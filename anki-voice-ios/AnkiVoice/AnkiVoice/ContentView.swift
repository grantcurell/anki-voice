// anki-voice-ios / ContentView.swift
import SwiftUI
import Speech
import AVFoundation
#if os(macOS) || os(visionOS)
import AVFAudio          // AVAudioApplication lives here
#endif
#if os(iOS)
import UIKit              // only used by openAppSettings()
import MicPermissionKit   // your Obj-C shim framework
#endif

// MARK: - Permission Management

enum PermissionState {
    case granted
    case denied          // user denied or restricted; must go to Settings
    case undetermined    // iOS has not asked yet
}

struct MicPermission {
    static func state() -> PermissionState {
        #if os(iOS)
        // iOS: call into the Obj-C shim inside MicPermissionKit (no deprecation warnings)
        switch MicPermissionShim.recordPermission() {
        case .granted:      return .granted
        case .denied:       return .denied
        case .undetermined: return .undetermined
        @unknown default:   return .denied
        }
        #elseif os(macOS) || os(visionOS)
        // macOS/visionOS: AVAudioApplication is real here
        if #available(macOS 14.0, visionOS 1.0, *) {
            switch AVAudioApplication.recordPermission {
            case .granted:      return .granted
            case .denied:       return .denied
            case .undetermined: return .undetermined
            @unknown default:   return .denied
            }
        } else {
            return .denied
        }
        #else
        return .denied
        #endif
    }

    static func request(_ completion: @escaping (Bool) -> Void) {
        #if os(iOS)
        // iOS: use the shim wrapper
        MicPermissionShim.requestRecordPermission { granted in
            completion(granted)
        }
        #elseif os(macOS) || os(visionOS)
        if #available(macOS 14.0, visionOS 1.0, *) {
            Task {
                let ok = await AVAudioApplication.requestRecordPermission()
                DispatchQueue.main.async { completion(ok) }
            }
        } else {
            DispatchQueue.main.async { completion(false) }
        }
        #else
        DispatchQueue.main.async { completion(false) }
        #endif
    }
}

struct SpeechPermission {
    static func state() -> PermissionState {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .undetermined
        @unknown default: return .denied
        }
    }
    static func request(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }
}

#if os(iOS)
func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
}
#endif

struct CurrentCard: Decodable {
    let status: String
    let cardId: Int?
    let front_text: String?
    let back_text: String?
}

struct GradeResult: Decodable {
    let verdict: String
    let suggested_ease: Int
    let reasons: [String:AnyDecodable]
}

struct GradeWithExplanationResponse: Decodable {
    let correct: Bool
    let explanation: String
    let confidence: Double
    let missing: [String]
    let extras: [String]
}

struct AskResponse: Decodable {
    let answer: String
}

struct AnyDecodable: Decodable {
    enum ValueType {
        case null
        case bool(Bool)
        case int(Int)
        case double(Double)
        case string(String)
        case array([AnyDecodable])
        case dictionary([String: AnyDecodable])
    }
    
    private let value: ValueType
    
    init(_ value: ValueType) {
        self.value = value
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = AnyDecodable(.null)
        } else if let bool = try? container.decode(Bool.self) {
            self = AnyDecodable(.bool(bool))
        } else if let int = try? container.decode(Int.self) {
            self = AnyDecodable(.int(int))
        } else if let double = try? container.decode(Double.self) {
            self = AnyDecodable(.double(double))
        } else if let string = try? container.decode(String.self) {
            self = AnyDecodable(.string(string))
        } else if let array = try? container.decode([AnyDecodable].self) {
            self = AnyDecodable(.array(array))
        } else if let dict = try? container.decode([String: AnyDecodable].self) {
            self = AnyDecodable(.dictionary(dict))
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyDecodable value cannot be decoded")
        }
    }
    
    var description: String {
        switch value {
        case .null:
            return ""
        case .bool(let b):
            return String(b)
        case .int(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .string(let s):
            return s
        case .array(let a):
            return a.map { $0.description }.joined(separator: ", ")
        case .dictionary(let d):
            if let explanation = d["explanation"] {
                return explanation.description
            }
            if let answer = d["answer"] {
                return answer.description
            }
            return String(describing: d)
        }
    }
}

enum ReviewState {
    case idle
    case readingFront(cardId: Int, front: String, back: String)
    case awaitingAnswer(cardId: Int, front: String, back: String)
    case explaining(cardId: Int, front: String, back: String, explanation: String)
    case awaitingAction(cardId: Int, front: String, back: String) // listen for grade or question
    case confirmingGrade(cardId: Int, ease: Int, front: String, back: String) // ask "Confirm Good?"
}

// Names Apple uses for novelty/gag voices (differs across OSes)
private let noveltyNames: Set<String> = [
    "Zarvox","Bad News","Bubbles","Cellos","Deranged","Frog","Hysterical","Organ",
    "Princess","Trinoids","Whisper","Albert","Bahh","Bells","Boing","Fred","Junior",
    "Pipe Organ","Reed","Superstar","Theater","Good News"
]

private func isNovelty(_ v: AVSpeechSynthesisVoice) -> Bool {
    noveltyNames.contains { v.name.localizedCaseInsensitiveContains($0) }
}

private func isUS(_ v: AVSpeechSynthesisVoice) -> Bool { v.language == "en-US" }
private func isHighQuality(_ v: AVSpeechSynthesisVoice) -> Bool { v.quality.rawValue >= 1 } // Premium/Enhanced
private func isSiri(_ v: AVSpeechSynthesisVoice) -> Bool {
    v.name.localizedCaseInsensitiveContains("siri") || v.identifier.localizedCaseInsensitiveContains("siri")
}

