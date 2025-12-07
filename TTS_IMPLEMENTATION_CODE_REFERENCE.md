# TTS Implementation Code Reference

Quick reference to current TTS implementation code for the GB10 migration.

## Core TTS Class

**File:** `anki-voice-ios/AnkiVoice/AnkiVoice/ContentView.swift`

### SpeechTTS Class (lines 395-540)

```swift
final class SpeechTTS: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    nonisolated(unsafe) let synth = AVSpeechSynthesizer()
    @Published private(set) var isSpeaking: Bool = false
    private var voice: AVSpeechSynthesisVoice? = normalUSVoice()
    private var lastUtteranceText: String?
    var onFinishedSpeaking: (() -> Void)?
    private var waitCont: CheckedContinuation<Void, Never>?
    
    #if os(iOS)
    weak var director: AudioDirector?
    #endif
    
    func speak(_ text: String, stt: SpeechSTT? = nil, route: Bool = true, language: String? = nil) {
        Task { @MainActor in
            #if os(iOS)
            if route {
                if let stt = stt, let director = director {
                    await director.handle(.toTTS(stt))
                } else if director != nil {
                    await director?.handle(.toTTSWithoutSTT)
                }
            }
            #endif

            if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
            lastUtteranceText = text
            let u = AVSpeechUtterance(string: text)
            // Use language-specific voice if provided
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
    
    func speakAndWait(_ text: String, stt: SpeechSTT? = nil, language: String? = nil) async {
        #if os(iOS)
        if let stt = stt, let director = director {
            await director.handle(.toTTS(stt))
        } else if director != nil {
            await director?.handle(.toTTSWithoutSTT)
        }
        #endif
        
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waitCont?.resume()
            waitCont = cont
            onFinishedSpeaking = { [weak self] in
                guard let self = self else { return }
                self.onFinishedSpeaking = nil
                self.waitCont?.resume()
                self.waitCont = nil
            }
            speak(text, stt: stt, route: false, language: language)
        }
    }
    
    func stopSpeaking() {
        let cont = waitCont
        waitCont = nil
        onFinishedSpeaking = nil
        synth.stopSpeaking(at: .immediate)
        cont?.resume()
        DispatchQueue.main.async { self.isSpeaking = false }
    }
    
    // AVSpeechSynthesizerDelegate methods
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.isSpeaking = true }
    }
    
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
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
    
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isSpeaking = false
            if let cb = self.onFinishedSpeaking {
                self.onFinishedSpeaking = nil
                cb()
            }
            self.waitCont?.resume()
            self.waitCont = nil
        }
    }
}
```

### Voice Selection Helper (line 320)

```swift
func normalUSVoice() -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices()
    // Fast "any" fallback bundle
    let any = voices.first
    // ... (additional logic)
    return any
}
```

## Audio Routing Integration

**File:** `anki-voice-ios/AnkiVoice/AnkiVoice/AudioDirector.swift`

### AudioDirector Class (lines 32-216)

```swift
actor AudioDirector {
    enum Phase { case idle, tts, stt }
    enum Event {
        case toTTS(SpeechSTT)
        case toTTSWithoutSTT
        case toSTT(SpeechSTT)
        // ...
    }
    
    private func toTTS(_ stt: SpeechSTT) async {
        await MainActor.run {
            stt.micGate = .closed
            stt.stopRecognitionIfRunning()
            let s = AVAudioSession.sharedInstance()
            let outs = s.currentRoute.outputs
            let isBT = outs.contains { $0.portType == .bluetoothA2DP || ... }
            if !isBT { try? s.overrideOutputAudioPort(.speaker) }
            try? s.setPreferredInput(nil)
        }
        phase = .tts
    }
    
    private func toTTSWithoutSTT() async {
        await MainActor.run {
            let s = AVAudioSession.sharedInstance()
            let outs = s.currentRoute.outputs
            let isBT = outs.contains { $0.portType == .bluetoothA2DP || ... }
            if !isBT {
                try? s.overrideOutputAudioPort(.speaker)
            }
            try? s.setPreferredInput(nil)
        }
        phase = .tts
    }
}
```

