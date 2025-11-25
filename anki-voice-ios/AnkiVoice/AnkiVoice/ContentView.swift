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
import OSLog

// MARK: - Tailscale Configuration

let tailnetSuffix = "tail73fcb8.ts.net"
let defaultDevURL = "http://grants-macbook-air.\(tailnetSuffix):8000"
// Production API URL
let productionAPIURL = "https://api.grantcurell.com"

// MARK: - Logging

#if DEBUG
// In DEBUG, use print for immediate visibility
func appLog(_ message: String, category: String = "app") {
    print("[\(category)] \(message)")
}
#else
// In Release, use OSLog for filtering by subsystem/category
private let appLogger = Logger(subsystem: "anki.voice", category: "app")
private let sttLogger = Logger(subsystem: "anki.voice", category: "stt")
private let ttsLogger = Logger(subsystem: "anki.voice", category: "tts")
private let networkLogger = Logger(subsystem: "anki.voice", category: "network")

func appLog(_ message: String, category: String = "app") {
    switch category {
    case "stt":
        sttLogger.info("\(message)")
    case "tts":
        ttsLogger.info("\(message)")
    case "network":
        networkLogger.info("\(message)")
    default:
        appLogger.info("\(message)")
    }
}
#endif

// MARK: - JSON Decoding Helpers

extension JSONDecoder {
    /// Non-throwing decode helper that returns nil on error instead of throwing
    func decodeIfPresent<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        do {
            return try decode(type, from: data)
        } catch {
            #if DEBUG
            print("[JSON] Decode failed for \(type): \(error)")
            #endif
            return nil
        }
    }
}

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
        // iOS: use the shim wrapper and always bounce to main
        MicPermissionShim.requestRecordPermission { granted in
            DispatchQueue.main.async { completion(granted) }
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
    let front_text_tts: String?  // README div only for TTS, falls back to front_text if not present
    let back_text_tts: String?    // README div only for TTS, falls back to back_text if not present
    let front_language: String?   // BCP-47 language code for front TTS (e.g., "es-ES", "en-US")
    let back_language: String?    // BCP-47 language code for back TTS (e.g., "es-ES", "en-US")
}

// MARK: - Post-grade resync helpers
extension ContentView {
    /// GET /current with cache-busting and tight timeouts; returns nil on any error.
    private func fetchCurrentCard() async -> CurrentCard? {
        guard let base = validatedBaseURL(),
              var comps = URLComponents(string: "\(base)/current") else { return nil }
        // cache-buster so we don't re-read a warm cache
        comps.queryItems = [URLQueryItem(name: "t", value: String(Date().timeIntervalSince1970))]
        guard let url = comps.url else { return nil }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 3.0
        cfg.timeoutIntervalForResource = 4.0
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: cfg)
        do {
            var req = URLRequest(url: url)
            authService.addAuthHeader(to: &req)
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return try? JSONDecoder().decode(CurrentCard.self, from: data)
        } catch { return nil }
    }

    /// After grading, wait for Anki to publish the next card id, then advance UI to it.
    private func advanceToNextCard(previousCardId: Int) async {
        // small settle; Anki may still be flipping
        try? await Task.sleep(nanoseconds: 120_000_000)
        let maxAttempts = 6
        for i in 0..<maxAttempts {
            if Task.isCancelled { return }
            if let c = await fetchCurrentCard(),
               c.status == "ok",
               let cid = c.cardId, let front = c.front_text, let back = c.back_text {
                if cid != previousCardId {
                    // We have the next card. Drive normal flow without touching isBusy/startReview().
                    current = c
                    #if os(iOS)
                    await director.handle(.toTTS(stt))
                    #endif
                    state = .readingFront(cardId: cid, front: front, back: back)
                    let frontTTS = c.front_text_tts ?? front
                    let frontLang = c.front_language
                    await safeSpeakAndWait(frontTTS, language: frontLang)
                    state = .awaitingAnswer(cardId: cid, front: front, back: back)
                    await startAnswerPhase(cardId: cid, front: front, back: back)
                    return
                }
            }
            // short backoff and try again
            try? await Task.sleep(nanoseconds: 120_000_000 + UInt64(i) * 60_000_000)
        }
        // Fallback: if we never saw a new id (deck finished, etc.), use existing path.
        await startReview()
    }
}

struct GradeWithExplanationResponse: Decodable {
    let explanation: String
}

struct AskResponse: Decodable {
    let answer: String
}

fileprivate struct AnyDecodable: Decodable {
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

enum ReviewState: Equatable {
    case idle
    case readingFront(cardId: Int, front: String, back: String)
    case awaitingAnswer(cardId: Int, front: String, back: String)
    case explaining(cardId: Int, front: String, back: String, explanation: String)
    case awaitingAction(cardId: Int, front: String, back: String) // listen for grade or question
    case confirmingGrade(cardId: Int, ease: Int, front: String, back: String) // ask "Confirm Good?"
    case confirmingDelete(cardId: Int, front: String, back: String) // ask "Confirm delete note?"
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
// Replace rawValue heuristic with explicit cases
private func isHighQuality(_ v: AVSpeechSynthesisVoice) -> Bool {
    switch v.quality {
    case .premium, .enhanced: return true
    default: return false
    }
}
private func isSiri(_ v: AVSpeechSynthesisVoice) -> Bool {
    v.name.localizedCaseInsensitiveContains("siri") || v.identifier.localizedCaseInsensitiveContains("siri")
}

// Absolute "normal voice" selector - pick once and always use it
// Returns optional; nil means use system default (AVSpeechSynthesizer handles this automatically)
func normalUSVoice() -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    
    // Fast "any" fallback bundle
    let any = voices.first
        ?? AVSpeechSynthesisVoice(language: "en-US")
        ?? AVSpeechSynthesisVoice(language: "en")
        ?? AVSpeechSynthesisVoice(language: Locale.current.identifier)
        ?? AVSpeechSynthesisVoice(language: "en-GB")
        ?? AVSpeechSynthesisVoice(language: "en-AU")
        ?? AVSpeechSynthesisVoice(language: "en-CA")
    
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
    
    // Return cached fallback (may be nil in simulator/CI; system default used when nil)
    #if DEBUG
    if let finalVoice = any {
        print("Using cached fallback voice: \(finalVoice.name)")
    } else {
        print("No voice available; using system default")
    }
    #endif
    return any
}

final class SpeechTTS: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    nonisolated(unsafe) let synth = AVSpeechSynthesizer()
    @Published private(set) var isSpeaking: Bool = false
    private var voice: AVSpeechSynthesisVoice? = normalUSVoice()
    private var lastUtteranceText: String?
    var onFinishedSpeaking: (() -> Void)?

    // Track whoever is awaiting the current utterance
    private var waitCont: CheckedContinuation<Void, Never>?
    
    var isMidUtterance: Bool { synth.isSpeaking }
    
    #if os(iOS)
    weak var director: AudioDirector?
    #endif

    override init() {
        super.init()
        synth.delegate = self
    }
    
    // Explicit teardown (call from stopAllIO / onDisappear)
    func teardown() {
        // Idempotent
        let cont = waitCont
        waitCont = nil
        onFinishedSpeaking = nil
        synth.stopSpeaking(at: .immediate)
        cont?.resume()
        isSpeaking = false
    }
    
    deinit {
        #if DEBUG
        print("SpeechTTS deinit")
        #endif
        // No side-effects here; rely on explicit teardown
    }
    
    
    // Note: stt reference must be passed from ContentView for director
    func speak(_ text: String, stt: SpeechSTT? = nil, route: Bool = true, language: String? = nil) {
        Task { @MainActor in
            #if os(iOS)
            if route {
                if let stt = stt, let director = director {
                    await director.handle(.toTTS(stt))
                } else if director != nil {
                    // Even without stt, use director for routing
                    await director?.handle(.toTTSWithoutSTT)
                }
            }
            #endif

            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
            lastUtteranceText = text
            let u = AVSpeechUtterance(string: text)
            // Use language-specific voice if provided, otherwise fall back to default voice
            if let lang = language, let langVoice = AVSpeechSynthesisVoice(language: lang) {
                u.voice = langVoice
            } else if let v = voice {
                u.voice = v
            }
            u.rate = 0.48
            u.pitchMultiplier = 1.0
            u.volume = 1.0
            synth.speak(u)
            self.isSpeaking = true
        }
    }
    
    // Awaitable speak that unblocks if stopSpeaking() is pressed
    // stt parameter required for director integration
    func speakAndWait(_ text: String, stt: SpeechSTT? = nil, language: String? = nil) async {
        #if os(iOS)
        if let stt = stt, let director = director {
            await director.handle(.toTTS(stt))
        } else if director != nil {
            // Even without stt, use director for routing
            await director?.handle(.toTTSWithoutSTT)
        }
        #endif
        
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            // if another waiter existed, resume it to avoid leaks
            waitCont?.resume()
            waitCont = cont
            onFinishedSpeaking = { [weak self] in
                guard let self = self else { return }
                self.onFinishedSpeaking = nil
                self.waitCont?.resume()
                self.waitCont = nil
                
                // NOTE: STT entry is handled by listenForAnswerContinuous(), not here
                // This avoids duplicate calls and race conditions
            }
            // Routing already handled above; avoid double-routing.
            speak(text, stt: stt, route: false, language: language)
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
        DispatchQueue.main.async { self.isSpeaking = false }
    }
    
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        // Director already handled routing before speak() was called
        DispatchQueue.main.async { self.isSpeaking = true }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            if let cb = self.onFinishedSpeaking {
                self.onFinishedSpeaking = nil
                cb()                    // resumes continuation
            } else {
                self.waitCont?.resume() // only if no callback was set
                self.waitCont = nil
            }
        }
    }

    // Ensure continuations are also released on cancellation paths
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            if let cb = self.onFinishedSpeaking {
                self.onFinishedSpeaking = nil
                cb()
            } else {
                self.waitCont?.resume()
                self.waitCont = nil
            }
        }
    }
}

@MainActor
final class SpeechSTT: NSObject, ObservableObject {
    enum Gate { case open, closed }
    var micGate: Gate = .closed
    #if os(iOS)
    weak var director: AudioDirector?
    #endif
    
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    #if os(iOS)
    private let session = AVAudioSession.sharedInstance()
    private var routeChangeObs: NSObjectProtocol?
    private var interruptionObs: NSObjectProtocol?
    private var availabilityObs: NSObjectProtocol?
    #endif
    private let engine = AVAudioEngine()
    private var tapInstalled = false
    
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    @Published var transcript: String = ""
    @Published var isFinal: Bool = false
    @Published private(set) var isRunning = false
    @Published private(set) var isMuted = false

    override init() {
        super.init()
        #if os(iOS)
        // Add route change observer for debugging and graceful device handling
        routeChangeObs = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self else { return }
            let reason = AVAudioSession.RouteChangeReason(rawValue: (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0) ?? .unknown
            let route = AVAudioSession.sharedInstance().currentRoute
            #if DEBUG
            print("Route change: \(reason), inputs: \(route.inputs.map { $0.portType.rawValue })")
            #endif
            
            Task { @MainActor in
                // Restart recognition if device changed while listening (e.g., user inserts AirPods)
                // Don't flip phase in callback; just keep recognition alive
                if reason == .newDeviceAvailable || reason == .oldDeviceUnavailable {
                    #if DEBUG
                    print("[RouteChange] Device change, rebuilding tap…")
                    #endif
                    AVAudioSession.sharedInstance().preferBluetoothHFPInputIfAvailable()
                    self.rebuildTapIfNeeded()
                    if !self.isMuted, self.micGate == .open {
                        self.stopRecognitionIfRunning()
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        try? await self.startRecognitionIfNeeded()
                    }
                }
            }
        }
        
        // Handle audio interruptions
        interruptionObs = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self = self,
                  let info = note.userInfo,
                  let typeVal = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeVal) else { return }
            