// Absolute "normal voice" selector - pick once and always use it
func normalUSVoice() -> AVSpeechSynthesisVoice {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    // Cache a guaranteed safe fallback upfront (one acceptable force-unwrap on 'en' which always exists)
    let any = voices.first ?? AVSpeechSynthesisVoice(language: "en-US") ?? AVSpeechSynthesisVoice(language: "en")!
    
    #if DEBUG
    if voices.isEmpty {
        print("WARNING: No voices available in speechVoices()")
    }
    #endif

    // 1) Prefer US Siri, high quality, non-novelty
    if let v = voices.first(where: { isUS($0) && isSiri($0) && isHighQuality($0) && !isNovelty($0) }) {
        #if DEBUG
        print("Selected US Siri voice: \(v.name) (\(v.identifier))")
        #endif
        return v
    }

    // 2) Prefer well-known natural US voices (no gag voices)
    let preferredNaturalNames = ["Samantha","Alex","Ava","Allison","Nicky","Joelle","Susan","Nathan","Tom"]
    if let v = voices.first(where: { voice in
        isUS(voice) && !isNovelty(voice) &&
        preferredNaturalNames.contains(where: { voice.name.localizedCaseInsensitiveContains($0) }) &&
        isHighQuality(voice)
    }) {
        #if DEBUG
        print("Selected preferred US voice: \(v.name) (\(v.identifier))")
        #endif
        return v
    }

    // 3) Any high-quality US, non-novelty
    if let v = voices.filter({ isUS($0) && !isNovelty($0) && isHighQuality($0) })
                     .max(by: { $0.quality.rawValue < $1.quality.rawValue }) {
        #if DEBUG
        print("Selected high-quality US voice: \(v.name) (\(v.identifier))")
        #endif
        return v
    }

    // 4) Default US voice (still "normal")
    if let us = AVSpeechSynthesisVoice(language: "en-US") {
        #if DEBUG
        print("Using default en-US voice")
        #endif
        return us
    }
    
    // 5) Generic English
    if let en = AVSpeechSynthesisVoice(language: "en") {
        #if DEBUG
        print("Using en voice as fallback")
        #endif
        return en
    }
    
    // Return cached safe fallback (never crashes)
    #if DEBUG
    print("Using cached fallback voice: \(any.name)")
    #endif
    return any
}

final class SpeechTTS: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    nonisolated(unsafe) let synth = AVSpeechSynthesizer()
    private var voice: AVSpeechSynthesisVoice = normalUSVoice()
    var onFinishedSpeaking: (() -> Void)?

    // Track whoever is awaiting the current utterance
    private var waitCont: CheckedContinuation<Void, Never>?

    override init() {
        super.init()
        synth.delegate = self
    }
    
    deinit {
        #if DEBUG
        print("SpeechTTS deinit")
        #endif
        synth.stopSpeaking(at: .immediate)
        waitCont?.resume()
    }
    
    func setPreferredVoice(identifier: String?) {
        if let id = identifier, let v = AVSpeechSynthesisVoice(identifier: id), !isNovelty(v), v.language == "en-US" {
            voice = v
            print("Pinned voice: \(v.name) (\(v.identifier))")
        } else {
            voice = normalUSVoice()
            print("Reset to normal US voice: \(voice.name) (\(voice.identifier))")
        }
    }
    
    func speak(_ text: String) {
        // TTS queue hygiene: stop any current speech before starting new
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
        }
        let u = AVSpeechUtterance(string: text)
        u.voice = voice                  // <- always this one
        u.rate = 0.48                    // 0.44–0.52 tends to sound most natural
        u.pitchMultiplier = 1.0          // avoid "cartoon" pitch
        u.volume = 1.0
        synth.speak(u)
    }
    
    // Awaitable speak that unblocks if stopSpeaking() is pressed
    func speakAndWait(_ text: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // if another waiter existed, resume it to avoid leaks
            waitCont?.resume()
            waitCont = cont
            onFinishedSpeaking = { [weak self] in
                self?.onFinishedSpeaking = nil
                self?.waitCont?.resume()
                self?.waitCont = nil
            }
            speak(text)
        }
    }
    
    func stopSpeaking() {
        // Race hardening: capture and nil continuation before stopping
        let cont = waitCont
        waitCont = nil
        onFinishedSpeaking = nil
        synth.stopSpeaking(at: .immediate)
        // Resume after stopping to reduce double-resume risk
        cont?.resume()
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            self?.onFinishedSpeaking?()
            self?.onFinishedSpeaking = nil
        }
    }
}

final class SpeechSTT: NSObject, ObservableObject {
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    #if os(iOS)
    private let session = AVAudioSession.sharedInstance()
    #endif
    private let engine = AVAudioEngine()
    
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    @Published var transcript: String = ""
    @Published var isFinal: Bool = false
    private(set) var isRunning = false

