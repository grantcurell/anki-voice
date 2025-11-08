import AVFoundation

#if os(iOS)
extension AVAudioSession {
    func preferBluetoothHFPInputIfAvailable() {
        // Prefer HFP (hands-free profile) for BT headsets - has working mic
        if let bt = availableInputs?.first(where: { $0.portType == .bluetoothHFP }) {
            try? setPreferredInput(bt)
            #if DEBUG
            print("[AudioSession] Selected HFP input: \(bt.portName)")
            #endif
            return
        }
        
        // Fallback: explicitly select built-in mic if no HFP (e.g., LE-only devices or no BT)
        // This ensures we have a working mic input before recognition starts
        if let builtIn = availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try? setPreferredInput(builtIn)
            #if DEBUG
            print("[AudioSession] Selected built-in mic (no HFP available)")
            #endif
        } else {
            // Last resort: let iOS choose
            try? setPreferredInput(nil)
            #if DEBUG
            print("[AudioSession] Cleared preferred input (no HFP or built-in mic found)")
            #endif
        }
    }
}

actor AudioDirector {
    enum Phase { case idle, tts, stt }
    enum Event {
        case toTTS(SpeechSTT)
        case toTTSWithoutSTT  // For TTS when no STT instance available
        case toSTT(SpeechSTT)
        case assertSTTRunning(SpeechSTT)
        case interruptionBegan
        case routeChanged
        case forceSpeakerIfEarpiece  // Emergency route fix when earpiece detected
        case toIdle
    }

    private var phase: Phase = .idle
    private var configured = false

    func configureOnce() async throws {
        guard !configured else { return }
        try await MainActor.run {
            let s = AVAudioSession.sharedInstance()
            // Duplex audio with AEC, supports BT and speaker
            try s.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
            )
            if #available(iOS 17.0, *) { try? s.setPrefersEchoCancelledInput(true) }
            
            // Speech engines are happy at 16 kHz; feel free to use 44.1kHz if your TTS prefers it
            try s.setPreferredSampleRate(16_000)
            
            // 20 ms buffers are a good tradeoff for STT latency vs. power
            try s.setPreferredIOBufferDuration(0.02)
            
            // Remain active across backgrounding
            try s.setActive(true)
            
            // Force speaker unless on BT
            let outs = s.currentRoute.outputs
            let isBT = outs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP }
            if !isBT { try? s.overrideOutputAudioPort(.speaker) }
            try? s.setPreferredInput(nil)
        }
        configured = true
    }
    
    func ensureActive() async {
        await MainActor.run {
            try? AVAudioSession.sharedInstance().setActive(true, options: [])
        }
    }
    
    func deactivateIfReallyQuitting() async {
        await MainActor.run {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    func handle(_ e: Event) async {
        switch e {
        case .toTTS(let stt):
            await toTTS(stt)
        case .toTTSWithoutSTT:
            await toTTSWithoutSTT()
        case .toSTT(let stt):
            await toSTT(stt)
        case .assertSTTRunning(let stt):
            await assertSTTRunning(stt)
        case .interruptionBegan:
            phase = .idle
        case .routeChanged:
            // No phase flip; the loops should call assertSTTRunning as needed
            break
        case .forceSpeakerIfEarpiece:
            await forceSpeakerIfEarpiece()
        case .toIdle:
            phase = .idle
        }
    }

    private func toTTS(_ stt: SpeechSTT) async {
        await MainActor.run {
            stt.micGate = .closed
            stt.stopRecognitionIfRunning()
            // Leave stt.setMuted(_:) alone here — user control overrides phase
            let s = AVAudioSession.sharedInstance()
            let outs = s.currentRoute.outputs
            let isBT = outs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP }
            if !isBT { try? s.overrideOutputAudioPort(.speaker) }
            try? s.setPreferredInput(nil)
        }
        phase = .tts
        #if DEBUG
        print("[AudioDirector] toTTS: gate closed, speaker forced")
        #endif
    }

    private func toSTT(_ stt: SpeechSTT) async {
        await MainActor.run {
            let s = AVAudioSession.sharedInstance()
            s.preferBluetoothHFPInputIfAvailable()
        }

        // SpeechSTT is @MainActor; snapshot gate on the main actor
        let gateIsOpen = await MainActor.run { stt.micGate == .open }
        if phase == .stt && gateIsOpen {
            await assertSTTRunning(stt)
            return
        }
        phase = .stt
        
        // Extended quiet fence to prevent TTS echo from being recorded
        // Wait longer after TTS finishes to ensure audio has fully stopped and echo/reverb has died down
        try? await Task.sleep(nanoseconds: 400_000_000) // 400ms quiet fence (increased from 120ms)
        
        await MainActor.run {
            stt.micGate = .open
            // Clear transcript before starting to avoid any stale text
            stt.transcript = ""
            stt.isFinal = false
        }
        // If user muted, startRecognitionIfNeeded() will no-op; otherwise it starts
        do { try await stt.startRecognitionIfNeeded() } catch {
            #if DEBUG
            print("[AudioDirector] toSTT: failed to start recognition: \(error)")
            #endif
        }
        #if DEBUG
        print("[AudioDirector] toSTT: gate open, recognition ensured (after 400ms quiet fence)")
        #endif
    }

    private func assertSTTRunning(_ stt: SpeechSTT) async {
        await MainActor.run {
            AVAudioSession.sharedInstance().preferBluetoothHFPInputIfAvailable()
        }
        let isRunning = await MainActor.run { stt.isRunning }
        if !isRunning {
            await MainActor.run {
                stt.stopRecognitionIfRunning()
            }
            do { try await stt.startRecognitionIfNeeded() } catch {
                #if DEBUG
                print("[AudioDirector] assertSTTRunning failed: \(error)")
                #endif
            }
        }
    }
    
    private func toTTSWithoutSTT() async {
        // For TTS when no STT instance - just force speaker and clear preferred input
        await MainActor.run {
            let s = AVAudioSession.sharedInstance()
            let outs = s.currentRoute.outputs
            let isBT = outs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP }
            if !isBT {
                try? s.overrideOutputAudioPort(.speaker)
            }
            try? s.setPreferredInput(nil)
        }
        phase = .tts
        #if DEBUG
        print("[AudioDirector] toTTSWithoutSTT: speaker forced")
        #endif
    }
    
    private func forceSpeakerIfEarpiece() async {
        // Emergency route fix: if earpiece detected, force speaker (safety net for watchdog)
        await MainActor.run {
            let s = AVAudioSession.sharedInstance()
            let outs = s.currentRoute.outputs
            let wentReceiver = outs.contains { $0.portType == .builtInReceiver }
            if wentReceiver {
                let isBT = outs.contains { $0.portType == .bluetoothA2DP || $0.portType == .bluetoothLE || $0.portType == .bluetoothHFP }
                if !isBT {
                    try? s.overrideOutputAudioPort(.speaker)
                    #if DEBUG
                    print("[AudioDirector] forceSpeakerIfEarpiece: forced speaker (earpiece detected)")
                    #endif
                }
            }
        }
    }
}
#endif

