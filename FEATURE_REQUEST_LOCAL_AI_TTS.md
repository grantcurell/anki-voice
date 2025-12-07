# Feature Request: Replace Siri TTS with Local AI Voice (GB10)

## Executive Summary

**Request:** Replace the current iOS `AVSpeechSynthesizer` (Siri voices) implementation with a local AI voice synthesis system using GB10. This will provide more natural, customizable voice output for reading Anki flashcard content.

**Priority:** High - Improves user experience with better voice quality and local processing (privacy, offline capability)

**Impact:** Core feature change affecting all TTS functionality in the app

---

## Current Implementation

### Architecture Overview

The app currently uses iOS's native `AVSpeechSynthesizer` for text-to-speech:

**Location:** `anki-voice-ios/AnkiVoice/AnkiVoice/ContentView.swift`

**Key Components:**

1. **`SpeechTTS` class** (lines 395-540):
   - Uses `AVSpeechSynthesizer` and `AVSpeechUtterance`
   - Supports language-specific voices via `AVSpeechSynthesisVoice(language:)`
   - Handles async `speakAndWait()` for blocking until speech completes
   - Integrates with `AudioDirector` for audio routing

2. **Current TTS Flow:**
   ```
   User Action → ContentView → SpeechTTS.speak() or speakAndWait()
   → AVSpeechSynthesizer.speak(utterance)
   → AudioDirector handles routing (speaker/Bluetooth)
   → AVSpeechSynthesizerDelegate callbacks (didStart, didFinish)
   ```

3. **Language Support:**
   - Detects language from `lang` attribute in HTML (via `/current` API endpoint)
   - Falls back to default US English voice
   - Uses `normalUSVoice()` helper function (line 320)

### Current Code Structure

```swift
final class SpeechTTS: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    nonisolated(unsafe) let synth = AVSpeechSynthesizer()
    @Published private(set) var isSpeaking: Bool = false
    private var voice: AVSpeechSynthesisVoice? = normalUSVoice()
    
    func speak(_ text: String, stt: SpeechSTT? = nil, route: Bool = true, language: String? = nil) {
        // Routes audio via AudioDirector
        // Creates AVSpeechUtterance
        // Sets voice based on language parameter
        // Calls synth.speak(u)
    }
    
    func speakAndWait(_ text: String, stt: SpeechSTT? = nil, language: String? = nil) async {
        // Uses continuation to wait for speech completion
        // Calls speak() internally
    }
}
```

### Integration Points

1. **Audio Routing:** `AudioDirector` (lines 32-216 in `AudioDirector.swift`)
   - Manages transitions between TTS and STT phases
   - Handles speaker/Bluetooth routing
   - Current implementation expects `AVSpeechSynthesizer` to handle audio playback

2. **API Integration:** Server provides language hints via `/current` endpoint
   - `front_language` and `back_language` fields
   - Extracted from deck config or note tags
   - Passed to `speak()` and `speakAndWait()` methods

3. **Usage Throughout App:**
   - Card reading: `await tts.speakAndWait(frontText, language: frontLang)`
   - Error messages: `tts.speak("Error message")`
   - User prompts: `await tts.speakAndWait("What's your answer?", stt: stt)`
   - Status updates: `await tts.speakAndWait("Sync complete.")`

---

## Proposed Implementation

### High-Level Architecture

Replace `AVSpeechSynthesizer` with a local TTS service that:
1. Sends text to GB10 device/server
2. Receives audio data (likely WAV/MP3 format)
3. Plays audio using `AVAudioPlayer` or `AVAudioEngine`
4. Maintains same async interface (`speak()`, `speakAndWait()`)

### Design Requirements

#### 1. **GB10 Integration**
   - **Connection:** HTTP/HTTPS API to GB10 device
   - **Endpoint:** TBD (e.g., `http://gb10.local:8080/tts` or similar)
   - **Request Format:** JSON with text and language code
   - **Response Format:** Audio data (WAV/MP3) or streaming audio
   - **Authentication:** If required by GB10

#### 2. **Audio Playback**
   - Use `AVAudioPlayer` or `AVAudioEngine` for playback
   - Maintain compatibility with `AudioDirector` routing
   - Support same audio session configuration (speaker, Bluetooth)
   - Handle interruptions (phone calls, other audio)

#### 3. **Language Support**
   - Map language codes (e.g., `en-US`, `es-ES`, `zh-TW`) to GB10 voice models
   - Fallback mechanism if GB10 doesn't support a language
   - Maintain current language detection from API

#### 4. **Error Handling**
   - Network failures (GB10 unreachable)
   - Audio playback errors
   - Fallback to system TTS if GB10 unavailable (optional)
   - User-friendly error messages