            Task { @MainActor in
                switch type {
                case .began:
                    // Pause TTS and stop STT on interruption
                    self.stopRecognitionIfRunning()
                    self.micGate = .closed
                    // Keep session active - don't deactivate
                    
                case .ended:
                    // Check if we should resume
                    let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                        .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
                    
                    if shouldResume {
                        // Reactivate session and restart if gate was open and not muted
                        try? AVAudioSession.sharedInstance().setActive(true, options: [])
                        self.rebuildTapIfNeeded()
                        if !self.isMuted, self.micGate == .open {
                            // Restart recognition after brief delay
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            try? await self.startRecognitionIfNeeded()
                        }
                    }
                    
                @unknown default:
                    break
                }
            }
        }
        
        // React to speech recognizer availability changes (Wi-Fi, network, on-device flips)
        // Fall back to raw notification name to support SDKs where the typed constant isn't exposed
        let availabilityName = NSNotification.Name("SFSpeechRecognizerAvailabilityDidChange")
        availabilityObs = NotificationCenter.default.addObserver(
            forName: availabilityName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                if !self.isMuted, self.micGate == .open {
                    #if os(iOS)
                    await self.director?.handle(.assertSTTRunning(self))
                    #else
                    try? await self.startRecognitionIfNeeded()
                    #endif
                }
            }
        }
        
        // Handle media services reset (rare but critical - requires full reconfiguration)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            Task { @MainActor in
                #if os(iOS)
                // Re-configure session and restart pipelines
                try? await self.director?.configureOnce()
                self.rebuildTapIfNeeded()
                // Restart STT if gate was open and not muted
                if !self.isMuted, self.micGate == .open {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    try? await self.startRecognitionIfNeeded()
                }
                #endif
            }
        }
        #endif
    }
    
    deinit {
        #if os(iOS)
        if let o = routeChangeObs { NotificationCenter.default.removeObserver(o) }
        if let o = interruptionObs { NotificationCenter.default.removeObserver(o) }
        if let o = availabilityObs { NotificationCenter.default.removeObserver(o) }
        #endif
        #if DEBUG
        print("SpeechSTT deinit")
        #endif
        // DO NOT call stop() here (Main-actor isolated; deinit is nonisolated in Swift Concurrency)
    }

    
    // Public API for mute control
    func setMuted(_ muted: Bool) {
        if muted == isMuted { return }
        isMuted = muted
        
        if muted {
            // Hard stop recognition and remove the capture source
            stopRecognitionIfRunning()
            uninstallTapIfInstalled()
            // Optional battery saver: stop the engine when fully muted
            if engine.isRunning {
                engine.stop()
            }
        } else {
            // Prepare engine and reinstall tap (but only start recognition if allowed)
            if !engine.isRunning {
                engine.prepare()
                try? engine.start()
            }
            installTapIfNeeded()
            // Will no-op if micGate == .closed
            Task { @MainActor in
                try? await startRecognitionIfNeeded()
            }
        }
    }
    
    // Tap management
    private func installTapIfNeeded() {
        guard !isMuted, !tapInstalled else { return }
        
        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        
        // Fallback to inputFormat if output format is invalid
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = input.inputFormat(forBus: 0)
        }
        
        guard format.sampleRate > 0, format.channelCount > 0 else {
            #if DEBUG
            print("[SpeechSTT] Cannot install tap: invalid format")
            #endif
            return
        }
        
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, !self.isMuted, self.micGate == .open else { return }
            self.request?.append(buffer)
        }
        
        tapInstalled = true
        #if DEBUG
        print("[SpeechSTT] Tap installed")
        #endif
    }
    
    private func uninstallTapIfInstalled() {
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        #if DEBUG
        print("[SpeechSTT] Tap uninstalled")
        #endif
    }
    
    // Call when routes/interruptions occur and you need to rebuild, but keep mute respected
    func rebuildTapIfNeeded() {
        uninstallTapIfInstalled()
        installTapIfNeeded()
    }
    
    // Install tap once and keep engine running (legacy method - now uses installTapIfNeeded)
    func installTapOnce() async throws {
        guard !tapInstalled else { return }
        
        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        
        // If format is invalid, try again after brief pause
        if format.sampleRate <= 0 || format.channelCount == 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            format = input.outputFormat(forBus: 0)
        }
        
        // Fallback to inputFormat
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = input.inputFormat(forBus: 0)
        }
        
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "stt", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid audio format"])
        }
        
        engine.prepare()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self, !self.isMuted, self.micGate == .open else { return }
            self.request?.append(buffer)
        }
        
        try engine.start()
        tapInstalled = true
        #if DEBUG
        print("[SpeechSTT] Tap installed, engine running")
        #endif
    }
    
    // Start recognition task (separate from engine lifecycle)
    func startRecognitionIfNeeded() async throws {
        // If a previous task existed but crashed, make sure we're clean
        if task != nil && !isRunning {
            stopRecognitionIfRunning()
        }
        // Respect both the gate and mute override
        guard !isMuted, task == nil, micGate == .open else { return }
        
        guard let recognizer = recognizer, recognizer.isAvailable else {
            throw NSError(domain: "stt", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognizer is not available"])
        }
        
        installTapIfNeeded()
        
        let input = engine.inputNode
        var format = input.outputFormat(forBus: 0)
        
        // If format is invalid, try again after brief pause
        if format.sampleRate <= 0 || format.channelCount == 0 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            format = input.outputFormat(forBus: 0)
        }
        
        // Fallback to inputFormat
        if format.sampleRate <= 0 || format.channelCount == 0 {
            format = input.inputFormat(forBus: 0)
        }
        
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "stt", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid audio format"])
        }
        
        transcript = ""
        isFinal = false
        
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if #available(iOS 13.0, *) {
            if recognizer.supportsOnDeviceRecognition {
                req.requiresOnDeviceRecognition = true
            }
            req.taskHint = .dictation
        }
        request = req
        
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
        
        isRunning = true
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            
            if let error = error {
                #if DEBUG
                print("STT error: \(error)")
                #endif
                Task { @MainActor in
                    self.isRunning = false
                    self.task = nil
                    self.request = nil
                    // If still allowed to listen, auto-recover
                    if !self.isMuted, self.micGate == .open {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        try? await self.startRecognitionIfNeeded()
                    }
                }
                return
            }
            
            if let r = result {
                Task { @MainActor in
                    self.transcript = r.bestTranscription.formattedString
                    self.isFinal = r.isFinal
                }
            }
            
            if result?.isFinal == true {
                Task { @MainActor in
                    self.isRunning = false
                    self.task = nil
                    self.request = nil
                    // If still allowed to listen, auto-recover
                    if !self.isMuted, self.micGate == .open {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        try? await self.startRecognitionIfNeeded()
                    }
                }
            }
        }
        
        #if DEBUG
        print("[SpeechSTT] Recognition task started")
        #endif
    }
    
    // Stop recognition task (keep engine running)
    func stopRecognitionIfRunning() {
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isFinal = false
        isRunning = false
        // Do not auto-remove tap here; mute controls source removal
        #if DEBUG
        print("[SpeechSTT] Recognition task stopped")
        #endif
    }
    
    // Watchdog to check task liveness (for debugging)
    func ensureTaskLiveness() {
        if task == nil || !isRunning {
            #if DEBUG
            print("[SpeechSTT] Liveness check failed (task nil or not running)")
            #endif
        }
    }
    
    // Legacy methods for backward compatibility during transition
    func start() async throws {
        try await installTapOnce()
        try await startRecognitionIfNeeded()
    }
    
    func stop() {
        stopRecognitionIfRunning()
        // Do NOT stop engine in normal flow - keep tap installed and engine running
        // Only stop engine if deactivating session on app background
    }
}

@MainActor
struct ContentView: View {
    @AppStorage("serverBaseURL") private var server = productionAPIURL
    @AppStorage("didRequestMicOnce") private var didRequestMicOnce = false
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var authService = AuthService.shared
    @State private var current: CurrentCard?
    @State private var state: ReviewState = .idle
    @StateObject private var tts = SpeechTTS()
    @StateObject private var stt = SpeechSTT()
    @State private var speechAuthorized = false
    @State private var micAuthorized = false
    @State private var permissionErrorMessage: String?
    @State private var isListening = false
    @State private var currentNetworkTask: Task<Void, Never>?   // cancel LLM calls
    @State private var listeningTask: Task<Void, Never>?   // track listening task to cancel it
    @State private var hasPromptedForAnswer = false
    @State private var isBusy = false  // debounce Start Review
    @State private var isSubmittingGrade = false  // prevent concurrent grade submissions
    @State private var showBackDuringProcessing = false  // show back while LLM is grading
    @State private var showAuthSheet: Bool = false  // Show registration/login sheet
    @State private var lastErrorSpokenAt: Date?  // rate-limit error TTS
    @State private var serverHealthStatus: String?  // "Connected" or "Server unreachable"
    @State private var lastGradedCardId: Int?  // Track last graded card for undo
    @State private var availableDecks: [String] = []  // List of available decks
    @State private var selectedDeck: String = ""  // Currently selected deck
    @State private var isLoadingDecks: Bool = false  // Loading state for decks
    @State private var isSyncing: Bool = false  // Loading state for sync
    @State private var deckNewCount: Int? = nil  // Number of new cards in selected deck
    @State private var deckReviewCount: Int? = nil  // Number of review cards in selected deck
    @State private var isLoadingDeckStats: Bool = false  // Loading state for deck stats
    // AnkiWeb linking removed - using custom sync server with auto-generated credentials
    
    #if os(iOS)
    private let director = AudioDirector()
    @State private var routeWatchToken: NSObjectProtocol?
    #endif

    var canStart: Bool { micAuthorized && speechAuthorized }
    
    @MainActor
    func stopAllIO(deactivateSession: Bool = false) {
        // Stop TTS & unblock any waiters (explicit teardown to avoid dangling continuations)
        tts.teardown()
        // Stop STT only if it's actually running (avoid unnecessary session churn)
        if stt.isRunning {
            stt.stop()
        }
        #if os(iOS)
        // Only deactivate session on app lifecycle events (background/disappear)
        // Default is false to preserve routing state between phases
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        #endif
    }

