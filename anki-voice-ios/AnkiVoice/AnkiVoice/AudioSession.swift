import AVFoundation

#if os(iOS)
enum AudioPhase { case tts, stt }

final class AudioSession {
    static let shared = AudioSession()
    private init() {}

    private let session = AVAudioSession.sharedInstance()
    private(set) var phase: AudioPhase?

    func configureForTTS() {
        // No phase guard: we may need to re-assert routing each time
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            // Prefer Bluetooth if present
            let outs = session.currentRoute.outputs
            let hasBT = outs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP }

            if hasBT {
                // Let iOS keep BT; do not override to speaker
                try? session.overrideOutputAudioPort(.none)
            } else {
                // Force built-in speaker, never receiver
                try? session.overrideOutputAudioPort(.speaker)
            }

            phase = .tts
            #if DEBUG
            logRoute(prefix: "TTS")
            #endif
        } catch {
            #if DEBUG
            print("AudioSession TTS config failed:", error)
            #endif
        }
    }

    func configureForSTT() {
        do {
            try session.setCategory(.playAndRecord,
                                    mode: .voiceChat,
                                    options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            // Prefer built-in mic when using speaker:
            if session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
                try? session.setPreferredInput(nil)
            }
            // Optional but stabilizes input format on some devices
            try? session.setPreferredSampleRate(48_000)
            try? session.setPreferredIOBufferDuration(0.005)
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

    #if DEBUG
    private func logRoute(prefix: String) {
        let r = session.currentRoute
        let ins  = r.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outs = r.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("[AudioRoute] \(prefix) inputs=\(ins) outputs=\(outs)")
    }
    #endif
}
#endif

