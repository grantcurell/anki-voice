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

    // BLOCKING, verified config for TTS. More stubborn to survive STT→TTS handoff race.
    func configureForTTSVerified(maxAttempts: Int = 3, settleMs: UInt64 = 80) async -> Bool {
        for _ in 0..<maxAttempts {
            do {
                try s.setCategory(.playAndRecord,
                                  mode: .spokenAudio,
                                  options: [.duckOthers, .allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
                try s.setActive(true, options: [])
            } catch {
                // continue
            }
            // Clear preferred input to avoid receiver heuristics
            try? s.setPreferredInput(nil)
            // Force speaker only if not on Bluetooth
            if !isBTOutput(s.currentRoute.outputs) {
                _ = try? s.overrideOutputAudioPort(.speaker)
            }
            try? await Task.sleep(nanoseconds: settleMs * 1_000_000)

            let outs = s.currentRoute.outputs
            let ok = outs.contains { port in
                let pt = port.portType
                return pt == .builtInSpeaker || pt == .bluetoothA2DP || pt == .bluetoothLE || pt == .bluetoothHFP
            }
            if ok {
                phase = .tts
                return true
            }
        }
        phase = .tts
        return false
    }
    
    func cancelKeepAliveIfAny() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
    }

    // Light wrapper for STT (unchanged from your logic)
    func configureForSTT() {
        do {
            try s.setCategory(.playAndRecord,
                              mode: .voiceChat,
                              options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
            try s.setActive(true, options: [])
            // Force built-in speaker only when not on BT
            let outs = s.currentRoute.outputs
            if !isBTOutput(outs) {
                _ = try? s.overrideOutputAudioPort(.speaker)
            }
            // Prefer built-in mic when using speaker:
            if outs.contains(where: { $0.portType == .builtInSpeaker }) {
                try? s.setPreferredInput(nil)
            }
            // Optional but stabilizes input format on some devices
            try? s.setPreferredSampleRate(48_000)
            try? s.setPreferredIOBufferDuration(0.005)
            phase = .stt
            #if DEBUG
            logRoute(prefix: "STT")
            #endif
        } catch {
            #if DEBUG
            print("AudioSession STT config failed:", error)
            #endif
        }
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
