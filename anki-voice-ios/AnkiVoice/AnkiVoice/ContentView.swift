// anki-voice-ios / ContentView.swift
import SwiftUI
import Speech
import AVFoundation
#if os(macOS) || os(visionOS)
import AVFAudio          // AVAudioApplication lives here
#endif
#if os(iOS)
import UIKit              // only used by openAppSettings()
#endif
import MicPermissionKit   // your Obj-C shim framework

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

    // 1) Prefer US Siri, high quality, non-novelty
    if let v = voices.first(where: { isUS($0) && isSiri($0) && isHighQuality($0) && !isNovelty($0) }) {
        print("Selected US Siri voice: \(v.name) (\(v.identifier))")
        return v
    }

    // 2) Prefer well-known natural US voices (no gag voices)
    let preferredNaturalNames = ["Samantha","Alex","Ava","Allison","Nicky","Joelle","Susan","Nathan","Tom"]
    if let v = voices.first(where: { voice in
        isUS(voice) && !isNovelty(voice) &&
        preferredNaturalNames.contains(where: { voice.name.localizedCaseInsensitiveContains($0) }) &&
        isHighQuality(voice)
    }) {
        print("Selected preferred US voice: \(v.name) (\(v.identifier))")
        return v
    }

    // 3) Any high-quality US, non-novelty
    if let v = voices.filter({ isUS($0) && !isNovelty($0) && isHighQuality($0) })
                     .sorted(by: { $0.quality.rawValue > $1.quality.rawValue })
                     .first {
        print("Selected high-quality US voice: \(v.name) (\(v.identifier))")
        return v
    }

    // 4) Final fallback: default US voice (still "normal")
    if let us = AVSpeechSynthesisVoice(language: "en-US") {
        print("Using default en-US voice")
        return us
    }
    
    print("Using fallback voice")
    return AVSpeechSynthesisVoice.speechVoices().first ?? AVSpeechSynthesisVoice(language: "en-US")!
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
        synth.stopSpeaking(at: .immediate)
        onFinishedSpeaking = nil
        // Immediately resume anyone awaiting completion
        waitCont?.resume()
        waitCont = nil
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

    override init() {
        super.init()
        #if os(iOS)
        // Add route change observer for debugging
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { note in
            let reason = AVAudioSession.RouteChangeReason(rawValue: (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0) ?? .unknown
            let route = AVAudioSession.sharedInstance().currentRoute
            print("Route change: \(reason), inputs: \(route.inputs.map { $0.portType.rawValue })")
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
    }

    
    func start() throws {
        transcript = ""
        isFinal = false
        
        // Check recognizer availability
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "stt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available"])
        }
        
        // Fully stop any prior run
        stop()
        
        #if os(iOS)
        // Configure session for STT (raw capture)
        // Use .record + .measurement for best raw capture for STT
        // (Alternative: .playAndRecord + .voiceChat if you need duplex with echo cancellation)
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        
        // Create request & task BEFORE starting engine
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 13.0, *) {
            req.requiresOnDeviceRecognition = false
            req.taskHint = .confirmation
        }
        request = req
        
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let error = error {
                    print("STT error: \(error)")
                    self.stop()
                    return
                }
                if let result = result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.isFinal = true
                        self.stop()
                    }
                }
            }
        }
        
        // Install tap and start engine
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)  // Use input format for mic tap, not output format
        
        // Remove any stale tap first
        if engine.isRunning {
            input.removeTap(onBus: 0)
        }
        
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        
        engine.prepare()
        try engine.start()
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
    }
}

@MainActor
struct ContentView: View {
    @State private var server = "http://192.168.1.153:8000"
    @State private var current: CurrentCard?
    @State private var state: ReviewState = .idle
    @StateObject private var tts = SpeechTTS()
    @StateObject private var stt = SpeechSTT()
    @State private var speechAuthorized = false
    @State private var micAuthorized = false
    @State private var permissionErrorMessage: String?
    @State private var isListening = false

    var canStart: Bool { micAuthorized && speechAuthorized }

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
                TextField("Server Base URL", text: $server).textFieldStyle(.roundedBorder)
                
                Button("Authorize Speech & Mic") {
                    authorizeSpeechAndMic()
                }.disabled(canStart)