    override init() {
        super.init()
        #if os(iOS)
        // Add route change observer for debugging
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            #if DEBUG
            let reason = AVAudioSession.RouteChangeReason(rawValue: (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0) ?? .unknown
            let route = AVAudioSession.sharedInstance().currentRoute
            print("Route change: \(reason), inputs: \(route.inputs.map { $0.portType.rawValue })")
            #endif
        }
        
        // Handle audio interruptions
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let info = note.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            if type == .began {
                self.stop()
                // Note: isListening is @Published, update on main thread
                DispatchQueue.main.async {
                    // ContentView will update isListening when it observes transcript changes
                }
            }
        }
        #endif
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        #if DEBUG
        print("SpeechSTT deinit")
        #endif
        stop()
    }

    
    func start() throws {
        transcript = ""
        isFinal = false
        
        // Check recognizer availability
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "stt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available"])
        }
        
        // If already running, don't tear down & recreate
        if isRunning {
            return
        }
        
        #if os(iOS)
        // Configure session for STT with duplex support (keeps mic hot, echo-cancels)
        // Prefer HFP over A2DP for lowest-latency duplex with mics
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,                // echo cancel + AGC, great for speech
            options: [.duckOthers, .allowBluetooth, .defaultToSpeaker]
        )
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        try session.setPreferredSampleRate(44100)
        try session.setPreferredIOBufferDuration(0.005)
        
        // Prefer built-in mic when on speaker (prevents weird input if BT output is connected)
        if session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
            try? session.setPreferredInput(nil) // ensures built-in mic
        }
        #endif
        
        // Create request & task BEFORE starting engine
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 13.0, *) {
            // Prefer on-device recognition when available (latency win, offline-friendly)
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            }
            req.taskHint = .confirmation
        }
        request = req
        
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    #if DEBUG
                    print("STT error: \(error)")
                    #endif
                    self.stop()
                    return
                }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.isFinal = true
                        // Do NOT stop here; caller controls lifecycle for continuous mode
                    }
                }
            }
        }
        
        // Install tap and start engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)  // Use input format for mic tap, not output format
        
        // Remove any stale tap and reset if already running (stability on rare devices)
        if engine.isRunning {
            input.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        
        engine.prepare()
        try engine.start()
        isRunning = true
    }
    
    func stop() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        
        // Don't deactivate session here - let caller handle it to avoid race with TTS
        isFinal = false
        isRunning = false
    }
}

@MainActor
struct ContentView: View {
    @AppStorage("serverBaseURL") private var server = "http://192.168.1.153:8000"
    @Environment(\.scenePhase) private var scenePhase
    @State private var current: CurrentCard?
    @State private var state: ReviewState = .idle
    @StateObject private var tts = SpeechTTS()
    @StateObject private var stt = SpeechSTT()
    @State private var speechAuthorized = false
    @State private var micAuthorized = false
    @State private var permissionErrorMessage: String?
    @State private var isListening = false
    @State private var currentNetworkTask: Task<Void, Never>?   // cancel LLM calls
    @State private var hasPromptedForAnswer = false
    @State private var isBusy = false  // debounce Start Review

    var canStart: Bool { micAuthorized && speechAuthorized }
    