    var body: some View {
        ZStack {
            VStack(spacing: 16) {
                // Top bar with mute button and register/logout
                TopBarView(authService: authService, stt: stt, showAuthSheet: $showAuthSheet)
                
                Text("Anki Voice").font(.title)
                
                // Show authentication status
                AuthStatusView(authService: authService)
                
                // Show server URL input only when idle and not authenticated (for local dev)
                #if DEBUG
                if case .idle = state, !authService.isAuthenticated {
                    TextField("Server Base URL (local dev)", text: $server)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    
                    // Show validation hint if URL is invalid
                    if validatedServerURL() == nil && !server.isEmpty {
                        Text("HTTP allowed only for *.\(tailnetSuffix)")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    
                    // Show port forwarding hint
                    Text("Note: Run 'kubectl port-forward -n gateway --address 0.0.0.0 svc/api-gateway 8000:80' to enable local dev")
                            .font(.caption2)
                        .foregroundColor(.blue)
                        .padding(.top, 2)
                    }
                #endif
                    
                    // Deck selection dropdown
                    if !availableDecks.isEmpty {
                        Picker("Select Deck", selection: $selectedDeck) {
                            Text("Select a deck...").tag("")
                            ForEach(availableDecks, id: \.self) { deck in
                                Text(deck).tag(deck)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedDeck) { oldValue, newValue in
                            if !newValue.isEmpty && newValue != oldValue {
                                Task {
                                    await fetchDeckStats(for: newValue)
                                }
                            } else if newValue.isEmpty {
                                // Clear stats when no deck is selected
                                deckNewCount = nil
                                deckReviewCount = nil
                            }
                        }
                    } else if isLoadingDecks {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Loading decks...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Button("Load Decks") {
                            Task {
                                await fetchDecks()
                            }
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                
                // Display deck stats when a deck is selected (always visible, compact format)
                if !selectedDeck.isEmpty {
                    HStack(spacing: 12) {
                        if isLoadingDeckStats {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Loading...")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        } else {
                            // Always show both, even if 0
                            HStack(spacing: 4) {
                                Text("New:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(deckNewCount ?? 0)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.blue)
                            }
                            HStack(spacing: 4) {
                                Text("Review:")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Text("\(deckReviewCount ?? 0)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.orange)
                            }
                        }
                    }
                    .padding(.top, 2)
                    .task(id: selectedDeck) {
                        // Automatically fetch stats whenever selectedDeck changes
                        if !selectedDeck.isEmpty {
                            await fetchDeckStats(for: selectedDeck)
                        }
                    }
                }
                
                // Show server health status (always visible when not idle, or when idle if set)
                if case .idle = state {
                    if let status = serverHealthStatus {
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(status == "Connected" ? .green : .red)
                    }
                } else {
                    // Show connection status during review
                    if let status = serverHealthStatus {
                        Text(status)
                            .font(.caption2)
                            .foregroundColor(status == "Connected" ? .green : .red)
                    } else {
                        Text("Checking connection...")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
                
                // Only show authorize button if permissions are not already granted
                if !canStart {
                    Button("Authorize Speech & Mic") {
                        authorizeSpeechAndMic()
                    }
                }

                if let msg = permissionErrorMessage {
                    Text(msg)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    #if os(iOS)
                    Button("Open Settings") {
                        openAppSettings()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                    .padding(.top, 4)
                    #endif
                    
                    // Additional guidance for users
                    #if os(iOS)
                    Text("If Microphone isn't under Settings → AnkiVoice yet, go to Settings → Privacy & Security → Microphone. If AnkiVoice appears there, enable it. If it doesn't appear, tap 'Authorize' again.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 4)
                    #endif
                } else if !canStart {
                    Text(micAuthorized ? "Speech recognition permission required" : "Microphone permission required")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
                
                // Show "Start Review" when idle, "Return to deck selection" when in review
                Button(state == .idle ? "Start Review" : "Return to deck selection") {
                    if state == .idle {
                        #if DEBUG
                        print("[START] Button tapped. canStart=\(canStart), isBusy=\(isBusy), micAuth=\(micAuthorized), speechAuth=\(speechAuthorized)")
                        #endif
                        guard !isBusy else {
                            #if DEBUG
                            print("[START] Already busy, ignoring tap")
                            #endif
                            return
                        }
                        guard canStart else {
                            #if DEBUG
                            print("[START] Cannot start: permissions not granted")
                            #endif
                            return
                        }
                        // startReview() handles isBusy guard/defer internally
                        Task {
                            #if DEBUG
                            print("[START] Starting review task...")
                            #endif
                            await startReview()
                            #if DEBUG
                            print("[START] Review task completed, state=\(state)")
                            #endif
                        }
                    } else {
                        // Return to deck selection
                        Task {
                            await returnToDeckSelection()
                        }
                    }
                }
                .disabled(state == .idle && (!canStart || isBusy))
                
                // Sync button (only shown when idle)
                if case .idle = state {
                    Button {
                        Task {
                            await syncAnki()
                        }
                    } label: {
                        HStack {
                            if isSyncing {
                                ProgressView()
                                    .scaleEffect(0.8)
                                    .padding(.trailing, 8)
                            }
                            Text(isSyncing ? "Syncing..." : "Sync")
                        }
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                    }
                    .background(Color.blue.opacity(0.12))
                    .cornerRadius(10)
                    .disabled(isSyncing)
                }

                // Card displaying current prompt/answer
                if !displayText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if !displayTitle.isEmpty {
                            Text(displayTitle)
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        
                        // Make answer text scrollable
                        ScrollView {
                            Text(displayText)
                                .font(.title2)
                                .fontWeight(.semibold)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 300) // Limit height so it doesn't take over screen

                        if shouldShowTranscript {
                            Divider().opacity(0.3)
                            ScrollView {
                                Text(stt.transcript)
                                    .font(.body)
                                    .foregroundColor(.orange)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityLabel("Your answer")
                            }
                            .frame(maxHeight: 150) // Limit transcript height too
                        }
        }
        .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                }

                if isListening {
                    Text("Listening…").foregroundColor(.orange)
                        .font(.caption)
                }

                // Show current state
                Text("State: \(stateDescription)").font(.caption)

                Spacer()

                // Always-visible grade buttons
                if case .idle = state {
                    EmptyView()
                } else {
                    VStack(spacing: 10) {
                        // Read Answer button
                        Button {
                            #if os(iOS)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            #endif
                            Task { await handleReadAnswer() }
                        } label: {
                            Text("Read Answer")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.accentColor.opacity(0.18))
                                .cornerRadius(10)
                        }
                        .accessibilityLabel("Read the answer")

                        // Existing grade buttons
                        HStack(spacing: 10) {
                            gradeButton("Again", ease: 1)
                            gradeButton("Hard", ease: 2)
                            gradeButton("Good", ease: 3)
                            gradeButton("Easy", ease: 4)
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 6)

                        // Optional tip line
                        Text("Say \"undo\" to change the last grade.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
        }
        }
        .padding()
        .sheet(isPresented: $showAuthSheet) {
            AuthSheet(authService: authService)
        }
        .onAppear {
            // Check authorization status on app startup
            checkAuthorizationStatus()
            
            // Fetch decks when app appears
            Task {
                await fetchDecks()
                // If a deck is already selected, fetch its stats
                if !selectedDeck.isEmpty {
                    await fetchDeckStats(for: selectedDeck)
                }
            }
            
            // One-time migration: update old IPs to Tailscale MagicDNS hostname
            let oldIPs = [
                "http://192.168.1.153:8000",
                "http://100.101.120.23:8000",
                "http://10.125.111.70:8000"
            ]
            if oldIPs.contains(server) {
                server = defaultDevURL
                #if DEBUG
                print("[MIGRATION] Updated server URL from IP to Tailscale MagicDNS: \(defaultDevURL)")
                #endif
            }
            
            // Normalize and persist validated URL
            if let normalized = validatedBaseURL(), normalized != server {
                server = normalized
                #if DEBUG
                print("[NORMALIZE] Persisted normalized URL: \(normalized)")
                #endif
            }
            
            #if DEBUG
            print("Server URL:", validatedBaseURL() ?? "<invalid>")
            #endif
            
            #if os(iOS)
            // Configure audio session once at app start (long-lived voiceChat session with AEC)
            // Inject director into SpeechTTS and SpeechSTT
            tts.director = director
            stt.director = director
            Task { @MainActor in
                do {
                    try await director.configureOnce()
                    // Install STT tap once and keep engine running
                    try await stt.installTapOnce()
                } catch {
                    #if DEBUG
                    print("[ContentView] Failed to configure audio: \(error)")
                    #endif
                }
            }
            
            // Route watchdog: force speaker if iOS flips to earpiece (always, not just during TTS)
            // This is a safety net; director should handle routing, but this catches edge cases
            routeWatchToken = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    let s = AVAudioSession.sharedInstance()
                    let outs = s.currentRoute.outputs
                    let wentReceiver = outs.contains { $0.portType == .builtInReceiver }
                    
                    // Always force speaker if route goes to the earpiece (unless on Bluetooth)
                    if wentReceiver {
                        await director.handle(.forceSpeakerIfEarpiece)
                    }
                }
            }
            #endif
            
            // Check server health
            Task {
                await checkServerHealth()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                // Ensure session is active and STT is running if it should be
                Task { @MainActor in
                    await director.ensureActive()
                    // Ensure STT is running if it should be (gate is open)
                    if stt.micGate == .open && !stt.isRunning {
                        try? await stt.startRecognitionIfNeeded()
                    }
                }
                
            case .inactive:
                // Keep session active during transitions
                break
                
            case .background:
                // Do NOT deactivate session. Keep STT running (Discord-like behavior)
                // Optional: pause TTS for battery savings
                Task { @MainActor in
                    tts.stopSpeaking()  // Pause TTS when backgrounded
                    // Keep STT running - don't stop it
                    // Keep session active - don't deactivate
                    currentNetworkTask?.cancel()
                    currentNetworkTask = nil
                }
                
            @unknown default:
                break
            }
            applyKeepAwake()
        }
        .onChange(of: state) { _, _ in
            applyKeepAwake()
        }
        .onDisappear {
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            #endif
            Task { @MainActor in
                #if os(iOS)
                // Remove route observer
                if let token = routeWatchToken {
                    NotificationCenter.default.removeObserver(token)
                    routeWatchToken = nil
                }
                #endif
                // Only deactivate if really quitting (not just backgrounding)
                // For true app termination, we'll deactivate
                stopAllIO(deactivateSession: false)  // Don't deactivate - keep session alive
                currentNetworkTask?.cancel()
                currentNetworkTask = nil
            }
        }
    }

    // Helper for consistent voice feedback after grading
    private func undoPrompt() -> String {
        return "Say 'undo' to change it."
    }
    
    // Rate-limited error speaking (avoid spam in Release)
    private func speakErrorIfAllowed(_ message: String, throttleSeconds: Double = 3.0) {
        let now = Date()
            if let last = lastErrorSpokenAt, now.timeIntervalSince(last) < throttleSeconds {
            #if DEBUG
            let interval = now.timeIntervalSince(last)
            print("[ERROR] Throttled error message (last spoken \(String(format: "%.1f", interval))s ago): \(message)")
            #endif
            return
        }
        lastErrorSpokenAt = now
        tts.speak(message)
    }
    
    // Helper to describe URL errors in user-friendly terms
    private func describeURLError(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .cannotConnectToHost:   // -1004 / ECONNREFUSED
                #if DEBUG
                return "Could not connect. For local dev, run: kubectl port-forward -n gateway --address 0.0.0.0 svc/api-gateway 8000:80"
                #else
                return "Could not connect to server. Please check your network connection."
                #endif
            case .timedOut:
                return "Server timed out. Mac may be asleep or network is flaky."
            default:
                break
            }
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == -1004 {
            return "Could not connect. The server isn't running on your Mac (port 8000 refused). Start it with: uvicorn app dot main colon app --host 0 dot 0 dot 0 dot 0 --port 8000"
        }
        return "Network error."
    }
    
    // Check server health (lightweight preflight)
    private func checkServerHealth() async {
        guard let base = validatedBaseURL(), let url = URL(string: "\(base)/health") else {
            await MainActor.run {
                self.serverHealthStatus = nil
            }
            return
        }
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 1.0  // Short timeout
        config.timeoutIntervalForResource = 1.5
        let session = URLSession(configuration: config)
        
        do {
            var req = URLRequest(url: url)
            authService.addAuthHeader(to: &req)
            let (_, response) = try await session.data(for: req)
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            await MainActor.run {
                self.serverHealthStatus = ok ? "Connected" : "Server unreachable"
            }
        } catch {
            let description = describeURLError(error)
            await MainActor.run {
                // Show concise status; full message will be spoken if user tries to start
                if description.contains("isn't running") {
                    self.serverHealthStatus = "Server not running"
                } else if description.contains("timed out") {
                    self.serverHealthStatus = "Server timeout"
                } else {
                    self.serverHealthStatus = "Server unreachable"
                }
            }
        }
    }
    
    // Grade button helper
    private func gradeButton(_ title: String, ease: Int) -> some View {
        Button {
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            Task { await handleGradeButton(ease) }
        } label: {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.accentColor.opacity(0.12))
                .cornerRadius(10)
        }
        .accessibilityLabel("Mark \(title.lowercased())")
    }
    
    // Helper to get API base URL (production for authenticated users, or custom server URL)
    func validatedBaseURL() -> String? {
        // If authenticated, use production API
        if authService.isAuthenticated {
            return productionAPIURL
        }
        // Otherwise use the configured server URL (for local dev)
        return validatedServerURL()
    }
    
    // Helper to validate and trim server URL (for local dev)
    // Rejects raw IPs and enforces scheme rules per build type
    // Auto-appends tailnet suffix for bare device names
    private func validatedServerURL() -> String? {
        var base = server.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Prepend scheme when omitted
        if !base.lowercased().hasPrefix("http://") && !base.lowercased().hasPrefix("https://") {
            #if DEBUG
            base = "http://" + base
            #else
            base = "https://" + base
            #endif
        }
        
        guard var comps = URLComponents(string: base), let rawHost = comps.host else { return nil }
        
        // If user typed a bare device name (no dots), treat it as MagicDNS host
        if !rawHost.contains(".") {
            comps.host = "\(rawHost).\(tailnetSuffix)"
        }
        
        let host = comps.host ?? rawHost
        // Explicitly reject IPv6 literals—this app does not support IPv6 endpoints
        if host.contains(":") {
            #if DEBUG
            print("IPv6 host '\(host)' not supported; use IPv4 or MagicDNS.")
            #endif
            return nil
        }
        
        // Strict IPv4 check using regex
        let isIPv4 = host.range(of: #"^(?:\d{1,3}\.){3}\d{1,3}$"#, options: .regularExpression) != nil
        #if DEBUG
        if isIPv4 {
            print("Warning: using raw IP '\(host)'. Prefer MagicDNS like '<device>.\(tailnetSuffix)'.")
        }
        #else
        if isIPv4 { return nil }
        #endif
        
        // Dev: only allow HTTP for our tailnet domain (subdomains only, not root domain)
        #if DEBUG
        if comps.scheme?.lowercased() == "http",
           !host.hasSuffix(".\(tailnetSuffix)") {
            print("ATS: HTTP allowed only for *.\(tailnetSuffix). You entered \(host).")
            return nil
        }
        #else
        // In Release, require https
        if comps.scheme?.lowercased() != "https" { return nil }
        #endif

        // Return a normalized absolute string
        return comps.url?.absoluteString
    }
    
    // Guard against speaking while app not active (prevents odd resumes)
    private func safeSpeakAndWait(_ text: String, language: String? = nil) async {
        guard scenePhase == .active else { return }
        await tts.speakAndWait(text, stt: stt, language: language)  // speakAndWait routes once; speak(route:false)
    }
    
    @MainActor
    func switchDeck(to deck: String) async {
        guard let base = validatedBaseURL(),
              let encodedDeck = deck.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(base)/switch-deck?name=\(encodedDeck)") else {
            await tts.speakAndWait("Invalid server URL.")
            return
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        authService.addAuthHeader(to: &req)
        
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                await tts.speakAndWait("Couldn't switch decks.")
                return
            }
            
            // After switching, fetch the now-current card and proceed as normal
            if let c = await fetchCurrentCard(),
               c.status == "ok",
               let cid = c.cardId, let front = c.front_text, let back = c.back_text {
                current = c
                #if os(iOS)
                await director.handle(.toTTS(stt))
                #endif
                state = .readingFront(cardId: cid, front: front, back: back)
                let frontTTS = c.front_text_tts ?? front
                let frontLang = c.front_language
                await safeSpeakAndWait(frontTTS, language: frontLang)
                state = .awaitingAnswer(cardId: cid, front: front, back: back)
                await startAnswerPhase(cardId: cid, front: front, back: back)
            } else {
                // Deck may have 0 due cards ("Congratulations")
                await tts.speakAndWait("No cards due in \(deck).")
            }
        } catch {
            await tts.speakAndWait("Cannot reach Anki.")
        }
    }
    
    @MainActor
    func fetchDecks() async {
        guard let base = validatedBaseURL(),
              let url = URL(string: "\(base)/decks") else {
            return
        }
        
        isLoadingDecks = true
        defer { isLoadingDecks = false }
        
        do {
            var req = URLRequest(url: url)
            authService.addAuthHeader(to: &req)
            
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                return
            }
            
            struct DecksResponse: Decodable {
                let status: String
                let decks: [String]
            }
            
            let decoded = try JSONDecoder().decode(DecksResponse.self, from: data)
            if decoded.status == "ok" {
                await MainActor.run {
                    availableDecks = decoded.decks.sorted()
                    // If no deck is selected and we have decks, optionally select the first one
                    if selectedDeck.isEmpty && !availableDecks.isEmpty {
                        // Don't auto-select, let user choose
                    }
                }
            }
        } catch {
            // Silently fail - user can retry
        }
    }
    
    @MainActor
    func fetchDeckStats(for deckName: String) async {
        #if DEBUG
        print("[DECK_STATS] ===== Starting fetchDeckStats for deck: '\(deckName)' =====")
        #endif
        
        guard let base = validatedBaseURL() else {
            #if DEBUG
            print("[DECK_STATS] ❌ validatedBaseURL() returned nil")
            print("[DECK_STATS] Current server value: '\(server)'")
            #endif
            return
        }
        
        #if DEBUG
        print("[DECK_STATS] Base URL: \(base)")
        #endif
        
        // Use URLComponents for proper URL construction
        guard var components = URLComponents(string: base) else {
            #if DEBUG
            print("[DECK_STATS] ❌ Failed to create URLComponents from base: \(base)")
            #endif
            return
        }
        
        // Determine endpoint path based on whether we're authenticated (production) or not (local dev)
        let endpointPath = authService.isAuthenticated ? "/anki/deck-stats" : "/deck-stats"
        components.path = endpointPath
        components.queryItems = [URLQueryItem(name: "name", value: deckName)]
        
        guard let url = components.url else {
            #if DEBUG
            print("[DECK_STATS] ❌ Failed to create URL from components")
            #endif
            return
        }
        
        #if DEBUG
        print("[DECK_STATS] ✅ URL created: \(url.absoluteString)")
        print("[DECK_STATS] Using endpoint path: \(endpointPath)")
        print("[DECK_STATS] Deck name: '\(deckName)'")
        print("[DECK_STATS] Is authenticated: \(authService.isAuthenticated)")
        #endif
        
        isLoadingDeckStats = true
        defer { 
            isLoadingDeckStats = false
            #if DEBUG
            print("[DECK_STATS] ===== Finished fetchDeckStats =====")
            #endif
        }
        
        do {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            
            #if DEBUG
            print("[DECK_STATS] Checking authentication...")
            print("[DECK_STATS] isAuthenticated: \(authService.isAuthenticated)")
            #endif
            
            authService.addAuthHeader(to: &req)
            
            #if DEBUG
            print("[DECK_STATS] Request details:")
            print("[DECK_STATS]   Method: \(req.httpMethod ?? "N/A")")
            print("[DECK_STATS]   URL: \(req.url?.absoluteString ?? "N/A")")
            print("[DECK_STATS]   All headers:")
            for (key, value) in req.allHTTPHeaderFields ?? [:] {
                if key.lowercased() == "authorization" {
                    let preview = value.prefix(30) + "..."
                    print("[DECK_STATS]     \(key): \(preview)")
                } else {
                    print("[DECK_STATS]     \(key): \(value)")
                }
            }
            if let authHeader = req.value(forHTTPHeaderField: "Authorization") {
                print("[DECK_STATS] ✅ Authorization header present")
                print("[DECK_STATS]   Format check: \(authHeader.hasPrefix("Bearer ") ? "✅ Correct (Bearer prefix)" : "❌ Missing 'Bearer ' prefix")")
                let tokenPart = authHeader.replacingOccurrences(of: "Bearer ", with: "")
                print("[DECK_STATS]   Token length: \(tokenPart.count) characters")
                print("[DECK_STATS]   Token preview: \(tokenPart.prefix(20))...")
            } else {
                print("[DECK_STATS] ⚠️ No Authorization header added")
            }
            #endif
            
            #if DEBUG
            print("[DECK_STATS] Making HTTP request...")
            #endif
            
            let (data, resp) = try await URLSession.shared.data(for: req)
            
            #if DEBUG
            print("[DECK_STATS] ✅ Received response")
            print("[DECK_STATS] Response data length: \(data.count) bytes")
            if let responseString = String(data: data, encoding: .utf8) {
                print("[DECK_STATS] Response body: \(responseString)")
            } else {
                print("[DECK_STATS] ⚠️ Could not decode response as UTF-8")
            }
            #endif
            
            guard let httpResponse = resp as? HTTPURLResponse else {
                #if DEBUG
                print("[DECK_STATS] ❌ Invalid response type: \(type(of: resp))")
                #endif
                deckNewCount = nil
                deckReviewCount = nil
                return
            }
            
            #if DEBUG
            print("[DECK_STATS] HTTP Status Code: \(httpResponse.statusCode)")
            if let headers = httpResponse.allHeaderFields as? [String: String] {
                print("[DECK_STATS] Response headers: \(headers)")
            }
            #endif
            
            struct DeckStatsResponse: Decodable {
                let status: String
                let deck: String
                let new: Int
                let review: Int
            }
            
            switch httpResponse.statusCode {
            case 200:
                #if DEBUG
                print("[DECK_STATS] ✅ HTTP 200 - Attempting to decode JSON...")
                #endif
                do {
                    let decoded = try JSONDecoder().decode(DeckStatsResponse.self, from: data)
                    #if DEBUG
                    print("[DECK_STATS] ✅ JSON decoded successfully")
                    print("[DECK_STATS] Decoded response - status: '\(decoded.status)', deck: '\(decoded.deck)', new: \(decoded.new), review: \(decoded.review)")
                    #endif
                    
                    if decoded.status == "ok" {
                        await MainActor.run {
                            deckNewCount = decoded.new
                            deckReviewCount = decoded.review
                        }
                        #if DEBUG
                        print("[DECK_STATS] ✅ Successfully set counts - New: \(decoded.new), Review: \(decoded.review)")
                        #endif
                    } else {
                        #if DEBUG
                        print("[DECK_STATS] ⚠️ Response status not 'ok': '\(decoded.status)'")
                        #endif
                        deckNewCount = nil
                        deckReviewCount = nil
                    }
                } catch let decodeError {
                    #if DEBUG
                    print("[DECK_STATS] ❌ JSON decode failed: \(decodeError)")
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("[DECK_STATS] Raw JSON string: \(jsonString)")
                    }
                    #endif
                    deckNewCount = nil
                    deckReviewCount = nil
                }
            case 404:
                #if DEBUG
                print("[DECK_STATS] ❌ HTTP 404 - Endpoint or deck not found")
                if let errorBody = String(data: data, encoding: .utf8) {
                    print("[DECK_STATS] Error response: \(errorBody)")
                    // If error says "Deck not found", it's a valid 404 for the deck
                    // If error just says "Not Found", the endpoint might not exist
                    if errorBody.contains("Deck not found") {
                        print("[DECK_STATS] Deck '\(deckName)' doesn't exist in Anki")
                    } else {
                        print("[DECK_STATS] Endpoint '\(endpointPath)' might not exist or routing issue")
                    }
                }
                #endif
                // Set to 0 instead of nil so UI shows "New: 0 Review: 0" instead of nothing
                await MainActor.run {
                    deckNewCount = 0
                    deckReviewCount = 0
                }
            case 401:
                #if DEBUG
                print("[DECK_STATS] ❌ HTTP 401 - Unauthorized (invalid or expired token)")
                if let errorBody = String(data: data, encoding: .utf8) {
                    print("[DECK_STATS] Error response: \(errorBody)")
                }
                #endif
                deckNewCount = nil
                deckReviewCount = nil
            case 502:
                #if DEBUG
                print("[DECK_STATS] ❌ HTTP 502 - Bad Gateway (AnkiConnect error)")
                if let errorBody = String(data: data, encoding: .utf8) {
                    print("[DECK_STATS] Error response: \(errorBody)")
                }
                #endif
                deckNewCount = nil
                deckReviewCount = nil
            default:
                #if DEBUG
                print("[DECK_STATS] ❌ HTTP error: \(httpResponse.statusCode)")
                if let errorBody = String(data: data, encoding: .utf8) {
                    print("[DECK_STATS] Error response: \(errorBody)")
                }
                #endif
                deckNewCount = nil
                deckReviewCount = nil
            }
        } catch let error {
            #if DEBUG
            print("[DECK_STATS] ❌ Exception occurred: \(error)")
            print("[DECK_STATS] Error type: \(type(of: error))")
            print("[DECK_STATS] Error description: \(error.localizedDescription)")
            if let urlError = error as? URLError {
                print("[DECK_STATS] URLError code: \(urlError.code.rawValue)")
                print("[DECK_STATS] URLError description: \(urlError.localizedDescription)")
            }
            #endif
            deckNewCount = nil
            deckReviewCount = nil
        }
    }
    
    @MainActor
    private func showBackNowAndPrepareToListen(_ cid: Int, _ front: String, _ back: String) {
        // Show the back immediately; this sets the UI to "Answer"+answer text at once.
        state = .awaitingAction(cardId: cid, front: front, back: back)
        showBackDuringProcessing = false
    }

    var stateDescription: String {
        switch state {
        case .idle: return "Idle"
        case .readingFront: return "Reading Front"
        case .awaitingAnswer: return "Awaiting Answer"
        case .explaining: return "Explaining"
        case .awaitingAction: return "Awaiting Action"
        case .confirmingGrade: return "Confirming Grade"
        case .confirmingDelete: return "Confirming Delete"
        }
    }
    
    private func applyKeepAwake() {
        #if os(iOS)
        let reviewActive = (state != .idle)
        let appActive = (scenePhase == .active)
        UIApplication.shared.isIdleTimerDisabled = (reviewActive && appActive)
        #endif
    }
    
    private var displayTitle: String {
        switch state {
        case .readingFront, .awaitingAnswer: return showBackDuringProcessing ? "Answer" : "Question"
        case .explaining, .awaitingAction:   return "Answer"
        case .confirmingGrade, .confirmingDelete: return "Confirm"
        case .idle:                          return ""
        }
    }

    private var displayText: String {
        switch state {
        case .readingFront(_, let front, _):                      return front
        case .awaitingAnswer(_, let front, let back):             return showBackDuringProcessing ? back : front
        case .explaining(_, _, let back, _):                      return back
        case .awaitingAction(_, _, let back):                     return back
        case .confirmingGrade(_, _, _, let back):         return back
        case .confirmingDelete(_, _, let back):             return back
        case .idle:                                               return ""
        }
    }

    private var shouldShowTranscript: Bool {
        if case .awaitingAnswer = state {
            return !stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !showBackDuringProcessing
        }
        return false
    }
    
    func authorizeSpeechAndMic() {
        permissionErrorMessage = nil
        
        // Verify Info.plist keys are present in built app
        #if DEBUG
        if Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil {
            print("ERROR: NSMicrophoneUsageDescription missing from built Info.plist")
            permissionErrorMessage = "Configuration error: microphone description missing. Check Xcode target membership."
            return
        }
        if Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") == nil {
            print("ERROR: NSSpeechRecognitionUsageDescription missing from Info.plist")
        }
        #endif
        
        // CRITICAL FIX: If we've never made a real mic request on this install, do it now.
        // iOS only shows the Microphone toggle in Settings after the app calls requestRecordPermission at least once.
        if !didRequestMicOnce {
            #if DEBUG
            print("[PERM] First-time mic request (forcing real request to create Settings entry)")
            #endif
            MicPermission.request { granted in
                Task { @MainActor in
                    self.didRequestMicOnce = true
                    self.micAuthorized = granted
                    if granted {
                        self.requestSpeech()
                    } else {
                        // Now that we requested once, Settings should show the toggle
                        self.permissionErrorMessage = "Microphone access was denied. Enable it in Settings → AnkiVoice → Microphone, or go to Settings → Privacy & Security → Microphone."
                    }
                }
            }
            return
        }
        
        // Normal path after first request: check state first
        switch MicPermission.state() {
        case .granted:
            Task { @MainActor in
                micAuthorized = true
                requestSpeech()       // chain to speech
            }
        case .undetermined:
            MicPermission.request { granted in
                Task { @MainActor in
                    self.micAuthorized = granted
                    if granted {
                        self.requestSpeech()
                    } else {
                        self.permissionErrorMessage = "Microphone access was denied. Enable it in Settings → AnkiVoice → Microphone, or go to Settings → Privacy & Security → Microphone."
                    }
                }
            }
        case .denied:
            Task { @MainActor in
                micAuthorized = false
                permissionErrorMessage = "Microphone permission was previously denied. Enable it in Settings → AnkiVoice → Microphone, or go to Settings → Privacy & Security → Microphone."
            }
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
    
    /// Check current authorization status without requesting permissions
    /// This is called on app startup to check if permissions are already granted
    private func checkAuthorizationStatus() {
        // Check microphone permission
        switch MicPermission.state() {
        case .granted:
            micAuthorized = true
            // If mic is granted, check speech recognition
            switch SpeechPermission.state() {
            case .granted:
                speechAuthorized = true
            case .undetermined, .denied:
                speechAuthorized = false
            }
        case .undetermined, .denied:
            micAuthorized = false
            speechAuthorized = false
        }
    }

    @MainActor
    func syncAnki() async {
        // Use auth service to sync via backend API
        guard authService.isAuthenticated else {
            await tts.speakAndWait("Please sign in first.")
            return
        }
        
        isSyncing = true
        defer { isSyncing = false }
        
        do {
            let response = try await authService.syncAnki()
            if response.status == "ok" {
                await tts.speakAndWait("Sync complete.")
            } else {
                await tts.speakAndWait("Sync may have failed.")
            }
        } catch let authError as AuthError {
            let errorDetails: String
            switch authError {
            case .serverError(let code, let message):
                errorDetails = "Server error \(code): \(message)"
                appLog("❌ [SYNC] Server error \(code): \(message)", category: "sync")
            case .notAuthenticated:
                errorDetails = "Not authenticated. Please sign in."
                appLog("❌ [SYNC] Not authenticated", category: "sync")
            case .invalidURL:
                errorDetails = "Invalid API URL"
                appLog("❌ [SYNC] Invalid URL", category: "sync")
            case .invalidResponse:
                errorDetails = "Invalid response from server"
                appLog("❌ [SYNC] Invalid response", category: "sync")
            default:
                errorDetails = authError.localizedDescription
                appLog("❌ [SYNC] Auth error: \(authError.localizedDescription)", category: "sync")
            }
            await tts.speakAndWait("Cannot sync. \(errorDetails)")
        } catch let urlError as URLError {
            let errorDetails = "Network error: \(urlError.localizedDescription) (code: \(urlError.code.rawValue))"
            appLog("❌ [SYNC] Network error: \(urlError.localizedDescription) (code: \(urlError.code.rawValue))", category: "sync")
            await tts.speakAndWait("Cannot sync. \(errorDetails)")
        } catch {
            let errorDetails = "\(error.localizedDescription)"
            appLog("❌ [SYNC] Unexpected error: \(error) - \(error.localizedDescription)", category: "sync")
            appLog("   Error type: \(type(of: error))", category: "sync")
            await tts.speakAndWait("Cannot sync. \(errorDetails)")
        }
    }
    
    // AnkiWeb linking removed - sync credentials are auto-generated on registration/login
    
    @MainActor
    func returnToDeckSelection() async {
        // Stop all audio I/O
        stopAllIO(deactivateSession: true)
        
        // Cancel any ongoing network tasks
        currentNetworkTask?.cancel()
        currentNetworkTask = nil
        listeningTask?.cancel()
        listeningTask = nil
        
        // Reset state to idle
        state = .idle
        current = nil
        showBackDuringProcessing = false
        hasPromptedForAnswer = false
        isListening = false
        
        // Re-fetch deck stats if a deck is selected
        if !selectedDeck.isEmpty {
            await fetchDeckStats(for: selectedDeck)
        }
        
        #if DEBUG
        print("[RETURN] Returned to deck selection")
        #endif
    }
    
    func startReview() async {
        // Prevent concurrent runs (covers voice-initiated paths too)
        if isBusy { 
            #if DEBUG
            print("[START_REVIEW] EXITING EARLY - isBusy is true!")
            #endif
            return 
        }
        isBusy = true
        defer { isBusy = false }
        
        #if DEBUG
        print("[START_REVIEW] Called, current state=\(state), previous cardId=\(current?.cardId?.description ?? "nil")")
        #endif
        
        // ✅ FIRST THING: Assert routing before any network operations
        #if os(iOS)
        await director.handle(.toTTS(stt))
        #endif
        
        // If a deck is selected, switch to it before starting review
        if !selectedDeck.isEmpty {
            guard let base = validatedBaseURL(),
                  let encodedDeck = selectedDeck.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "\(base)/switch-deck?name=\(encodedDeck)") else {
                await tts.speakAndWait("Invalid server URL.")
                return
            }
            
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            authService.addAuthHeader(to: &req)
            
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    await tts.speakAndWait("Couldn't switch decks.")
                    return
                }
            } catch {
                await tts.speakAndWait("Cannot reach Anki.")
                return
            }
        }
        
        // Reset prompt flag for new card
        hasPromptedForAnswer = false
        showBackDuringProcessing = false
        
        // 1) Sanity test: fetch current card with retry and logging
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 7.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config)
        
        guard let base = validatedBaseURL() else {
            #if DEBUG
            print("[START_REVIEW] ERROR: validatedBaseURL() returned nil. server='\(server)'")
            #endif
            tts.speak("Invalid server URL.")
            return
        }
        
        guard let url = URL(string: "\(base)/current") else {
            #if DEBUG
            print("[START_REVIEW] ERROR: Failed to create URL from base='\(base)'")
            #endif
            tts.speak("Invalid server URL.")
            return
        }
        
        #if DEBUG
        print("[START_REVIEW] Fetching from URL: \(url.absoluteString)")
        #endif
        
        // Test connectivity first and log the result
        var card: CurrentCard?
        for attempt in 0..<2 {
                do {
                    var req = URLRequest(url: url)
                    authService.addAuthHeader(to: &req)
                    let (data, response) = try await session.data(for: req)
                    if let httpResponse = response as? HTTPURLResponse {
                        #if DEBUG
                        print("[CURRENT_CARD] GET /current: HTTP \(httpResponse.statusCode)")
                        let responseBody = String(data: data, encoding: .utf8) ?? "<non-utf8>"
                        print("[CURRENT_CARD] Response body length: \(data.count) bytes")
                        print("[CURRENT_CARD] Response body (first 1000 chars): \(String(responseBody.prefix(1000)))")
                        if httpResponse.statusCode != 200 {
                            print("[CURRENT_CARD] ERROR: Non-200 status. Full body: \(responseBody)")
                        }
                        #endif
                    }
                    do {
                    let decoded = try JSONDecoder().decode(CurrentCard.self, from: data)
                    #if DEBUG
                    print("[CURRENT_CARD] Successfully decoded card")
                    print("[CURRENT_CARD]   status: \(decoded.status)")
                    print("[CURRENT_CARD]   cardId: \(decoded.cardId?.description ?? "nil")")
                    print("[CURRENT_CARD]   front_text: \(decoded.front_text?.prefix(50) ?? "nil")")
                    print("[CURRENT_CARD]   back_text: \(decoded.back_text?.prefix(50) ?? "nil")")
                    print("[CURRENT_CARD]   front_text present: \(decoded.front_text != nil)")
                    print("[CURRENT_CARD]   back_text present: \(decoded.back_text != nil)")
                    print("[CURRENT_CARD]   front_text empty: \(decoded.front_text?.isEmpty ?? true)")
                    print("[CURRENT_CARD]   back_text empty: \(decoded.back_text?.isEmpty ?? true)")
                    #endif
                    if decoded.status == "ok" {
                        card = decoded
                        #if DEBUG
                        print("[CURRENT_CARD] ✅ Card status is 'ok', using it")
                        #endif
                        break
                    } else {
                        #if DEBUG
                        print("[CURRENT_CARD] ⚠️  Card status is not 'ok': '\(decoded.status)'")
                        #endif
                    }
                } catch {
                    #if DEBUG
                    print("[CURRENT_CARD] JSON decode error: \(error)")
                    print("[CURRENT_CARD] Raw response data: \(String(data: data, encoding: .utf8)?.prefix(500) ?? "<non-utf8>")")
                    #endif
                }
            } catch {
                // Check if this is a connection refused error (server not running)
                // URLError.cannotConnectToHost = -1004, also check raw NSError code
                let nsError = error as NSError
                #if DEBUG
                print("Network error fetching /current:", error)
                print("  Error domain: \(nsError.domain), code: \(nsError.code)")
                if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
                    print("  Underlying error code: \(underlying.code)")
                }
                #endif
                
                let isConnectionRefused: Bool = {
                    if let urlError = error as? URLError {
                        return urlError.code == .cannotConnectToHost
                    }
                    // NSURLErrorCannotConnectToHost = -1004
                    if nsError.domain == NSURLErrorDomain && nsError.code == -1004 {
                        return true
                    }
                    // Also check for ECONNREFUSED (61) in underlying error
                    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                       underlying.code == 61 { // ECONNREFUSED
                        return true
                    }
                    return false
                }()
                
                if isConnectionRefused {
                    #if DEBUG
                    print("[START_REVIEW] Detected connection refused - server not running")
                    #endif
                    // Use the descriptive error helper
                    let errorMsg = describeURLError(error)
                    speakErrorIfAllowed(errorMsg)
                    return
                }
                
                // For other network errors, provide helpful message
                let errorMsg = describeURLError(error)
                if !errorMsg.isEmpty && errorMsg != "Network error." {
                    speakErrorIfAllowed(errorMsg)
                }
                
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms retry
                }
            }
        }
        
        guard let finalCard = card,
              let front = finalCard.front_text,
              let back = finalCard.back_text,
              let cid = finalCard.cardId else {
            #if DEBUG
            print("[START_REVIEW] ❌ No valid card available")
            print("[START_REVIEW]   card == nil: \(card == nil)")
            if let c = card {
                print("[START_REVIEW]   card.status: \(c.status)")
                print("[START_REVIEW]   card.cardId: \(c.cardId?.description ?? "nil")")
                print("[START_REVIEW]   card.front_text present: \(c.front_text != nil)")
                print("[START_REVIEW]   card.front_text empty: \(c.front_text?.isEmpty ?? true)")
                print("[START_REVIEW]   card.back_text present: \(c.back_text != nil)")
                print("[START_REVIEW]   card.back_text empty: \(c.back_text?.isEmpty ?? true)")
            }
            #endif
            
            // Distinguish between connection errors and no card available
            if card == nil {
                // No card means either server error or Anki not ready
                // Check if we got a network error (would have returned above)
                // Otherwise assume Anki isn't ready
                tts.speak("Open Anki on your Mac and start a review.")
            } else {
                // Got a response but no valid card
                tts.speak("No card available. Open Anki and start a review.")
            }
            // Even if no card, update state so user knows something happened
            // Don't leave it stuck in idle
            return
        }
        
        // Check if we got the same card we just graded (Anki hasn't advanced yet)
        // This can happen if we call startReview() too quickly after submitting a grade
        if let previousCardId = current?.cardId, previousCardId == cid {
            #if DEBUG
            print("[START_REVIEW] Got same card ID (\(cid)), Anki hasn't advanced yet. Waiting and retrying...")
            #endif
            // Wait a bit longer for Anki to process the grade and advance
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            
            // Retry once to get the new card
            if let retryUrl = URL(string: "\(validatedBaseURL() ?? "")/current") {
                let retryConfig = URLSessionConfiguration.default
                retryConfig.timeoutIntervalForRequest = 3.0
                retryConfig.timeoutIntervalForResource = 5.0
                let retrySession = URLSession(configuration: retryConfig)
                
                if let (retryData, _) = try? await retrySession.data(from: retryUrl),
                   let retryCard = try? JSONDecoder().decode(CurrentCard.self, from: retryData),
                   retryCard.status == "ok",
                   let newCid = retryCard.cardId,
                   newCid != cid,
                   let newFront = retryCard.front_text,
                   let newBack = retryCard.back_text {
                    // Got a different card - use it
                    #if DEBUG
                    print("[START_REVIEW] Retry successful, got new card: \(newCid)")
                    #endif
                    current = retryCard
                    state = .readingFront(cardId: newCid, front: newFront, back: newBack)
                    await safeSpeakAndWait(newFront)
                    state = .awaitingAnswer(cardId: newCid, front: newFront, back: newBack)
                    await startAnswerPhase(cardId: newCid, front: newFront, back: newBack)
                    return
                }
            }
            // If retry failed, proceed with the same card (might be last card in session)
            #if DEBUG
            print("[START_REVIEW] Retry failed or still same card, proceeding with current card")
            #endif
        }
        
        #if DEBUG
        print("[START_REVIEW] Got card: id=\(cid), front='\(front.prefix(50))...', back='\(back.prefix(50))...'")
        #endif
        
        current = finalCard
        
        // ✅ RE-ASSERT after network (session may have changed during fetch)
        #if os(iOS)
        await director.handle(.toTTS(stt))
        #endif
        
        // 2) Move to readingFront and speak front
        state = .readingFront(cardId: cid, front: front, back: back)
        #if DEBUG
        print("[START_REVIEW] ✅ State changed to readingFront, cardId=\(cid), front='\(front.prefix(30))...'")
        #endif
        
        // Wait for TTS to finish before starting to listen
        // Orchestrator handles TTS→STT transition with quiet fence
        let frontTTS = current?.front_text_tts ?? front
        let frontLang = current?.front_language
        await safeSpeakAndWait(frontTTS, language: frontLang)
        
        // Additional settle after TTS finishes to ensure echo has fully died down
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms additional settle
        
        // 3) Move to awaitingAnswer and start answer phase
        state = .awaitingAnswer(cardId: cid, front: front, back: back)
        #if DEBUG
        print("[START_REVIEW] ✅ State changed to awaitingAnswer, cardId=\(cid)")
        #endif
        await startAnswerPhase(cardId: cid, front: front, back: back)
    }