#### 5. **Performance**
   - Caching: Cache generated audio for repeated text
   - Streaming: If GB10 supports streaming, use it for long text
   - Latency: Minimize delay between request and playback start
   - Background: Support background audio playback

### Proposed Code Structure

```swift
final class SpeechTTS: NSObject, ObservableObject {
    // Remove: AVSpeechSynthesizer
    // Add: GB10 client, audio player, cache
    
    private let gb10Client: GB10TTSClient
    private var audioPlayer: AVAudioPlayer?
    private let audioCache: TTSCache
    @Published private(set) var isSpeaking: Bool = false
    
    // Maintain same public interface
    func speak(_ text: String, stt: SpeechSTT? = nil, route: Bool = true, language: String? = nil) async {
        // 1. Route audio via AudioDirector
        // 2. Check cache for audio
        // 3. If not cached, request from GB10
        // 4. Play audio using AVAudioPlayer
        // 5. Update isSpeaking state
    }
    
    func speakAndWait(_ text: String, stt: SpeechSTT? = nil, language: String? = nil) async {
        // Same as speak() but await completion
    }
}

// New: GB10 TTS Client
class GB10TTSClient {
    private let baseURL: String
    private let session: URLSession
    
    func synthesize(text: String, language: String) async throws -> Data {
        // HTTP request to GB10
        // Return audio data
    }
    
    func synthesizeStreaming(text: String, language: String) async throws -> AsyncThrowingStream<Data, Error> {
        // If GB10 supports streaming
    }
}
```

### API Design for GB10

**Request:**
```json
POST /tts
Content-Type: application/json

{
  "text": "The text to synthesize",
  "language": "en-US",
  "voice": "default",  // Optional: specific voice model
  "speed": 1.0,       // Optional: playback speed
  "pitch": 1.0        // Optional: pitch adjustment
}
```

**Response:**
- Option 1: Audio file (WAV/MP3)
  ```
  Content-Type: audio/wav
  [binary audio data]
  ```
- Option 2: Streaming
  ```
  Content-Type: audio/wav
  Transfer-Encoding: chunked
  [streaming audio chunks]
  ```
- Option 3: JSON with base64 audio
  ```json
  {
    "audio": "base64-encoded-audio-data",
    "format": "wav",
    "sample_rate": 22050
  }
  ```

### Configuration

**Settings to Add:**
- GB10 server URL (e.g., `http://gb10.local:8080`)
- Enable/disable GB10 TTS (fallback to system)
- Cache size limit
- Voice selection per language

**User Preferences:**
```swift
@AppStorage("gb10ServerURL") private var gb10URL = "http://gb10.local:8080"
@AppStorage("useGB10TTS") private var useGB10 = true
@AppStorage("ttsCacheEnabled") private var cacheEnabled = true
```

---

## Implementation Plan

### Phase 1: Core GB10 Integration
1. Create `GB10TTSClient` class
2. Implement HTTP request/response handling
3. Add audio data parsing
4. Basic error handling

### Phase 2: Audio Playback
1. Replace `AVSpeechSynthesizer` with `AVAudioPlayer` or `AVAudioEngine`
2. Integrate with `AudioDirector` (maintain routing compatibility)
3. Handle audio session configuration
4. Implement playback completion callbacks

### Phase 3: Language & Voice Support
1. Map language codes to GB10 voice models
2. Implement fallback mechanism
3. Add voice selection UI (if multiple voices per language)

### Phase 4: Caching & Performance
1. Implement audio cache (disk + memory)
2. Add cache management (size limits, cleanup)
3. Optimize for latency (prefetch, streaming if available)

### Phase 5: Error Handling & Fallback
1. Network error handling
2. GB10 unavailable fallback (system TTS or user notification)
3. Audio playback error recovery
4. User-facing error messages

### Phase 6: Testing & Polish
1. Test all language codes
2. Test audio routing (speaker, Bluetooth, AirPods)
3. Test interruptions (phone calls, other apps)
4. Performance testing (latency, memory usage)
5. Background playback testing

---

## Technical Considerations

### Audio Format
- **Recommended:** WAV (uncompressed, low latency) or MP3 (compressed, smaller)
- **Sample Rate:** 22050 Hz or 44100 Hz (match GB10 output)
- **Channels:** Mono or Stereo (mono sufficient for speech)
- **Bit Depth:** 16-bit (standard)

### Audio Session
- Maintain current `AudioSession` configuration
- Category: `.playAndRecord` (for TTS + STT)
- Mode: `.spokenAudio` or `.voiceChat`
- Options: `.defaultToSpeaker`, `.allowBluetooth`, `.allowBluetoothA2DP`

### Memory Management
- Cache size limits (e.g., 50MB max)
- LRU eviction for cache
- Release audio buffers after playback
- Handle memory warnings