## Usage Examples Throughout App

### Card Reading (line 1621)
```swift
await tts.speakAndWait(text, stt: stt, language: language)
```

### Error Messages (line 2362)
```swift
tts.speak("Open Anki on your Mac and start a review.")
```

### User Prompts (line 2451)
```swift
await tts.speakAndWait("What's your answer?", stt: stt)
```

### Status Updates (line 2100)
```swift
await tts.speakAndWait("Sync complete.")
```

## Language Detection

**File:** `anki-voice-server/app/main.py`

### Language Hints API (lines 70-108)

```python
async def get_language_hints(card_id: int) -> Dict[str, Optional[str]]:
    """Get language hints for front and back of a card"""
    front_lang = None
    back_lang = None
    
    # Get card info to find deck name
    card_info = await get_card_info(card_id)
    deck_name = card_info.get("deckName")
    
    # Get note info to check for per-note tags
    note_id = card_info.get("note")
    note_tags = []
    if note_id:
        note_info = await get_note_info(note_id)
        if note_info:
            note_tags = note_info.get("tags", [])
    
    # Check for per-note tag overrides first
    front_lang = extract_lang_from_tags(note_tags, "av:front")
    back_lang = extract_lang_from_tags(note_tags, "av:back")
    
    # If no per-note tags, check deck-level config
    if not front_lang or not back_lang:
        deck_config = await get_deck_language_config(deck_name)
        if deck_config:
            if not front_lang:
                front_lang = deck_config.get("front_language")
            if not back_lang:
                back_lang = deck_config.get("back_language")
    
    return {"front_language": front_lang, "back_language": back_lang}
```

### Current Card Response (lines 174-214)

```python
@app.get("/current")
async def get_current():
    # ... fetch card data ...
    
    # Get language hints for TTS
    lang_hints = await get_language_hints(card_id)
    
    data = {
        "status": "reviewing",
        "cardId": card_id,
        "front_text": front_text_full,
        "back_text": back_text_full,
        "front_text_tts": front_text_readme,  # README div only
        "back_text_tts": back_text_readme,    # README div only
        "front_language": lang_hints.get("front_language"),
        "back_language": lang_hints.get("back_language"),
        # ...
    }
    return data
```

## Audio Session Configuration

**File:** `anki-voice-ios/AnkiVoice/AnkiVoice/AudioSession.swift`

```swift
func forceSpeakerNow() {
    try? s.setCategory(.playAndRecord,
                       mode: .spokenAudio,
                       options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers, .defaultToSpeaker])
    try? s.setActive(true, options: [])
    try? s.setPreferredInput(nil)
    if !isBTOutput(s.currentRoute.outputs) {
        try? s.overrideOutputAudioPort(.speaker)
    }
    phase = .tts
}
```

## Key Integration Points

1. **TTS Initialization:** ContentView creates `SpeechTTS` instance and sets `director`
2. **Audio Routing:** `speak()` and `speakAndWait()` call `AudioDirector.handle(.toTTS())` before speaking
3. **Language Support:** Language codes passed from API (`front_language`, `back_language`) to `speak()` methods
4. **Async Coordination:** `speakAndWait()` uses continuations to wait for completion
5. **State Management:** `@Published var isSpeaking` tracks playback state

## Migration Checklist

- [ ] Replace `AVSpeechSynthesizer` with GB10 client
- [ ] Replace `AVSpeechUtterance` with GB10 API request
- [ ] Replace delegate callbacks with `AVAudioPlayerDelegate` or completion handlers
- [ ] Maintain `AudioDirector` integration (same routing calls)
- [ ] Maintain language parameter support
- [ ] Maintain `speak()` and `speakAndWait()` signatures
- [ ] Maintain `isSpeaking` published property
- [ ] Add error handling for network failures
- [ ] Add caching for generated audio
- [ ] Test all usage sites (card reading, errors, prompts, status)