    func startAnswerPhase(cardId: Int, front: String, back: String) async {
        // Ask once, then keep listening
        if !hasPromptedForAnswer {
            hasPromptedForAnswer = true
            await tts.speakAndWait("What's your answer?", stt: stt)
            // Orchestrator already handled the TTS→STT transition with quiet fence
            // Additional settle to ensure TTS audio has fully stopped
            try? await Task.sleep(nanoseconds: 200_000_000) // 200ms after prompt
        }
        
        // Clear transcript before starting to listen to avoid any TTS echo
        stt.transcript = ""
        stt.isFinal = false
        
        await listenForAnswerContinuous()
    }

    func listenForAnswerContinuous() async {
        // Orchestrator manages STT phase transitions; just start recognition if needed
        do {
            isListening = true
            #if os(iOS)
            // Enter STT phase (opens mic gate after quiet fence and starts recognition)
            await director.handle(.toSTT(stt))
            #else
            try await stt.startRecognitionIfNeeded()
            #endif
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
                #if os(iOS)
                // Assert liveness without re-entering STT (no duplicate quiet fence)
                await director.handle(.assertSTTRunning(stt))
                #else
                try? await stt.startRecognitionIfNeeded()
                #endif
            }
            
            // Debounce logic: finalize after explicit 2s silence window (duration-based)
            let tickNs: UInt64 = 250_000_000        // 250ms checks (smoother)
            let silenceWindowNs: UInt64 = 2_000_000_000  // 2.0s required silence
            let minListenNs: UInt64 = 1_200_000_000      // ignore isFinal before 1.2s total listen
            let hardCapNs: UInt64 = 15_000_000_000       // hard stop after 15s
            let started = DispatchTime.now()
            var lastText = ""
            var lastChange = started
            var lastPrintedTick = 0

            while case .awaitingAnswer = state {
                // Check for cancellation
                if Task.isCancelled {
                    stt.stop()
                    isListening = false
                    return
                }
                
                // Liveness check (debugging)
                stt.ensureTaskLiveness()
                
                try? await Task.sleep(nanoseconds: tickNs)

                let now = DispatchTime.now()
                let elapsedNs = now.uptimeNanoseconds - started.uptimeNanoseconds
                let text = stt.transcript.trimmingCharacters(in: .whitespacesAndNewlines)

                // Debug breadcrumb every ~2.5s
                #if DEBUG
                lastPrintedTick += 1
                if lastPrintedTick % 10 == 1 {
                    let secs = Double(elapsedNs) / 1e9
                    print("[Answer] live transcript: '\(text)' (elapsed \(String(format: "%.1f", secs))s)")
                }
                #endif

                // Track "silence" as "no transcript change"
                if text != lastText {
                    lastText = text
                    lastChange = now
                }
                let silenceNs = now.uptimeNanoseconds - lastChange.uptimeNanoseconds

                // Primary stop condition: 2.0s of silence and we have some content
                if !text.isEmpty && silenceNs >= silenceWindowNs {
                    break
                }

                // Treat isFinal only as a hint: honor it after we've listened a bit AND
                // either have 2.0s silence or at least a short 0.8s pause as a compromise.
                // If you want strictly 2.0s always, remove the 0.8s clause.
                if stt.isFinal && !text.isEmpty && elapsedNs >= minListenNs {
                    if silenceNs >= 800_000_000 || silenceNs >= silenceWindowNs {
                        break
                    }
                }

                // Punctuation heuristic: only if we also observed ~1.2s of quiet
                if let c = text.last, [".","?","!"].contains(c), silenceNs >= 1_200_000_000 {
                    break
                }

                // Hard cap (safety)
                if elapsedNs >= hardCapNs {
                    break
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

            let lower = transcript.lowercased()
            
            // 1) Reread Question phrases (stay in answer phase, just reread the question)
            let rereadQuestionPhrases = [
                "reread question", "reread the question", "say the question again", "read question again", "repeat question", "repeat the question"
            ]
            if rereadQuestionPhrases.contains(where: { lower.contains($0) }) {
                stt.stop()
                isListening = false
                await handleRereadQuestion()
                return
            }
            
            // 2) Reread Answer phrases (stay in answer phase, just reread)
            let rereadAnswerPhrases = [
                "reread answer", "reread the answer", "say the answer again", "read answer again"
            ]
            if rereadAnswerPhrases.contains(where: { lower.contains($0) }) {
                stt.stop()
                isListening = false
                await handleRereadAnswer()
                return
            }
            
            // 3) Read Answer phrases (skip LLM, read back and go to action phase)
            let readAnswerPhrases = [
                "read answer", "read the answer", "show answer", "tell me the answer"
            ]
            if readAnswerPhrases.contains(where: { lower.contains($0) }) {
                stt.stop()
                isListening = false
                await handleReadAnswer()
                return
            }
            
            // 4) Immediate grade phrases (skip LLM, submit grade)
            switch IntentParser.parse(lower) {
            case .grade(let ease, let canonical, let unambiguous) where unambiguous:
                // We are in .awaitingAnswer; grade and advance immediately
                stt.stop()
                isListening = false
                guard case .awaitingAnswer(let cid2, let front2, let back2) = state else { return }
                // Reveal the back in our UI and ensure Anki is on the answer side
                let prev = state
                state = .awaitingAction(cardId: cid2, front: front2, back: back2)
                await ensureAnswerShownIfNeeded(previousState: prev)
                var ok = await submitGrade(cardId: cid2, ease: ease)
                if !ok {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    ok = await submitGrade(cardId: cid2, ease: ease)
                }
                if ok {
                    #if os(iOS)
                    await director.handle(.toTTS(stt))
                    #endif
                    await tts.speakAndWait("Marked \(canonical). \(undoPrompt())")
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    await advanceToNextCard(previousCardId: cid2)
                } else {
                    tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    await listenForAction()
                }
                return

            default:
                break
            }
            
            // 5) Delete note phrases (confirm before deleting)
            let deleteNotePhrases = [
                "delete note", "delete the note", "remove note", "remove the note", "delete this note", "delete card", "delete the card"
            ]
            if deleteNotePhrases.contains(where: { lower.contains($0) }) {
                stt.stop()
                isListening = false
                guard case .awaitingAnswer(let cid2, let front2, let back2) = state else { return }
                state = .confirmingDelete(cardId: cid2, front: front2, back: back2)
                await tts.speakAndWait("Delete this note? Say confirm to delete, or say cancel.")
                try? await Task.sleep(nanoseconds: 300_000_000)
                await listenForDeleteConfirmation()
                return
            }
            
            // 6) "I don't know" flow (skip LLM, read back)
            let skipLLMPhrases = ["i don't know", "i have no idea", "i'm not sure", "no idea", "don't know", "i dunno"]
            if skipLLMPhrases.contains(where: { lower.contains($0) }) {
                stt.stop()
                isListening = false
                // Show answer immediately, then speak
                showBackNowAndPrepareToListen(cid2, front2, back2)
                let backTTS = current?.back_text_tts ?? back2
                let backLang = current?.back_language
                await safeSpeakAndWait(backTTS, language: backLang)
                try? await Task.sleep(nanoseconds: 50_000_000)
                await listenForAction()
                return
            }
            
            // 7) Undo phrases (undo last grade and go back to previous card)
            let undoPhrases = ["undo", "change", "take back", "undo that", "change that"]
            if undoPhrases.contains(where: { lower.contains($0) }) {
                stt.stop()
                isListening = false
                await undoLastGrade()
                // undoLastGrade will call startReview() to go back to previous card
                return
            }

            // 8) Normal path: grade with explanation
            stt.stop()
            isListening = false
            await MainActor.run { showBackDuringProcessing = true }  // show the back while LLM is working
            currentNetworkTask?.cancel()
            currentNetworkTask = Task { await getExplanation(transcript: transcript) }
            return
        }
        
        // Fell out of loop - state changed
        stt.stop()
        isListening = false
    }
    
    func handleGradeButton(_ ease: Int) async {
        // stop IO & cancel network when we're leaving whatever we're doing
        func stopForTransition(_ willListen: Bool = false) {
            // keep session active only if we'll immediately listen again
            stopAllIO(deactivateSession: !willListen)
            currentNetworkTask?.cancel()
            currentNetworkTask = nil
            showBackDuringProcessing = false
        }

        switch state {
        case .idle:
            return

        case .readingFront(let cid, let front, let back):
            // behave like old SKIP: jump to answer phase (don't submit)
            stopForTransition(true)
            state = .awaitingAnswer(cardId: cid, front: front, back: back)
            await startAnswerPhase(cardId: cid, front: front, back: back)

        case .awaitingAnswer(let cid, let front, let back):
            // Show the back, ensure reviewer is on answer side, then grade (one tap)
            stopForTransition(true)
            let prev = state
            // Reveal in our UI immediately so the user sees the answer
            showBackNowAndPrepareToListen(cid, front, back)
            await ensureAnswerShownIfNeeded(previousState: prev)
            // Try grade; if it fails once (e.g., Anki still flipping), retry after a short settle
            var ok = await submitGrade(cardId: cid, ease: ease)
            if !ok {
                try? await Task.sleep(nanoseconds: 150_000_000)
                ok = await submitGrade(cardId: cid, ease: ease)
            }
            if ok {
                #if os(iOS)
                await director.handle(.toTTS(stt))
                #endif
                await tts.speakAndWait("\(canonicalName(ease)). \(undoPrompt())")
                try? await Task.sleep(nanoseconds: 80_000_000)
                await advanceToNextCard(previousCardId: cid)
            } else {
                tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
                // fall back to action so user can retry by voice or buttons
                try? await Task.sleep(nanoseconds: 150_000_000)
                await listenForAction()
            }

        case .explaining(let cid, let front, let back, _):
            // Also immediate grade while explaining
            // Configure TTS BEFORE stopping to put session in speaker-safe state
            #if os(iOS)
            await director.handle(.toTTS(stt))
            #endif
            tts.stopSpeaking()
            
            // Do NOT call stopAllIO(true) here; we aren't about to deactivate.
            // Only stop STT if it's running to avoid unnecessary session churn
            if stt.isRunning {
                stt.stop()
            }
            
            state = .awaitingAction(cardId: cid, front: front, back: back)
            let ok = await submitGrade(cardId: cid, ease: ease)
            if ok {
                #if os(iOS)
                await director.handle(.toTTS(stt))  // re-assert after any internal changes
                try? await Task.sleep(nanoseconds: 50_000_000)  // 50 ms settle
                #endif
                await tts.speakAndWait("\(canonicalName(ease)). \(undoPrompt())")
                try? await Task.sleep(nanoseconds: 80_000_000)
                await advanceToNextCard(previousCardId: cid)
            } else {
                tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
                try? await Task.sleep(nanoseconds: 150_000_000)
                await listenForAction()
            }

        case .awaitingAction(let cid, _, _):
            // Prevent concurrent grade submissions
            if isSubmittingGrade { return }
            isSubmittingGrade = true
            defer { isSubmittingGrade = false }
            
            // submit immediately and advance
            // Stop STT and listening before submitting grade (same as voice command path)
            // Cancel any running listening task
            listeningTask?.cancel()
            listeningTask = nil
            stt.stop()
            isListening = false
            let ok = await submitGrade(cardId: cid, ease: ease)
            if ok {
                #if os(iOS)
                await director.handle(.toTTS(stt))
                #endif
                await tts.speakAndWait("\(canonicalName(ease)). \(undoPrompt())")
                try? await Task.sleep(nanoseconds: 80_000_000)
                await advanceToNextCard(previousCardId: cid)
            } else {
                tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
            }

        case .confirmingGrade(let cid, let easeToConfirm, let front, let back):
            // Replace confirmation flow: pressing any grade button confirms the pending grade
            let ok = await submitGrade(cardId: cid, ease: easeToConfirm)
            if ok {
                #if os(iOS)
                await director.handle(.toTTS(stt))
                #endif
                await tts.speakAndWait("\(canonicalName(easeToConfirm)). \(undoPrompt())")
                try? await Task.sleep(nanoseconds: 80_000_000)
                await advanceToNextCard(previousCardId: cid)
            } else {
                tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode.")
                state = .awaitingAction(cardId: cid, front: front, back: back)
                try? await Task.sleep(nanoseconds: 150_000_000)
                await listenForAction()
            }
            
        case .confirmingDelete(let cid, let front, let back):
            // Cancel deletion confirmation; return to answer phase
            stopForTransition(true)
            state = .awaitingAnswer(cardId: cid, front: front, back: back)
            await tts.speakAndWait("Cancelled.")
            try? await Task.sleep(nanoseconds: 200_000_000)
            await listenForAnswerContinuous()
        }
    }
    
    @MainActor
    func handleReadAnswer() async {
        // Helper to keep session active if we're about to listen again
        func stopForTransition(_ willListen: Bool = true) {
            stopAllIO(deactivateSession: !willListen)
            currentNetworkTask?.cancel()
            currentNetworkTask = nil
            showBackDuringProcessing = false
        }

        switch state {
        case .idle:
            return

        case .readingFront(let cid, let front, let back):
            stopForTransition(true)
            showBackNowAndPrepareToListen(cid, front, back)
            let backTTS = current?.back_text_tts ?? back
            let backLang = current?.back_language
            await safeSpeakAndWait(backTTS, language: backLang)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await listenForAction()

        case .awaitingAnswer(let cid, let front, let back):
            stopForTransition(true)
            showBackNowAndPrepareToListen(cid, front, back)
            let backTTS = current?.back_text_tts ?? back
            let backLang = current?.back_language
            await safeSpeakAndWait(backTTS, language: backLang)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await listenForAction()

        case .explaining(let cid, let front, let back, _):
            tts.stopSpeaking() // cancel current explanation
            stopForTransition(true)
            showBackNowAndPrepareToListen(cid, front, back)
            let backTTS = current?.back_text_tts ?? back
            let backLang = current?.back_language
            await safeSpeakAndWait(backTTS, language: backLang) // re-read the official answer
            try? await Task.sleep(nanoseconds: 50_000_000)
            await listenForAction()

        case .awaitingAction(_, _, let back):
            // Already showing the back in this state; just speak it again.
            stopForTransition(true)
            let backTTS = current?.back_text_tts ?? back
            let backLang = current?.back_language
            await safeSpeakAndWait(backTTS, language: backLang)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await listenForAction()

        case .confirmingGrade(let cid, _, let front, let back):
            // Cancel confirmation; user wants the answer
            stopForTransition(true)
            showBackNowAndPrepareToListen(cid, front, back)
            let backTTS = current?.back_text_tts ?? back
            let backLang = current?.back_language
            await safeSpeakAndWait(backTTS, language: backLang)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await listenForAction()
            
        case .confirmingDelete(let cid, let front, let back):
            // Cancel deletion confirmation; return to answer phase
            stopForTransition(true)
            state = .awaitingAnswer(cardId: cid, front: front, back: back)
            await safeSpeakAndWait("Cancelled.")
            try? await Task.sleep(nanoseconds: 200_000_000)
            await listenForAnswerContinuous()
        }
    }
    
    @MainActor
    func handleRereadQuestion() async {
        // Reread the question but stay in answer phase (don't transition to action phase)
        guard case .awaitingAnswer(_, let front, _) = state else {
            return
        }
        
        // Stop STT temporarily while speaking
        stt.stop()
        
        // Keep showing the question in UI (don't show back during processing)
        showBackDuringProcessing = false
        
        // Read the question using TTS
        #if os(iOS)
        await director.handle(.toTTS(stt))
        #endif
        let frontTTS = current?.front_text_tts ?? front
        let frontLang = current?.front_language
        await tts.speakAndWait(frontTTS, language: frontLang)
        
        // Wait a bit for TTS to settle
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms settle after TTS
        
        // Clear transcript before resuming listening
        stt.transcript = ""
        stt.isFinal = false
        
        // Resume listening for answer (stay in awaitingAnswer state)
        await listenForAnswerContinuous()
    }
    
    @MainActor
    func handleRereadAnswer() async {
        // Reread the answer but stay in answer phase (don't transition to action phase)
        guard case .awaitingAnswer(_, _, let back) = state else {
            return
        }
        
        // Stop STT temporarily while speaking
        stt.stop()
        
        // Show the back in UI (so user can see it while it's being read)
        showBackDuringProcessing = true
        
        // Read the answer using TTS
        #if os(iOS)
        await director.handle(.toTTS(stt))
        #endif
        let backTTS = current?.back_text_tts ?? back
        let backLang = current?.back_language
        await tts.speakAndWait(backTTS, language: backLang)
        
        // Wait a bit for TTS to settle
        try? await Task.sleep(nanoseconds: 200_000_000) // 200ms settle after TTS
        
        // Clear transcript before resuming listening
        stt.transcript = ""
        stt.isFinal = false
        
        // Resume listening for answer (stay in awaitingAnswer state)
        await listenForAnswerContinuous()
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
        authService.addAuthHeader(to: &req)
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
                        // Orchestrator handles STT→TTS transition (closes mic gate, enters TTS phase)
                        await safeSpeakAndWait(result.explanation)
                        if Task.isCancelled { return }
                        
                        // Small settle to let the route flip from speaker to built-in mic
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        showBackDuringProcessing = false
                        currentNetworkTask = nil  // Clear task reference after completion
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
                        showBackDuringProcessing = false
                        // Small settle after TTS
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        await listenForAction()
                        return
                    } else if httpResponse.statusCode == 502 || httpResponse.statusCode == 503 {
                        tts.speak("The grader backend failed. Check the OpenAI key or network on the server.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        showBackDuringProcessing = false
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
                        currentNetworkTask = nil  // Clear task reference after completion
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        showBackDuringProcessing = false
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
        if authService.isAuthenticated {
            print("Using production API: \(productionAPIURL)")
        } else {
            print("For local dev:")
            print("1. Run: kubectl port-forward -n gateway --address 0.0.0.0 svc/api-gateway 8000:80")
        print("2. Server URL uses Tailscale MagicDNS (e.g., http://<device>.\(tailnetSuffix):8000)")
        }
        #endif
        
        #if DEBUG
        let errorMsg = baseURL.contains("127.0.0.1") || baseURL.contains("localhost") ?
            "Server URL is localhost. For local dev, run: kubectl port-forward -n gateway --address 0.0.0.0 svc/api-gateway 8000:80" :
            "I couldn't reach the grader. For local dev, ensure port forwarding is active. You can say a grade directly instead."
        #else
        let errorMsg = "I couldn't reach the grader. Please check your network connection. You can say a grade directly instead."
        #endif
        speakErrorIfAllowed(errorMsg)
        
        // Always transition to a valid state - never leave stuck in awaitingAnswer
        state = .awaitingAction(cardId: cid, front: front, back: back)
        showBackDuringProcessing = false
        currentNetworkTask = nil  // Clear task reference after completion
        await listenForAction()
    }

    func listenForAction() async {
        // Cancel any previous listening task
        listeningTask?.cancel()
        
        // Must be in awaitingAction
        guard case .awaitingAction = state else {
            #if DEBUG
            print("listenForAction called but not in awaitingAction state: \(state)")
            #endif
            return
        }
        
        // Store this task so it can be cancelled if needed
        listeningTask = Task {
            await listenForActionImpl()
        }
        await listeningTask?.value
    }
    
    private func listenForActionImpl() async {

        // Orchestrator manages STT phase transitions
        if !stt.isRunning {
            do {
                isListening = true
                #if os(iOS)
                // Enter STT phase (director handles quiet fence and mic gate)
                await director.handle(.toSTT(stt))
                #else
                try await stt.startRecognitionIfNeeded()
                #endif
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
            // Exit if listening was stopped (e.g., by button click)
            if !isListening {
                return
            }
            
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
                // Check for cancellation
                if Task.isCancelled {
                    stt.stop()
                    isListening = false
                    return
                }
                
                // Exit if listening was stopped (e.g., by button click)
                if !isListening {
                    return
                }
                
                // Resilience check: if recognizer silently died, restart it
                if !stt.isRunning {
                    #if os(iOS)
                    // Assert liveness without re-entering STT
                    await director.handle(.assertSTTRunning(stt))
                    #else
                    try? await stt.startRecognitionIfNeeded()
                    #endif
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
                    let success = await submitGrade(cardId: cid, ease: ease)
                    if success {
                        stt.stop()
                        isListening = false
                        #if os(iOS)
                        await director.handle(.toTTS(stt))
                        #endif
                        await tts.speakAndWait("Marked \(canonical). \(undoPrompt())")
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        await advanceToNextCard(previousCardId: cid)
                        return
                    } else {
                        stt.stop()
                        isListening = false
                        tts.speak("Failed to submit grade. Make sure Anki Desktop is in review mode with a card showing.")
                        state = .awaitingAction(cardId: cid, front: front, back: back)
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        // Restart listening after error message
                        isListening = true
                        #if os(iOS)
                        await director.handle(.assertSTTRunning(stt))
                        #endif
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

            case .question(text: let q):
                stt.stop()
                isListening = false
                currentNetworkTask?.cancel()
                currentNetworkTask = Task { await askFollowUp(question: q) }
                // askFollowUp will speak and then return to awaitingAction→listenForAction
                return

            case .ambiguous:
                let lower = utterance.lowercased()
                // Check for "read answer" phrases
                if ["read answer","read the answer","show answer","tell me the answer"].contains(where: { lower.contains($0) }) {
                    stt.stop()
                    isListening = false
                    await handleReadAnswer()
                    return
                } else if lower.contains("undo") || lower.contains("change") || lower.contains("take back") {
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
                     isListening = true
                     #if os(iOS)
                     // Director handles STT configuration - just restart recognition
                     await director.handle(.assertSTTRunning(stt))
                     #endif
                    continue
                }
            }
        }
    }

    func listenForConfirmation() async {
        stt.stopRecognitionIfRunning()
        // Don't deactivate session - keep it active for smooth transition
        try? await Task.sleep(nanoseconds: 100_000_000)

        isListening = true
        #if os(iOS)
        // Enter STT phase
        await director.handle(.toSTT(stt))
        #else
        try? await stt.startRecognitionIfNeeded()
        #endif

        let started = DispatchTime.now()
        var last = ""
        var unchangedCount = 0
        let unchangedThreshold = 2
        let hardTimeout: UInt64 = 3_000_000_000

        while true {
            // Check for cancellation
            if Task.isCancelled {
                stt.stopRecognitionIfRunning()
                isListening = false
                return
            }
            
            // Resilience check: if recognizer silently died, restart it
            if !stt.isRunning {
                #if os(iOS)
                // Assert liveness without re-entering STT
                await director.handle(.assertSTTRunning(stt))
                #else
                try? await stt.startRecognitionIfNeeded()
                #endif
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
            let success = await submitGrade(cardId: cid, ease: ease)
            if success {
                #if os(iOS)
                await director.handle(.toTTS(stt))
                #endif
                await tts.speakAndWait("Marked \(canonicalName(ease)). \(undoPrompt())")
                try? await Task.sleep(nanoseconds: 80_000_000)
                await advanceToNextCard(previousCardId: cid)
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
    
    func listenForDeleteConfirmation() async {
        stt.stopRecognitionIfRunning()
        // Don't deactivate session - keep it active for smooth transition
        try? await Task.sleep(nanoseconds: 100_000_000)

        isListening = true
        #if os(iOS)
        // Enter STT phase
        await director.handle(.toSTT(stt))
        #else
        try? await stt.startRecognitionIfNeeded()
        #endif

        let started = DispatchTime.now()
        var last = ""
        var unchangedCount = 0
        let unchangedThreshold = 2
        let hardTimeout: UInt64 = 3_000_000_000

        while true {
            // Check for cancellation
            if Task.isCancelled {
                stt.stopRecognitionIfRunning()
                isListening = false
                return
            }
            
            // Resilience check: if recognizer silently died, restart it
            if !stt.isRunning {
                #if os(iOS)
                // Assert liveness without re-entering STT
                await director.handle(.assertSTTRunning(stt))
                #else
                try? await stt.startRecognitionIfNeeded()
                #endif
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
            guard case .confirmingDelete(let cid, let front, let back) = state else { return }
            state = .awaitingAnswer(cardId: cid, front: front, back: back)
            await tts.speakAndWait("Okay. Cancelled.")
            try? await Task.sleep(nanoseconds: 200_000_000)
            await listenForAnswerContinuous()
            return
        }

        await handleDeleteConfirmation(confirmed: confirmed) // safer: don't auto-confirm on timeout
    }
    
    func handleDeleteConfirmation(confirmed: Bool) async {
        guard case .confirmingDelete(let cid, let front, let back) = state else { return }
        
        // STT is already stopped by listenForDeleteConfirmation()
        
        if confirmed {
            let success = await deleteNote(cardId: cid)
            if success {
                #if os(iOS)
                await director.handle(.toTTS(stt))
                #endif
                await tts.speakAndWait("Note deleted.")
                try? await Task.sleep(nanoseconds: 80_000_000)
                await startReview() // Fetch next card
            } else {
                tts.speak("Failed to delete note. Make sure Anki Desktop is running.")
                state = .awaitingAnswer(cardId: cid, front: front, back: back)
                try? await Task.sleep(nanoseconds: 200_000_000)
                await listenForAnswerContinuous()
            }
        } else {
            state = .awaitingAnswer(cardId: cid, front: front, back: back)
            await tts.speakAndWait("Okay. Cancelled.")
            try? await Task.sleep(nanoseconds: 200_000_000)
            await listenForAnswerContinuous()
        }
    }
    
    func deleteNote(cardId: Int) async -> Bool {
        guard let base = validatedBaseURL(),
              let url = URL(string: "\(base)/delete-note") else {
            return false
        }
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        authService.addAuthHeader(to: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["cardId": cardId]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10.0
        cfg.timeoutIntervalForResource = 12.0
        let session = URLSession(configuration: cfg)
        
        do {
            let (data, response) = try await session.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            
            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["error"] == nil || (json["error"] as? NSNull) != nil {
                    return true
                }
            }
            return false
        } catch {
            #if DEBUG
            print("[DeleteNote] Error: \(error)")
            #endif
            return false
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
            currentNetworkTask = nil  // Clear task reference after completion
            try? await Task.sleep(nanoseconds: 150_000_000)
            await listenForAction()
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        authService.addAuthHeader(to: &req)
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
                    
                    // ✅ Re-assert TTS route right before speaking (critical STT→TTS transition)
                    #if os(iOS)
                    await director.handle(.toTTS(stt))
                    #endif
                    
                    await safeSpeakAndWait(result.answer)
                    if Task.isCancelled { return }
                    
                    // Small settle delay after TTS
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    currentNetworkTask = nil  // Clear task reference after completion
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
            
            // ✅ Re-assert TTS route right before speaking (critical STT→TTS transition)
            #if os(iOS)
            await director.handle(.toTTS(stt))
            #endif
            
            await safeSpeakAndWait("Sorry, I couldn't answer that. Ask again or grade.")
            
            // Small settle delay after TTS
            try? await Task.sleep(nanoseconds: 150_000_000)
            currentNetworkTask = nil  // Clear task reference after completion
            state = .awaitingAction(cardId: cid, front: front, back: back)
            await listenForAction()
    }

    func submitGrade(cardId: Int, ease: Int) async -> Bool {
        guard let base = validatedBaseURL(),
              let url = URL(string: "\(base)/submit-grade") else {
            appLog("Invalid submit-grade URL", category: "network")
            return false
        }
        
        // Short timeout for commands; a little headroom helps avoid false "fail"
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3.5
        config.timeoutIntervalForResource = 4.5
        let session = URLSession(configuration: config)
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        authService.addAuthHeader(to: &req)
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        struct Payload: Encodable {
            let cardId: Int
            let ease: Int
        }
        
        struct SubmitResponse: Decodable {
            let result: Bool?
            let error: String?
        }
        
        let p = Payload(cardId: cardId, ease: ease)
        req.httpBody = try? JSONEncoder().encode(p)
        
        do {
            let (data, response) = try await session.data(for: req)
            
            if let httpResponse = response as? HTTPURLResponse {
                #if DEBUG
                print("POST /submit-grade: HTTP \(httpResponse.statusCode)")
                #endif
                
                if httpResponse.statusCode == 200 {
                    // Check the response body - AnkiConnect returns {"result": true/false}
                    let decoder = JSONDecoder()
                    if let submitResponse = decoder.decodeIfPresent(SubmitResponse.self, from: data) {
                        if let result = submitResponse.result {
                            if result {
                                appLog("Grade submitted successfully", category: "network")
                                // Track this card as the last graded card for undo
                                lastGradedCardId = cardId
                                return true
                            } else {
                                let errorMsg = submitResponse.error ?? "unknown"
                                appLog("AnkiConnect returned result: false. Error: \(errorMsg)", category: "network")
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
        
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 3.0
        let session = URLSession(configuration: config)
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        authService.addAuthHeader(to: &req)
        
        do {
            let (data, response) = try await session.data(for: req)
            
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode == 200 {
                // Check if AnkiConnect returned an error
                struct UndoResponse: Decodable {
                    let result: Bool?
                    let error: String?
                }
                let decoder = JSONDecoder()
                if let undoResponse = decoder.decodeIfPresent(UndoResponse.self, from: data) {
                    if let error = undoResponse.error {
                        #if DEBUG
                        print("[UNDO] AnkiConnect error: \(error)")
                        #endif
                        tts.speak("Could not undo. \(error)")
                        return
                    }
                }
                
                // Undo succeeded - just fetch the current card and continue
                #if os(iOS)
                await director.handle(.toTTS(stt))
                #endif
                await tts.speakAndWait("Undid that.", stt: stt)
                
                // Fetch whatever card Anki is showing now and start review
                await startReview()
                // Clear the last graded card ID since we've undone it
                lastGradedCardId = nil
            } else {
                #if DEBUG
                print("[UNDO] HTTP error: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                #endif
                tts.speak("Could not undo.")
            }
        } catch {
            #if DEBUG
            print("[UNDO] Network error: \(error)")
            #endif
            tts.speak("Could not undo.")
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
    
    // Ensure Anki reviewer is showing the answer before we send a grade.
    // If /show-answer exists on your FastAPI server, we call it; otherwise we
    // fall back to a short settle delay after revealing the back in the UI.
    private func ensureAnswerShownIfNeeded(previousState: ReviewState) async {
        guard case .awaitingAnswer = previousState else { return }
        // Best-effort server nudge (optional endpoint)
        if let base = validatedBaseURL(),
           let url = URL(string: "\(base)/show-answer") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 1.0
            cfg.timeoutIntervalForResource = 1.5
            let session = URLSession(configuration: cfg)
            _ = try? await session.data(for: req)
        }
        // Give Anki a moment to flip; also avoids racing STT/TTS routing.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
}