### Network
- Timeout: 10-15 seconds for TTS request
- Retry: 1-2 retries on failure
- Offline: Fallback to system TTS or show error
- Background: Support background audio continuation

### Concurrency
- Use async/await for network requests
- Main actor for UI updates (`@Published` properties)
- Thread-safe audio playback
- Handle cancellation (Task cancellation)

---

## Code Changes Required

### Files to Modify

1. **`anki-voice-ios/AnkiVoice/AnkiVoice/ContentView.swift`**
   - Replace `SpeechTTS` class implementation
   - Remove `AVSpeechSynthesizer` dependencies
   - Add GB10 client integration
   - Update `speak()` and `speakAndWait()` methods

2. **`anki-voice-ios/AnkiVoice/AnkiVoice/AudioDirector.swift`**
   - Verify compatibility with new audio playback
   - May need minor adjustments for `AVAudioPlayer` vs `AVSpeechSynthesizer`

3. **New Files to Create:**
   - `GB10TTSClient.swift` - GB10 API client
   - `TTSCache.swift` - Audio caching implementation
   - `AudioPlayerManager.swift` - Wrapper for AVAudioPlayer/AVAudioEngine

### Dependencies
- No new external dependencies required (use Foundation/AVFoundation)
- If GB10 requires specific SDK, document here

---

## Testing Requirements

### Unit Tests
- GB10 client request/response parsing
- Audio cache hit/miss logic
- Language code mapping
- Error handling paths

### Integration Tests
- End-to-end TTS flow (text → GB10 → audio → playback)
- Audio routing (speaker, Bluetooth)
- Language switching
- Cache behavior

### Manual Testing
- All card reading scenarios
- Error messages
- User prompts
- Different languages
- Network failures
- GB10 unavailable scenarios
- Background playback
- Audio interruptions

---

## Open Questions

1. **GB10 API Specification:**
   - What is the exact endpoint URL?
   - What is the request/response format?
   - Does it support streaming?
   - What languages/voices are available?
   - Authentication requirements?

2. **Network Configuration:**
   - How is GB10 discovered? (mDNS, static IP, manual config)
   - What port does it use?
   - HTTP or HTTPS?
   - CORS requirements?

3. **Voice Selection:**
   - Does GB10 support multiple voices per language?
   - How are voices identified/selected?
   - Can users customize voice parameters (speed, pitch, etc.)?

4. **Fallback Strategy:**
   - Should we fallback to system TTS if GB10 unavailable?
   - Or show error and require user action?
   - Cache fallback audio?

5. **Performance Targets:**
   - Acceptable latency? (e.g., < 500ms from request to playback start)
   - Cache hit rate target?
   - Memory usage limits?

---

## Success Criteria

✅ **Functional:**
- All TTS functionality works with GB10
- Language support matches current implementation
- Audio routing works correctly (speaker, Bluetooth)
- Error handling is robust

✅ **Performance:**
- Latency < 500ms for cached audio
- Latency < 2s for network requests (acceptable for first-time)
- Memory usage < 100MB for cache
- No audio glitches or interruptions

✅ **User Experience:**
- Seamless transition from system TTS
- Clear error messages if GB10 unavailable
- Settings UI for GB10 configuration
- No regression in existing functionality

---

## Timeline Estimate

- **Phase 1-2:** 1-2 weeks (Core integration + audio playback)
- **Phase 3:** 1 week (Language support)
- **Phase 4:** 1 week (Caching)
- **Phase 5:** 1 week (Error handling)
- **Phase 6:** 1 week (Testing & polish)

**Total:** 5-7 weeks

---

## Additional Notes

- This change maintains backward compatibility with the existing API interface
- The `speak()` and `speakAndWait()` methods keep the same signature
- Audio routing via `AudioDirector` should remain compatible
- Consider adding analytics to track GB10 usage vs fallback scenarios

---

## References

### Current Implementation Files:
- `anki-voice-ios/AnkiVoice/AnkiVoice/ContentView.swift` (lines 395-540)
- `anki-voice-ios/AnkiVoice/AnkiVoice/AudioDirector.swift`
- `anki-voice-ios/AnkiVoice/AnkiVoice/AudioSession.swift`

### API Endpoints:
- Server: `/current` endpoint provides `front_language` and `back_language`
- Server: `anki-voice-server/app/main.py` (lines 70-108 for language hints)

### Related Documentation:
- `FOR_DEV.md` - System architecture overview
- iOS AVFoundation documentation for `AVAudioPlayer`/`AVAudioEngine`

---

**Prepared by:** Development Team  
**Date:** 2025-12-07  
**Status:** Awaiting GB10 API specification and expert review

