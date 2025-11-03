import AVFoundation

#if os(iOS)
enum AudioPhase { case idle, tts, stt }

@MainActor
final class AudioSession {
    static let shared = AudioSession()
    private init() {}

    private let s = AVAudioSession.sharedInstance()
    private(set) var phase: AudioPhase = .idle
    var keepAliveTask: Task<Void, Never>?

    // Helper: current route classification
    private func isBTOutput(_ outs: [AVAudioSessionPortDescription]) -> Bool {
        outs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP }
    }
    private func isSpeaker(_ outs: [AVAudioSessionPortDescription]) -> Bool {
        outs.contains { $0.portType == .builtInSpeaker }
    }
    private func isReceiver(_ outs: [AVAudioSessionPortDescription]) -> Bool {
        outs.contains { $0.portType == .builtInReceiver }
    }

    // Core speaker forcing with correct order: Category → setActive → clearPreferredInput → override
    // This is the canonical recipe from Stack Overflow: order matters!
    func forceSpeakerNow() {
        // 1) Category first
        try? s.setCategory(.playAndRecord,
                           mode: .spokenAudio,
                           options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers, .defaultToSpeaker])

        // 2) Activate second
        try? s.setActive(true, options: [])

        // 3) Prefer built-in mic if we're on speaker (avoids proximity/receiver heuristics)
        try? s.setPreferredInput(nil)

        // 4) Finally override to speaker (must happen AFTER category+active)
        if !isBTOutput(s.currentRoute.outputs) {
            try? s.overrideOutputAudioPort(.speaker)
        }

        phase = .tts
        #if DEBUG
        logRoute(prefix: "FORCE")
        #endif
    }

    // Deprecated: Use await configureForTTSVerified() everywhere.
    // This shim hard-forces speaker so any accidental uses won't silently fail.
    @available(*, deprecated, message: "Use await configureForTTSVerified() everywhere.")
    @MainActor
    func configureForTTS() {
        // Zero-wait, hard slam to a safe state if someone forgets to await.
        forceSpeakerNow()
    }

    // Simplified shim: uses voiceChat mode for both TTS and STT (with AEC)
    @discardableResult
    func configureForTTSVerified(maxAttempts: Int = 1, settleMs: UInt64 = 40) async -> Bool {
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        try? s.setActive(true)
        phase = .tts
        return true
    }
    
    func cancelKeepAliveIfAny() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    // Simplified shim: uses voiceChat mode (orchestrator handles session config, this is just for legacy calls)
    func configureForSTT() {
        try? s.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try? s.setActive(true)
        phase = .stt
    }

    // Emergency, used by watchdog. Uses the canonical order for maximum reliability.
    func emergencyForceSpeaker(safeForPlayback: Bool = false) {
        forceSpeakerNow()
    }

    #if DEBUG
    private func logRoute(prefix: String) {
        let r = s.currentRoute
        let ins  = r.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outs = r.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("[AudioRoute] \(prefix) inputs=\(ins) outputs=\(outs)")
    }
    #endif
}
#endif