                if let msg = permissionErrorMessage {
                    Text(msg)
                        .foregroundColor(.red)
                        .font(.caption)
                    
                    Button("Open Settings") {
                        openAppSettings()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                } else if !canStart {
                    Text(micAuthorized ? "Speech recognition permission required" : "Microphone permission required")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                
                Button("Start Review") { Task { await startReview() } }
                    .disabled(!canStart)

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
                            Button("Again") { Task { await submitGrade(1) } }
                            Button("Hard")  { Task { await submitGrade(2) } }
                            Button("Good")  { Task { await submitGrade(3) } }
                            Button("Easy")  { Task { await submitGrade(4) } }
                        }
                        Button("Ask Follow-up") { Task { await askFollowUp() } }
                    }
                }
                
                Spacer()
            }.padding()
            
            // Skip Explanation button (overlay during explaining state)
            if case .explaining = state {
        VStack {
                    Spacer()
                    Button(action: {
                        if tts.synth.isSpeaking { Task { await skipExplanation() } }
                    }) {
                        Text("Skip Explanation")
                            .font(.title2)
                            .fontWeight(.bold)
                            .foregroundColor(.white)
                            .frame(width: 280, height: 60)
                            .background(Color.red)
                            .cornerRadius(12)
                            .shadow(radius: 5)
                    }
                    .padding(.bottom, 40)
                }
            }
        }
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
        // 1) Sanity test: fetch current card with retry and logging
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 7.0
        let session = URLSession(configuration: config)
        
        guard let url = URL(string: "\(server)/current") else {
            tts.speak("Invalid server URL.")
            return
        }
        
        // Test connectivity first and log the result
        var card: CurrentCard?
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                if let httpResponse = response as? HTTPURLResponse {
                    print("GET /current: HTTP \(httpResponse.statusCode)")
                    let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                    print("Response body (first 500 chars): \(String(responseBody.prefix(500)))")
                    if httpResponse.statusCode != 200 {
                        print("ERROR: Non-200 status. Full body: \(responseBody)")
                    }
                }
                do {
                    let decoded = try JSONDecoder().decode(CurrentCard.self, from: data)
                    print("Decoded card - status: '\(decoded.status)', cardId: \(decoded.cardId?.description ?? "nil"), front_text: \(decoded.front_text?.prefix(50) ?? "nil"), back_text: \(decoded.back_text?.prefix(50) ?? "nil")")
                    if decoded.status == "ok" {
                        card = decoded
                        print("Successfully fetched card: \(decoded.cardId ?? 0)")
                        break
                    } else {
                        print("Card status is not 'ok': '\(decoded.status)'")
                    }
                } catch {
                    print("JSON decode failed: \(error)")
                    print("Response data: \(String(data: data, encoding: .utf8) ?? "<non-utf8>")")
                }
            } catch {
                print("Network error fetching /current:", error)
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
        await tts.speakAndWait(front)
        
        // Explicitly deactivate TTS audio session
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        
        // Minimal settling delay - reduced to 50ms for faster response (max 0.5s total as requested)
        try? await Task.sleep(nanoseconds: 50_000_000)
        
        // 3) Move to awaitingAnswer and listen immediately
        state = .awaitingAnswer(cardId: cid, front: front, back: back)
        await listenForAnswer()
    }

    func listenForAnswer() async {
        var retries = 0
        while true {
            stt.stop()
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif

            do {
                isListening = true
                try stt.start()
            } catch {
                let msg = (error as NSError).localizedDescription
                print("Failed to start STT: \(msg)")
                tts.speak("Speech recognition failed. Check microphone permission.")
                isListening = false
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                #endif
                return
            }

            try? await Task.sleep(nanoseconds: 60_000_000)

            var last = ""
            var unchangedCount = 0
            var hasReceivedAnyText = false
            let maxUnchanged = 20
            let answerUnchangedThreshold = 8

            while unchangedCount < maxUnchanged {
                try? await Task.sleep(nanoseconds: 300_000_000)
                let text = stt.transcript
                if !text.isEmpty { hasReceivedAnyText = true }
                if stt.isFinal && !text.isEmpty { break }
                if text == last { unchangedCount += 1 } else { unchangedCount = 0; last = text }
                if !text.isEmpty && unchangedCount >= answerUnchangedThreshold { break }
                if text.last == "." || text.last == "?" || text.last == "!" { break }
            }

            stt.stop()
            isListening = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif

            let transcript = stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if transcript.isEmpty && !hasReceivedAnyText {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if retries == 0 {
                        retries += 1
                        await tts.speakAndWait("I didn't catch that. Try speaking again.")
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        continue // re-listen, not recursion
                    } else {
                        guard case .awaitingAnswer(let cid, let front, let back) = state else { return }
                        await tts.speakAndWait("You can say a grade like 'grade good' or ask a question.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        await listenForAction()
                        return
                    }
                }
            }

            if transcript.isEmpty { return }
            
            // Check if user said "I don't know" - skip LLM and just read the answer
            let lowerTranscript = transcript.lowercased()
            let skipLLMPhrases = ["i don't know", "i have no idea", "i'm not sure", "no idea", "don't know", "i dunno"]
            if skipLLMPhrases.contains(where: { lowerTranscript.contains($0) }) {
                // User doesn't know the answer - read the back text directly
                guard case .awaitingAnswer(let cid, let front, let back) = state else { return }
                
                await tts.speakAndWait(back)
                
                // Explicitly deactivate TTS audio session
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                #endif
                
                // Minimal settling delay (50ms)
                try? await Task.sleep(nanoseconds: 50_000_000)
                
                state = .awaitingAction(cardId: cid, front: front, back: back)
                await listenForAction()
                return
            }
            
            await getExplanation(transcript: transcript)
            return
        }
    }
    
    func skipExplanation() async {
        // 1) kill TTS immediately and unblock any awaiters
        tts.stopSpeaking()

        // 2) hop to action state using the current card
        switch state {
        case .explaining(let cid, let front, let back, _),
             .awaitingAnswer(let cid, let front, let back),
             .awaitingAction(let cid, let front, let back):
            state = .awaitingAction(cardId: cid, front: front, back: back)

            // 3) tiny settle so the audio route flips cleanly
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            try? await Task.sleep(nanoseconds: 50_000_000)

            // 4) start listening right away
            await listenForAction()
        default:
            break
        }
    }

    func getExplanation(transcript: String) async {
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
        
        guard let url = URL(string:"\(server)/grade-with-explanation") else {
            print("Invalid /grade-with-explanation URL")
            tts.speak("Invalid server URL.")
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await listenForAction()
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(p)
        
        // Retry once on failure with detailed error logging
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(for: req)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                if httpResponse.statusCode == 200 {
                    if let result = try? JSONDecoder().decode(GradeWithExplanationResponse.self, from: data) {
                        state = .explaining(cardId: cid, front: front, back: back, explanation: result.explanation)
                        
                        // Wait for explanation to finish speaking
                        await tts.speakAndWait(result.explanation)
                        
                        // Explicitly deactivate TTS audio session
                        #if os(iOS)
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                        // Small settle (200ms) to let the route flip from speaker to built-in mic
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        #endif
                        
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        // Optional: comment out this block if you want fastest possible handoff
                        // await tts.speakAndWait("Say a grade like 'grade good' or ask a question.")
                        // try? await Task.sleep(nanoseconds: 50_000_000)
                        await listenForAction()
                        return
                    } else {
                        print("Decode error. HTTP \(httpResponse.statusCode), Body:", String(data: data, encoding: .utf8) ?? "<non-utf8>")
                    }
                } else {
                    print("HTTP \(httpResponse.statusCode) from /grade-with-explanation")
                    print("Body:", String(data: data, encoding: .utf8) ?? "<non-utf8>")
                    
                    // Speak specific messages for common error statuses
                    if httpResponse.statusCode == 400 {
                        tts.speak("Server says the request was invalid.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        // Don't prompt again - user already knows what to do
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        await listenForAction()
                        return
                    } else if httpResponse.statusCode == 502 || httpResponse.statusCode == 503 {
                        tts.speak("The grader backend failed. Check the OpenAI key or network on the server.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        // Don't prompt again - user already knows what to do
                        try? await Task.sleep(nanoseconds: 50_000_000)
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
                        print("Request timed out on retry. The LLM might be slow or the server might be busy.")
                        await tts.speakAndWait("The grader took too long to respond. You can try again or say a grade directly.")
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
        print("Failed to reach grader at \(server)/grade-with-explanation after retries")
        print("Make sure:")
        print("1. FastAPI server is running on your Mac")
        print("2. Server URL is set to your Mac's IP (e.g., http://192.168.1.50:8000)")
        print("3. Server is bound to 0.0.0.0 (not 127.0.0.1)")
        print("4. iPhone and Mac are on the same network")
        
        let errorMsg = server.contains("127.0.0.1") || server.contains("localhost") ?
            "Server URL is localhost. Set it to your Mac's IP address like http colon slash slash 192 dot 168 dot 1 dot 50 colon 8000" :
            "I couldn't reach the grader. Check that the server is running and the URL is correct. You can say a grade directly instead."
        await tts.speakAndWait(errorMsg)
        
        // Always transition to a valid state - never leave stuck in awaitingAnswer
        state = .awaitingAction(cardId: cid, front: front, back: back)
        await listenForAction()
    }

    func listenForAction() async {
        // Ensure we're in the right state
        guard case .awaitingAction = state else {
            print("listenForAction called but not in awaitingAction state: \(state)")
            return
        }
        
        stt.stop()
        // Don't deactivate session here - keep it active while staying in awaitingAction
        // to avoid spurious route changes and recognizer resets

        while true {
            // Double-check state before each iteration
            guard case .awaitingAction = state else {
                print("State changed during listenForAction, exiting loop")
                return
            }
            
            do {
                isListening = true
                try stt.start()
                print("STT started successfully in listenForAction")
            } catch {
                let errorMsg = (error as NSError).localizedDescription
                print("Failed to start speech recognition: \(errorMsg)")
                tts.speak("Speech recognition failed. Check microphone permission.")
                isListening = false
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                #endif
                return
            }

            var last = ""
            var unchangedCount = 0
            var hasReceivedAnyText = false
            var iterationCount = 0
            let maxUnchanged = 10
            let commandUnchangedThreshold = 2
            let minIterationsBeforeStop = 3 // Ensure we check at least 3 times (900ms) before stopping

            while unchangedCount < maxUnchanged {
                iterationCount += 1
                try? await Task.sleep(nanoseconds: 300_000_000)
                let text = stt.transcript
                if !text.isEmpty { hasReceivedAnyText = true }
                
                // Don't stop too early - give STT time to capture speech
                // Skip the unchangedCount logic for the first few iterations to prevent immediate stopping
                if iterationCount < minIterationsBeforeStop && text.isEmpty {
                    continue
                }
                
                if stt.isFinal && !text.isEmpty { break }
                if text == last { unchangedCount += 1 } else { unchangedCount = 0; last = text }
                if !text.isEmpty && unchangedCount >= commandUnchangedThreshold { break }
                if text.count > 0 && (text.last == "." || text.last == "?" || text.last == "!") { break }
            }

            stt.stop()
            isListening = false
            // Don't deactivate session here - keep it active while staying in awaitingAction
            // to avoid spurious route changes and recognizer resets

            let utterance = stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            print("listenForAction got utterance: '\(utterance)'")
            
            if utterance.isEmpty {
                // Check if we're still in awaitingAction state before restarting
                guard case .awaitingAction = state else {
                    print("State changed while processing empty utterance, exiting")
                    return
                }
                
                // If we got any text during the listen, wait longer before retrying
                // If we got nothing at all, it might be a mic issue - wait even longer
                let backoffDelay: UInt64 = hasReceivedAnyText ? 500_000_000 : 2_000_000_000 // 0.5s or 2s
                print("Empty utterance, backing off for \(backoffDelay / 1_000_000)ms before retry")
                try? await Task.sleep(nanoseconds: backoffDelay)
                
                // Check state again after backoff
                guard case .awaitingAction = state else {
                    print("State changed during backoff, exiting loop")
                    return
                }
                continue
            }

            // Handle intent and exit this function when you transition elsewhere,
            // otherwise continue the loop to keep listening in awaitingAction.
            switch IntentParser.parse(utterance) {
            case .grade(let ease, let canonical, let unambiguous):
                guard case .awaitingAction(let cid, let front, let back) = state else { return }
                if unambiguous {
                    let success = await submitGrade(ease)
                    if success {
                        await tts.speakAndWait("Marked \(canonical). Say 'undo' to change it.")
                        await startReview()
                        return
                    } else {
                        tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode with a card showing.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        // continue loop to re-listen
                    }
                } else {
                    state = .confirmingGrade(cardId: cid, ease: ease, front: front, back: back)
                    await tts.speakAndWait("Mark \(canonical)? Say confirm to proceed, or say a different grade.")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    await listenForConfirmation()
                    return
                }
            case .question(let q):
                await askFollowUp(question: q)
                return
            case .ambiguous:
                let lower = utterance.lowercased()
                if lower.contains("undo") || lower.contains("change") || lower.contains("take back") {
                    await undoLastGrade()
                    return
                } else {
                    await tts.speakAndWait("I didn't get that. Say a grade like 'grade good' or ask a question like 'explain more about URLLC'.")
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    // continue loop to re-listen
                }
            }
        }
    }

    func listenForConfirmation() async {
        stt.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #endif

        do {
            isListening = true
            try stt.start()
        } catch {
            let msg = (error as NSError).localizedDescription
            print("Failed to start STT: \(msg)")
            tts.speak("Speech recognition failed. Check microphone permission.")
            isListening = false
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            return
        }

        let started = DispatchTime.now()
        var last = ""
        var unchangedCount = 0
        let unchangedThreshold = 2
        let hardTimeout: UInt64 = 3_000_000_000

        while true {
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
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif

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

        await handleConfirmation(confirmed: confirmed || utter.isEmpty) // default yes on timeout
    }

    func handleConfirmation(confirmed: Bool) async {
        guard case .confirmingGrade(let cid, let ease, let front, let back) = state else { return }
        
        if confirmed {
            let success = await submitGrade(ease)
            if success {
                await tts.speakAndWait("Marked \(canonicalName(ease)). Say 'undo' to change it.")
                // Auto-advance to next card after successful grade
                await startReview()
            } else {
                tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode with a card showing.")
                state = .idle
            }
        } else {
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await tts.speakAndWait("Okay. Say a grade or ask a question.")
            try? await Task.sleep(nanoseconds: 300_000_000)
            await listenForAction()
        }
    }

    func askFollowUp(question: String? = nil) async {
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
        
        guard let url = URL(string:"\(server)/ask") else {
            print("Invalid /ask URL")
            tts.speak("Invalid server URL.")
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await listenForAction()
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(p)
        
        // Retry once
        for attempt in 0..<2 {
                do {
                    let (data, _) = try await session.data(for: req)
                    if let result = try? JSONDecoder().decode(AskResponse.self, from: data) {
                        await tts.speakAndWait(result.answer)
                        
                        // Explicitly deactivate TTS audio session
                        #if os(iOS)
                        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
                        #endif
                        
                        // Minimal settling delay (50ms)
                        try? await Task.sleep(nanoseconds: 50_000_000)
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
            
            await tts.speakAndWait("Sorry, I couldn't answer that.")
            
            // Explicitly deactivate TTS audio session
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
            
            // Minimal settling delay (50ms)
            try? await Task.sleep(nanoseconds: 50_000_000)
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await listenForAction()
    }

    func submitGrade(_ ease: Int) async -> Bool {
        guard let url = URL(string: "\(server)/submit-grade") else {
            print("Invalid submit-grade URL")
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
            print("Cannot submit grade: not in awaitingAction state")
            return false
        }
        let p = Payload(cardId: cid, ease: ease)
        req.httpBody = try? JSONEncoder().encode(p)
        
        do {
            let (data, response) = try await session.data(for: req)
            
            if let httpResponse = response as? HTTPURLResponse {
                print("POST /submit-grade: HTTP \(httpResponse.statusCode)")
                
                if httpResponse.statusCode == 200 {
                    // Check the response body - AnkiConnect returns {"result": true/false}
                    if let submitResponse = try? JSONDecoder().decode(SubmitResponse.self, from: data) {
                        if let result = submitResponse.result {
                            if result {
                                print("Grade submitted successfully")
                                return true
                            } else {
                                print("AnkiConnect returned result: false. Error:", submitResponse.error ?? "unknown")
                                if let error = submitResponse.error {
                                    print("AnkiConnect error message:", error)
                                } else {
                                    print("AnkiConnect returned false - likely no card is showing in Anki reviewer")
                                    print("Make sure Anki Desktop is open with a card ready for review")
                                }
                                return false
                            }
                        } else {
                            print("Response missing 'result' field. Body:", String(data: data, encoding: .utf8) ?? "<non-utf8>")
                            // Assume success if we got 200 and can't parse result
                            return true
                        }
                    } else {
                        print("Failed to decode submit response. Body:", String(data: data, encoding: .utf8) ?? "<non-utf8>")
                        // Do not assume success; log and return false to keep UI truthful
                        return false
                    }
                } else {
                    let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
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
                    
                    return false
                }
            } else {
                print("Invalid response type")
                return false
            }
        } catch {
            print("Network error submitting grade:", error)
            return false
        }
    }
    
    func undoLastGrade() async {
        guard let url = URL(string: "\(server)/undo") else {
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