    func stopAllIO(deactivateSession: Bool = true) {
        // Stop TTS & unblock any waiters
        tts.stopSpeaking()
        // Stop STT immediately
        stt.stop()
        #if os(iOS)
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                // Top bar with mute button
                HStack {
                    Spacer()
                    Button(action: {
                        tts.stopSpeaking()
                    }) {
                        Image(systemName: "speaker.slash.fill")
                            .font(.title2)
                            .foregroundColor(.red)
                            .padding(8)
                    }
                    .disabled(!tts.synth.isSpeaking)
                }
                .padding(.horizontal)
                
                Text("Anki Voice").font(.title)
                TextField("Server Base URL", text: $server)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                
                Button("Authorize Speech & Mic") {
                    authorizeSpeechAndMic()
                }.disabled(canStart)

                if let msg = permissionErrorMessage {
                    Text(msg)
                        .foregroundColor(.red)
                        .font(.caption)
                    
                    #if os(iOS)
                    Button("Open Settings") {
                        openAppSettings()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                    #endif
                } else if !canStart {
                    Text(micAuthorized ? "Speech recognition permission required" : "Microphone permission required")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                
                Button("Start Review") {
                    guard !isBusy else { return }
                    isBusy = true
                    Task {
                        await startReview()
                        isBusy = false
                    }
                }
                .disabled(!canStart || isBusy)

                if isListening {
                    Text("Listening…").foregroundColor(.orange)
                    Text(stt.transcript).padding()
                }

                // Show current state
                Text("State: \(stateDescription)").font(.caption)

                // Button fallback for awaitingAction state
                if case .awaitingAction = state {
        VStack {
                        Text("Voice commands: 'grade good', 'explain more about...'")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Button("Again") {
                                #if os(iOS)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                                Task {
                                    if await submitGrade(1) {
                                        await tts.speakAndWait("Marked again. \(undoPrompt())")
                                        await startReview()
                                    } else {
                                        tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
                                    }
                                }
                            }
                            .accessibilityLabel("Mark again")
                            Button("Hard") {
                                #if os(iOS)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                                Task {
                                    if await submitGrade(2) {
                                        await tts.speakAndWait("Marked hard. \(undoPrompt())")
                                        await startReview()
                                    } else {
                                        tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
                                    }
                                }
                            }
                            .accessibilityLabel("Mark hard")
                            Button("Good") {
                                #if os(iOS)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                                Task {
                                    if await submitGrade(3) {
                                        await tts.speakAndWait("Marked good. \(undoPrompt())")
                                        await startReview()
                                    } else {
                                        tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
                                    }
                                }
                            }
                            .accessibilityLabel("Mark good")
                            Button("Easy") {
                                #if os(iOS)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                #endif
                                Task {
                                    if await submitGrade(4) {
                                        await tts.speakAndWait("Marked easy. \(undoPrompt())")
                                        await startReview()
                                    } else {
                                        tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
                                    }
                                }
                            }
                            .accessibilityLabel("Mark easy")
                        }
                        Button("Ask Follow-up") {
                            Task {
                                currentNetworkTask?.cancel()
                                currentNetworkTask = Task {
                                    await askFollowUp()
                                }
                            }
                        }
                        .accessibilityLabel("Ask follow-up question")
                    }
                }
                
                Spacer()
            }.padding()
            
            // Always-present Skip button - large rectangle at bottom center
            if case .idle = state {
                EmptyView()
            } else {
                VStack {
                    Spacer()
                    Button {
                        Task { await handleSkip() }
                    } label: {
                        HStack {
                            Image(systemName: "forward.fill")
                                .font(.title)
                            Text("SKIP")
                                .font(.title)
                                .fontWeight(.bold)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                        .background(Color.red.opacity(0.9))
                        .cornerRadius(12)
                        .shadow(radius: 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                    .accessibilityLabel("Skip")
                }
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .background {
                stopAllIO()
                currentNetworkTask?.cancel()
                currentNetworkTask = nil
            }
        }
        .onDisappear {
            stopAllIO()
            currentNetworkTask?.cancel()
            currentNetworkTask = nil
        }
    }

    // Helper for consistent voice feedback after grading
    private func undoPrompt() -> String {
        return "Say 'undo' to change it."
    }
    
    // Helper to validate and trim server URL
    private func validatedBaseURL() -> String? {
        let base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard base.lowercased().hasPrefix("http://") || base.lowercased().hasPrefix("https://") else {
            return nil
        }
        return base
    }
    
    // Guard against speaking while app not active (prevents odd resumes)
    private func safeSpeakAndWait(_ text: String) async {
        guard scenePhase == .active else { return }
        await tts.speakAndWait(text)
    }

    var stateDescription: String {
        switch state {
        case .idle: return "Idle"
        case .readingFront: return "Reading Front"
        case .awaitingAnswer: return "Awaiting Answer"
        case .explaining: return "Explaining"
        case .awaitingAction: return "Awaiting Action"
        case .confirmingGrade: return "Confirming Grade"
        }
    }
    
    func authorizeSpeechAndMic() {
        permissionErrorMessage = nil
        
        // 1) MIC first (more fundamental permission)
        switch MicPermission.state() {
        case .granted:
            micAuthorized = true
            requestSpeech()       // chain to speech
        case .undetermined:
            MicPermission.request { granted in
                self.micAuthorized = granted
                if granted {
                    self.requestSpeech()
                } else {
                    self.permissionErrorMessage = "Microphone access is required. Enable it in Settings."
                }
            }
        case .denied:
            micAuthorized = false
            permissionErrorMessage = "Microphone permission was previously denied. Enable it in Settings."
        }
    }
    
    private func requestSpeech() {
        switch SpeechPermission.state() {
        case .granted:
            speechAuthorized = true
        case .undetermined:
            SpeechPermission.request { ok in
                self.speechAuthorized = ok
                if !ok {
                    self.permissionErrorMessage = "Speech Recognition permission is required. Enable it in Settings."
                }
            }
        case .denied:
            speechAuthorized = false
            permissionErrorMessage = "Speech Recognition was previously denied. Enable it in Settings."
        }
    }

    func startReview() async {
        // Reset prompt flag for new card
        hasPromptedForAnswer = false
        
        // 1) Sanity test: fetch current card with retry and logging
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 7.0
        let session = URLSession(configuration: config)
        
        guard let base = validatedBaseURL(),
              let url = URL(string: "\(base)/current") else {
            tts.speak("Invalid server URL.")
            return
        }
        
        // Test connectivity first and log the result
        var card: CurrentCard?
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    #if DEBUG
                    print("GET /current: HTTP \(httpResponse.statusCode)")
                    let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                    print("Response body (first 500 chars): \(String(responseBody.prefix(500)))")
                    if httpResponse.statusCode != 200 {
                        print("ERROR: Non-200 status. Full body: \(responseBody)")
                    }
                    #endif
                }
                do {
                    let decoded = try JSONDecoder().decode(CurrentCard.self, from: data)
                    #if DEBUG
                    print("Decoded card - status: '\(decoded.status)', cardId: \(decoded.cardId?.description ?? "nil"), front_text: \(decoded.front_text?.prefix(50) ?? "nil"), back_text: \(decoded.back_text?.prefix(50) ?? "nil")")
                    #endif
                    if decoded.status == "ok" {
                        card = decoded
                        #if DEBUG
                        print("Successfully fetched card: \(decoded.cardId ?? 0)")
                        #endif
                        break
                    } else {
                        #if DEBUG
                        print("Card status is not 'ok': '\(decoded.status)'")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("JSON decode failed: \(error)")
                    print("Response data: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
                    #endif
                }
            } catch {
                #if DEBUG
                print("Network error fetching /current:", error)
                #endif
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms retry
                }
            }
        }
        
        guard let finalCard = card,
              let front = finalCard.front_text,
              let back = finalCard.back_text,
              let cid = finalCard.cardId else {
            tts.speak("Open Anki on your Mac and start a review.")
            return
        }
        
        current = finalCard
        
        // 2) Move to readingFront and speak front
        state = .readingFront(cardId: cid, front: front, back: back)
        
        // Wait for TTS to finish before starting to listen
        await safeSpeakAndWait(front)
        
        // Explicitly deactivate TTS audio session
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        
        // Minimal settling delay - reduced to 50ms for faster response (max 0.5s total as requested)
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        // 3) Move to awaitingAnswer and start answer phase
        state = .awaitingAnswer(cardId: cid, front: front, back: back)
        await startAnswerPhase(cardId: cid, front: front, back: back)
    }

    func startAnswerPhase(cardId: Int, front: String, back: String) async {
        // Ask once, then keep listening
        if !hasPromptedForAnswer {
            hasPromptedForAnswer = true
            await tts.speakAndWait("What's your answer?")
            // do NOT deactivate the audio session here
            try? await Task.sleep(nanoseconds: 80_000_000) // tiny settle
        }
        await listenForAnswerContinuous()
    }

    func listenForAnswerContinuous() async {
        // Keep STT running continuously; don't flip the audio session in this phase
        do {
            isListening = true
            try stt.start()
                #if DEBUG
                print("Answer STT started.")
                #endif
        } catch {
            let msg = (error as NSError).localizedDescription
            print("Failed to start STT (answer): \(msg)")
            tts.speak("Speech recognition failed. Check microphone permission.")
            isListening = false
            return
        }

        // Main loop - avoid recursion by using continue instead of re-invoking function
        while case .awaitingAnswer = state {
            // If recognizer died, bring it back (resiliency check)
            if !stt.isRunning {
                do {
                    try stt.start()
                    print("[Answer] restarted STT")
                } catch {
                    print("[Answer] failed to restart STT: \(error)")
                    isListening = false
                    return
                }
            }
            
            // Debounce logic: finalize after stability or explicit final
            var last = ""
            var unchangedCount = 0
            let unchangedThreshold = 3         // ~900ms with 300ms ticks
            let softMinTicks = 2               // don't stop in the first ~600ms
            var ticks = 0

            while case .awaitingAnswer = state {
                try? await Task.sleep(nanoseconds: 300_000_000)
                ticks += 1

                let text = stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

                // Debug breadcrumbs
                #if DEBUG
                if ticks % 10 == 1 { print("[Answer] live transcript: '\(text)'") }
                #endif

                // No premature exits — just keep listening
                if stt.isFinal && !text.isEmpty { break }

                if text == last {
                    unchangedCount += 1
                } else {
                    unchangedCount = 0
                    last = text
                }

                // Heuristic: pause detected (stable text) OR sentence end
                if ticks > softMinTicks {
                    if (!text.isEmpty && unchangedCount >= unchangedThreshold) { break }
                    if let lastChar = text.last, [".","?","!"].contains(lastChar) { break }
                }
            }

            // Check if we left awaitingAnswer (e.g., user hit Skip)
            guard case .awaitingAnswer(let cid2, let front2, let back2) = state else {
                stt.stop()
                isListening = false
                return
            }

            let transcript = stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Reset for the next chunk regardless of content (prevent re-trigger loop)
            stt.transcript = ""
            stt.isFinal = false
            
            if transcript.isEmpty {
                // Nothing captured: continue the loop to keep listening (no recursion)
                #if DEBUG
                print("[Answer] empty capture; continuing to listen")
                #endif
                continue
            }

            // "I don't know" flow
            let lower = transcript.lowercased()
            let skipLLMPhrases = ["i don't know", "i have no idea", "i'm not sure", "no idea", "don't know", "i dunno"]
            if skipLLMPhrases.contains(where: { lower.contains($0) }) {
                stt.stop()
                isListening = false
                await tts.speakAndWait(back2)
                try? await Task.sleep(nanoseconds: 50_000_000)
                state = .awaitingAction(cardId: cid2, front: front2, back: back2)
                await listenForAction()
                return
            }

            // Normal path: grade with explanation
            stt.stop()
            isListening = false
            currentNetworkTask?.cancel()
            currentNetworkTask = Task { await getExplanation(transcript: transcript) }
            return
        }
        
        // Fell out of loop - state changed
        stt.stop()
        isListening = false
    }
    
    func handleSkip() async {
        // Stop TTS/STT and cancel any in-flight network
        // Don't deactivate session if we're transitioning to action phase (will start listening immediately)
        let willTransitionToAction: Bool
        switch state {
        case .awaitingAnswer, .explaining, .confirmingGrade:
            willTransitionToAction = true
        default:
            willTransitionToAction = false
        }
        
        stopAllIO(deactivateSession: !willTransitionToAction)
        currentNetworkTask?.cancel()
        currentNetworkTask = nil

        switch state {
        case .readingFront(let cid, let front, let back):
            // Jump to answer phase
            state = .awaitingAnswer(cardId: cid, front: front, back: back)
            await startAnswerPhase(cardId: cid, front: front, back: back)

        case .awaitingAnswer(let cid, let front, let back):
            // EXCEPTION: go straight to grading phase
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await tts.speakAndWait("Skipped to grading. Say a grade like 'grade good'.")
            try? await Task.sleep(nanoseconds: 150_000_000)
            await listenForAction()

        case .explaining(let cid, let front, let back, _):
            // Stop explanation, go to grading/listening
            state = .awaitingAction(cardId: cid, front: front, back: back)
            try? await Task.sleep(nanoseconds: 150_000_000)
            await listenForAction()

        case .awaitingAction:
            // Next card
            await startReview()

        case .confirmingGrade(let cid, _, let front, let back):
            // Cancel confirmation, return to action
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await tts.speakAndWait("Cancelled. Say a grade or ask a question.")
            try? await Task.sleep(nanoseconds: 150_000_000)
            await listenForAction()

        case .idle:
            break
        }
    }

    func getExplanation(transcript: String) async {
        if Task.isCancelled { return }
        
        guard case .awaitingAnswer(let cid, let front, let back) = state else { return }
        
        struct Payload: Encodable {
            let cardId: Int
            let transcript: String
            let question_text: String?
            let reference_text: String?
        }
        
        let p = Payload(cardId: cid, transcript: transcript, question_text: front, reference_text: back)
        
        // Create URLSession with timeout for GPT responses (30s for LLM calls)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 60.0
        let session = URLSession(configuration: config)
        
        guard let base = validatedBaseURL(),
              let url = URL(string: "\(base)/grade-with-explanation") else {
            tts.speak("Invalid server URL.")
            state = .awaitingAction(cardId: cid, front: front, back: back)
            try? await Task.sleep(nanoseconds: 150_000_000)
            await listenForAction()
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(p)
        
        // Retry once on failure with detailed error logging
        for attempt in 0..<2 {
            if Task.isCancelled { return }
            
            do {
                let (data, response) = try await session.data(for: req)
                if Task.isCancelled { return }
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                if httpResponse.statusCode == 200 {
                    if Task.isCancelled { return }
                    if let result = try? JSONDecoder().decode(GradeWithExplanationResponse.self, from: data) {
                        if Task.isCancelled { return }
                        state = .explaining(cardId: cid, front: front, back: back, explanation: result.explanation)
                        
                        // Wait for explanation to finish speaking
                        await safeSpeakAndWait(result.explanation)
                        if Task.isCancelled { return }
                        
                        // Small settle to let the route flip from speaker to built-in mic
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        // Optional: comment out this block if you want fastest possible handoff
                        // await tts.speakAndWait("Say a grade like 'grade good' or ask a question.")
                        // try? await Task.sleep(nanoseconds: 50_000_000)
                        await listenForAction()
                        return
                    } else {
                        #if DEBUG
                        print("Decode error. HTTP \(httpResponse.statusCode), Body:", String(data: data, encoding: .utf8) ?? "<non-utf8>")
                        #endif
                    }
                } else {
                    #if DEBUG
                    print("HTTP \(httpResponse.statusCode) from /grade-with-explanation")
                    print("Body:", String(data: data, encoding: .utf8) ?? "<non-utf8>")
                    #endif
                    
                    // Speak specific messages for common error statuses
                    if httpResponse.statusCode == 400 {
                        tts.speak("Server says the request was invalid.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        // Small settle after TTS
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        await listenForAction()
                        return
                    } else if httpResponse.statusCode == 502 || httpResponse.statusCode == 503 {
                        tts.speak("The grader backend failed. Check the OpenAI key or network on the server.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        // Small settle after TTS
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        await listenForAction()
                        return
                    }
                }
            } catch {
                let nsError = error as NSError
                print("Network error on attempt \(attempt + 1):", error)
                
                // Check for timeout specifically (NSURLErrorTimedOut = -1001)
                if nsError.domain == NSURLErrorDomain && nsError.code == -1001 {
                    print("Request timed out after \(config.timeoutIntervalForRequest)s")
                    if attempt == 0 {
                        print("Retrying...")
                        try? await Task.sleep(nanoseconds: 500_000_000) // 500ms retry delay
                        continue
                    } else {
                        // Timeout on retry - give up and transition to action state
                        #if DEBUG
                        print("Request timed out on retry. The LLM might be slow or the server might be busy.")
                        #endif
                        await safeSpeakAndWait("The grader took too long to respond. You can try again or say a grade directly.")
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        await listenForAction()
                        return
                    }
                }
                
                // Other network errors - retry once
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms retry delay
                }
            }
        }
        
        // Fallback on failure - ensure we don't get stuck
        let baseURL = validatedBaseURL() ?? server
        #if DEBUG
        print("Failed to reach grader at \(baseURL)/grade-with-explanation after retries")
        print("Make sure:")
        print("1. FastAPI server is running on your Mac")
        print("2. Server URL is set to your Mac's IP (e.g., http://192.168.1.50:8000)")
        print("3. Server is bound to 0.0.0.0 (not 127.0.0.1)")
        print("4. iPhone and Mac are on the same network")
        #endif
        
        let errorMsg = baseURL.contains("127.0.0.1") || baseURL.contains("localhost") ?
            "Server URL is localhost. Set it to your Mac's IP address like http colon slash slash 192 dot 168 dot 1 dot 50 colon 8000" :
            "I couldn't reach the grader. Check that the server is running and the URL is correct. You can say a grade directly instead."
        await safeSpeakAndWait(errorMsg)
        
        // Always transition to a valid state - never leave stuck in awaitingAnswer
        state = .awaitingAction(cardId: cid, front: front, back: back)
        await listenForAction()
    }

    func listenForAction() async {
        // Must be in awaitingAction
        guard case .awaitingAction = state else {
            #if DEBUG
            print("listenForAction called but not in awaitingAction state: \(state)")
            #endif
            return
        }

        // Do not stop/deactivate here; keep session warm between phases
        // Check if engine is already running - if so, we can keep it going
        if !stt.isRunning {
            do {
                isListening = true
                try stt.start()
                #if DEBUG
                print("[Action] STT started (continuous)")
                #endif
            } catch {
                let msg = (error as NSError).localizedDescription
                print("Failed to start STT (action): \(msg)")
                tts.speak("Speech recognition failed. Check microphone permission.")
                isListening = false
                return
            }
        } else {
            isListening = true
            #if DEBUG
            print("[Action] STT already running")
            #endif
        }

        // A small inner loop that finalizes chunks but never tears down the engine
        while true {
            // Re-check state on each pass
            guard case .awaitingAction = state else {
                print("[Action] State changed, exiting action listener")
                isListening = false
                return
            }

            // Wait for a short stable segment or final result (similar to answer phase)
            var last = ""
            var unchanged = 0
            var ticks = 0
            let unchangedThreshold = 2          // ~600ms at 300ms ticks
            let minTicks = 2

            while true {
                // Resilience check: if recognizer silently died, restart it
                if !stt.isRunning {
                    do {
                        try stt.start()
                        print("[Action] restarted STT after detecting it stopped")
                    } catch {
                        print("[Action] failed to restart STT: \(error)")
                        isListening = false
                        return
                    }
                }
                
                try? await Task.sleep(nanoseconds: 300_000_000)
                ticks += 1

                let text = stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                #if DEBUG
                if ticks % 10 == 1 { print("[Action] live transcript: '\(text)'") }
                #endif

                if stt.isFinal && !text.isEmpty { break }

                if text == last { unchanged += 1 } else { unchanged = 0; last = text }

                if ticks > minTicks {
                    if (!text.isEmpty && unchanged >= unchangedThreshold) { break }
                    if let c = text.last, [".","?","!"].contains(c) { break }
                }

                // If we left awaitingAction (e.g., graded, asking follow-up), bail
                if case .awaitingAction = state {} else {
                    isListening = false
                    return
                }
            }

            let utterance = stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            // Immediately reset transcript for next command in continuous mode
            stt.transcript = ""
            stt.isFinal = false
            
            if utterance.isEmpty {
                // Keep listening continuously; do not stop/start the engine
                continue
            }

            #if DEBUG
            print("[Action] utterance: '\(utterance)'")
            #endif

            switch IntentParser.parse(utterance) {
            case .grade(let ease, let canonical, let unambiguous):
                guard case .awaitingAction(let cid, let front, let back) = state else { return }
                if unambiguous {
                    let success = await submitGrade(ease)
                    if success {
                        stt.stop()
                        isListening = false
                        await tts.speakAndWait("Marked \(canonical). \(undoPrompt())")
                        await startReview()
                        return
                    } else {
                        stt.stop()
                        isListening = false
                        tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode with a card showing.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        // Restart listening after error message
                        do {
                            isListening = true
                            try stt.start()
                        } catch {
                            print("Failed to restart STT after error: \(error)")
                        }
                        continue
                    }
                } else {
                    stt.stop()
                    isListening = false
                    state = .confirmingGrade(cardId: cid, ease: ease, front: front, back: back)
                    await tts.speakAndWait("Mark \(canonical)? Say confirm to proceed, or say a different grade.")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await listenForConfirmation()
                    return
                }

            case .question(let q):
                stt.stop()
                isListening = false
                currentNetworkTask?.cancel()
                currentNetworkTask = Task { await askFollowUp(question: q) }
                // askFollowUp will speak and then return to awaitingAction→listenForAction
                return

            case .ambiguous:
                let lower = utterance.lowercased()
                if lower.contains("undo") || lower.contains("change") || lower.contains("take back") {
                    stt.stop()
                    isListening = false
                    await undoLastGrade()
                    // undo will call startReview(); exit this loop
                    return
                } else {
                    stt.stop()
                    isListening = false
                    await tts.speakAndWait("I didn't get that. Say a grade like 'grade good' or ask a question.")
                    // After TTS, restart listening; do not deactivate session
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    do {
                        isListening = true
                        try stt.start()
                    } catch {
                        print("Failed to restart STT after ambiguous: \(error)")
                    }
                    continue
                }
            }
        }
    }

    func listenForConfirmation() async {
        stt.stop()
        // Don't deactivate session - keep it active for smooth transition
        try? await Task.sleep(nanoseconds: 100_000_000)

        do {
            isListening = true
            try stt.start()
        } catch {
            let msg = (error as NSError).localizedDescription
            print("Failed to start STT: \(msg)")
            tts.speak("Speech recognition failed. Check microphone permission.")
            isListening = false
            return
        }

        let started = DispatchTime.now()
        var last = ""
        var unchangedCount = 0
        let unchangedThreshold = 2
        let hardTimeout: UInt64 = 3_000_000_000

        while true {
            // Resilience check: if recognizer silently died, restart it
            if !stt.isRunning {
                do {
                    try stt.start()
                    #if DEBUG
                    print("[Confirm] restarted STT")
                    #endif
                } catch {
                    #if DEBUG
                    print("[Confirm] failed to restart STT: \(error)")
                    #endif
                    isListening = false
                    return
                }
            }
            
            try? await Task.sleep(nanoseconds: 300_000_000)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            if elapsed >= hardTimeout { break }

            let text = stt.transcript
            if stt.isFinal && !text.isEmpty { break }
            if text == last { unchangedCount += 1 } else { unchangedCount = 0; last = text }
            if !text.isEmpty && unchangedCount >= unchangedThreshold { break }
        }

        stt.stop()
        isListening = false
        // Don't deactivate session here - keep it active for smooth transitions

        let utter = stt.transcript.lowercased()
        let confirmed = utter.contains("confirm") || utter.contains("yes") || utter.contains("do it") ||
                        utter.contains("that's fine") || utter.contains("okay") || utter.contains("ok")
        let cancelled = utter.contains("no") || utter.contains("cancel") || utter.contains("wait") ||
                        utter.contains("hold on") || utter.contains("change")

        if cancelled {
            guard case .confirmingGrade(let cid, _, let front, let back) = state else { return }
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await listenForAction()
            return
        }

        await handleConfirmation(confirmed: confirmed) // safer: don't auto-confirm on timeout
    }

    func handleConfirmation(confirmed: Bool) async {
        guard case .confirmingGrade(let cid, let ease, let front, let back) = state else { return }
        
        // STT is already stopped by listenForConfirmation()
        
        if confirmed {
            let success = await submitGrade(ease)
            if success {
                await tts.speakAndWait("Marked \(canonicalName(ease)). \(undoPrompt())")
                // Auto-advance to next card after successful grade
                await startReview()
            } else {
                tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode with a card showing.")
                state = .idle
            }
        } else {
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await tts.speakAndWait("Okay. Say a grade or ask a question.")
            try? await Task.sleep(nanoseconds: 150_000_000)
            await listenForAction()
        }
    }

    func askFollowUp(question: String? = nil) async {
        if Task.isCancelled { return }
        
        guard case .awaitingAction(let cid, let front, let back) = state else { return }
        
        let questionText = question ?? "What does that mean?"
        
        struct Payload: Encodable {
            let cardId: Int
            let question: String
            let question_text: String?
            let reference_text: String?
        }
        
        let p = Payload(cardId: cid, question: questionText, question_text: front, reference_text: back)
        
        // Short timeout for Q&A
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 15.0
        let session = URLSession(configuration: config)
        
        guard let base = validatedBaseURL(),
              let url = URL(string: "\(base)/ask") else {
            tts.speak("Invalid server URL.")
            state = .awaitingAction(cardId: cid, front: front, back: back)
            try? await Task.sleep(nanoseconds: 150_000_000)
            await listenForAction()
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(p)
        
        // Retry once
        for attempt in 0..<2 {
            if Task.isCancelled { return }
            
            do {
                let (data, _) = try await session.data(for: req)
                if Task.isCancelled { return }
                if let result = try? JSONDecoder().decode(AskResponse.self, from: data) {
                    if Task.isCancelled { return }
                    await safeSpeakAndWait(result.answer)
                    if Task.isCancelled { return }
                    
                    // Small settle delay after TTS
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    state = .awaitingAction(cardId: cid, front: front, back: back)
                    await listenForAction()
                    return
                }
                } catch {
                    if attempt == 0 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                }
            }
            
            await safeSpeakAndWait("Sorry, I couldn't answer that. Ask again or grade.")
            
            // Small settle delay after TTS
            try? await Task.sleep(nanoseconds: 150_000_000)
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await listenForAction()
    }

    func submitGrade(_ ease: Int) async -> Bool {
        guard let base = validatedBaseURL(),
              let url = URL(string: "\(base)/submit-grade") else {
            #if DEBUG
            print("Invalid submit-grade URL")
            #endif
            return false
        }
        
        // Short timeout for commands (2-3s)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        let session = URLSession(configuration: config)
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        struct Payload: Encodable {
            let cardId: Int
            let ease: Int
        }
        
        struct SubmitResponse: Decodable {
            let result: Bool?
            let error: String?
        }
        
        guard case .awaitingAction(let cid, _, _) = state else {
            #if DEBUG
            print("Cannot submit grade: not in awaitingAction state")
            #endif
            return false
        }
        let p = Payload(cardId: cid, ease: ease)
        req.httpBody = try? JSONEncoder().encode(p)
        
        do {
            let (data, response) = try await session.data(for: req)
            
            if let httpResponse = response as? HTTPURLResponse {
                #if DEBUG
                print("POST /submit-grade: HTTP \(httpResponse.statusCode)")
                #endif
                
                if httpResponse.statusCode == 200 {
                    // Check the response body - AnkiConnect returns {"result": true/false}
                    if let submitResponse = try? JSONDecoder().decode(SubmitResponse.self, from: data) {
                        if let result = submitResponse.result {
                            if result {
                                #if DEBUG
                                print("Grade submitted successfully")
                                #endif
                                return true
                            } else {
                                #if DEBUG
                                print("AnkiConnect returned result: false. Error:", submitResponse.error ?? "unknown")
                                if let error = submitResponse.error {
                                    print("AnkiConnect error message:", error)
                                } else {
                                    print("AnkiConnect returned false - likely no card is showing in Anki reviewer")
                                    print("Make sure Anki Desktop is open with a card ready for review")
                                }
                                #endif
                                return false
                            }
                        } else {
                            #if DEBUG
                            print("Response missing 'result' field. Body:", String(data: data, encoding: .utf8) ?? "<non-utf8>")
                            #endif
                            // Treat unknown body as failure to avoid false advancement
                            return false
                        }
                    } else {
                        #if DEBUG
                        print("Failed to decode submit response. Body:", String(data: data, encoding: .utf8) ?? "<non-utf8>")
                        #endif
                        // Do not assume success; log and return false to keep UI truthful
                        return false
                    }
                } else {
                    let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                    #if DEBUG
                    print("HTTP error \(httpResponse.statusCode). Body:", responseBody)
                    
                    // Parse error detail from response for better user feedback
                    var errorDetail: String? = nil
                    if let json = try? JSONDecoder().decode([String: String].self, from: data),
                       let detail = json["detail"] {
                        errorDetail = detail
                    }
                    
                    // Provide specific error messages for common status codes
                    if httpResponse.statusCode == 409 {
                        print("Reviewer not ready - Anki Desktop may not be in review mode")
                        if let detail = errorDetail {
                            print("Server says:", detail)
                        }
                    } else if httpResponse.statusCode == 502 {
                        print("AnkiConnect error when submitting grade")
                        if let detail = errorDetail {
                            print("Server says:", detail)
                        }
                    }
                    #endif
                    
                    return false
                }
            } else {
                #if DEBUG
                print("Invalid response type")
                #endif
                return false
            }
        } catch {
            #if DEBUG
            print("Network error submitting grade:", error)
            #endif
            return false
        }
    }
    
    func undoLastGrade() async {
        guard let base = validatedBaseURL(),
              let url = URL(string: "\(base)/undo") else {
            tts.speak("Could not undo.")
            return
        }
        
        // Short timeout for undo command
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        let session = URLSession(configuration: config)
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        
        do {
            _ = try await session.data(for: req)
            tts.speak("Undid that.")
            // Try to fetch current card again
            await startReview()
        } catch {
            tts.speak("Could not undo.")
        }
    }

    func getCurrentCardId() -> Int {
        switch state {
        case .readingFront(let cid, _, _): return cid
        case .awaitingAnswer(let cid, _, _): return cid
        case .explaining(let cid, _, _, _): return cid
        case .awaitingAction(let cid, _, _): return cid
        case .confirmingGrade(let cid, _, _, _): return cid
        case .idle: return 0
        }
    }

    func canonicalName(_ ease: Int) -> String {
        switch ease {
        case 1: return "again"
        case 2: return "hard"
        case 3: return "good"
        default: return "easy"
        }
    }
}
