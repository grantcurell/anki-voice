# Anki Voice System

A complete hands-free Anki card review system that uses speech recognition, semantic grading with GPT-5, and text-to-speech to enable voice-based flashcard review on iPhone while preserving Anki's scheduling algorithm.

## 🎯 What This Does

- **iPhone App**: Reads card fronts aloud, captures your spoken answers, and announces grading results
- **FastAPI Server**: Bridges between iPhone and Anki, provides semantic grading using GPT-5
- **Anki Add-on**: Exposes current card data for the voice system to access
- **AnkiConnect Integration**: Sends review results back to Anki's scheduler

## 🏗️ Architecture

```
iPhone App (SwiftUI) ←→ FastAPI Server ←→ Anki Add-on ←→ Anki Desktop
                              ↓
                         OpenAI GPT-5 API
                              ↓
                         AnkiConnect ←→ Anki Desktop
```

## 📁 Repository Structure

```
Anki Voice/
├── anki-voice-server/     # FastAPI server (Python)  
├── anki-voice-ios/        # iOS app (SwiftUI)
├── anki-deck-update/      # Scripts for configuring deck languages
└── README.md              # This file
```

## 🚀 Quick Start

### Prerequisites

- **macOS/Windows/Linux**: Anki 2.1.x installed
- **iPhone**: iOS 13.0+ with physical device (speech recognition requires device)
- **OpenAI API Key**: With GPT-5 access
- **Python 3.12+**: For the server (recommended)
- **Homebrew**: For macOS Python installation
- **Xcode**: For iOS development

### Installation

1. **Set up the server**:
   ```bash
   cd anki-voice-server
   python3.12 -m venv venv
   source venv/bin/activate  # On macOS/Linux
   pip install -r requirements.txt
   ```

2. **Install AnkiConnect**:
   - Open Anki → Tools → Add-ons → Get Add-ons
   - Enter code: `2055492159`
   - Restart Anki

3. **Configure OpenAI API**:
   ```bash
   cd anki-voice-server
   # Create .env file with your OpenAI API key
   echo "OPENAI_API_KEY=sk-your-key-here" > .env
   echo "OPENAI_API_BASE=https://api.openai.com/v1" >> .env
   echo "OPENAI_MODEL=gpt-5-mini" >> .env
   echo "USE_GPT5=1" >> .env
   ```

4. **Start the server**:
   ```bash
   cd anki-voice-server
   source venv/bin/activate
   uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```

5. **Build iOS app**:
   - Open `anki-voice-ios/AnkiVoice/AnkiVoice.xcodeproj` in Xcode
   - Add "Speech Recognition" capability
   - Build and run on device
   - Set server URL to your Mac's IP address (e.g., `http://192.168.1.50:8000`)

## 🎤 Complete Voice Commands Reference

The app recognizes voice commands at different stages of the review process. Commands are processed after you finish speaking (about 1.8 seconds of silence).

### Commands During Answer Phase

These commands work while you're providing your answer or after you've finished speaking:

#### Reread Question
- `"reread question"`
- `"reread the question"`
- `"say the question again"`
- `"read question again"`
- `"repeat question"`
- `"repeat the question"`

**What it does**: Repeats the question without changing the review state. You remain in the answer phase.

#### Reread Answer
- `"reread answer"`
- `"reread the answer"`
- `"say the answer again"`
- `"read answer again"`

**What it does**: Reads the answer text while still in the answer phase (before grading).

#### Read Answer (Skip Grading)
- `"read answer"`
- `"read the answer"`
- `"show answer"`
- `"tell me the answer"`

**What it does**: Skips LLM grading, reads the answer text, and moves to the action phase where you can grade or ask questions.

#### I Don't Know
- `"i don't know"`
- `"i have no idea"`
- `"i'm not sure"`
- `"no idea"`
- `"don't know"`
- `"i dunno"`

**What it does**: Skips LLM grading, immediately shows and reads the answer, then moves to the action phase.

#### Delete Note (Suspend Card)
- `"delete note"`
- `"delete the note"`
- `"remove note"`
- `"remove the note"`
- `"delete this note"`
- `"delete card"`
- `"delete the card"`

**What it does**: Asks for confirmation. If confirmed, suspends the card (it won't appear in reviews but the note is preserved). The app then advances to the next card.

#### Undo Last Grade
- `"undo"`
- `"change"`
- `"take back"`
- `"undo that"`
- `"change that"`

**What it does**: Undoes the last grade you submitted and returns to the previous card.

#### Immediate Grade Commands
You can grade directly during the answer phase with unambiguous commands (see Grade Commands section below). These skip LLM grading and immediately submit the grade.

### Commands During Action Phase

After the explanation is read, you can use these commands:

#### Grade Commands (Auto-Submit - No Confirmation)

Clear, unambiguous grade commands are submitted immediately:

**Again (Ease 1):**
- `"again"`
- `"wrong"`
- `"grade 1"` or `"grade one"`
- `"mark 1"` or `"mark one"`
- `"mark it 1"`
- `"set to 1"`
- `"repeat"`
- `"fail"` or `"failed"`
- `"miss"` or `"missed"`
- `"red"`

**Hard (Ease 2):**
- `"hard"`
- `"difficult"`
- `"grade 2"` or `"grade two"`
- `"mark 2"` or `"mark two"`
- `"mark it 2"`
- `"struggled"`

**Good (Ease 3):**
- `"good"`
- `"grade 3"` or `"grade three"`
- `"mark 3"` or `"mark three"`
- `"ok"` or `"okay"`
- `"correct"`
- `"decent"`
- `"solid"`

**Easy (Ease 4):**
- `"easy"`
- `"grade 4"` or `"grade four"`
- `"mark 4"` or `"mark four"`
- `"trivial"`
- `"simple"`

**Number Words:**
- `"one"`, `"two"`, `"three"`, `"four"` (bare numbers)
- `"grade one"`, `"mark two"`, etc.

#### Grade Commands (Require Confirmation)

Ambiguous or descriptive phrases require confirmation:

- `"that was good"`
- `"pretty easy"`
- `"kind of hard"`
- `"sort of difficult"`

The app will ask: *"Mark good? Say confirm to proceed, or say a different grade."*

**To confirm:**
- `"confirm"`
- `"yes"`
- `"do it"`
- `"that's fine"`
- `"okay"` or `"ok"`

**To cancel:**
- `"no"`
- `"cancel"`
- `"wait"`
- `"hold on"`
- `"change"`

Or simply wait 3 seconds for auto-confirmation.

#### Question Commands

Ask follow-up questions about the current card:

**Question Starters:**
- `"why is..."`
- `"what does..."`
- `"how does..."`
- `"when..."`
- `"where..."`
- `"who..."`
- `"which..."`
- `"explain more about..."`
- `"tell me more"`
- `"give me an example"`
- `"what does NEF mean"`
- `"i don't understand"`
- `"not clear"`
- `"can you explain"`
- `"help me understand"`
- `"clarify"`
- `"compare"`
- `"more about"`

Any sentence starting with question words or containing "explain", "clarify", "more about", "don't understand", or similar phrases will be treated as a question. The app uses GPT-5 to answer your question using the card's context.

#### Read Answer (During Action Phase)
- `"read answer"`
- `"read the answer"`
- `"show answer"`
- `"tell me the answer"`

**What it does**: Reads the answer text again.

#### Undo Commands (During Action Phase)
- `"undo"`
- `"change"`
- `"take back"`

**What it does**: Undoes the last grade you submitted and returns to the previous card.

## 🎛️ Buttons and UI Controls

### Home Screen (Idle State)

#### Server URL Text Field
- **Location**: Top of the screen
- **Purpose**: Enter your Mac's IP address and port (e.g., `http://192.168.1.50:8000`)
- **Persistence**: URL is saved and remembered between app launches

#### Authorize Speech & Mic Button
- **Location**: Below server URL field
- **Purpose**: Request microphone and speech recognition permissions
- **Visibility**: Only shown if permissions haven't been granted
- **What it does**: Opens iOS permission dialogs for microphone and speech recognition access

#### Open Settings Button
- **Location**: Shown if permissions were previously denied
- **Purpose**: Opens iPhone Settings app to manually enable permissions
- **When to use**: If you denied permissions and need to enable them later

#### Deck Selection Dropdown
- **Location**: Below authorization section
- **Purpose**: Select which Anki deck to review
- **How it works**: 
  - Tap "Load Decks" to fetch available decks from Anki
  - Select a deck from the dropdown menu
  - The selected deck will be used when you start a review

#### Start Review Button
- **Location**: Below deck selection
- **Purpose**: Begin a review session with the selected deck
- **What it does**: 
  - Fetches the current card from Anki
  - Speaks the card front using text-to-speech
  - Begins listening for your answer
- **State changes**: After starting, button changes to "Return to deck selection"

#### Return to Deck Selection Button
- **Location**: Same as "Start Review" button (replaces it during review)
- **Purpose**: Stop the current review and return to deck selection
- **What it does**: 
  - Stops all audio I/O
  - Resets state to idle
  - Returns to home screen

#### Sync Button
- **Location**: Below "State: idle" indicator
- **Purpose**: Synchronize Anki collection with AnkiWeb
- **What it does**: 
  - Calls AnkiConnect's sync action
  - Shows "Syncing..." with progress indicator while syncing
  - Speaks "Sync complete" when finished
  - Can take up to 2 minutes for large collections
- **Visibility**: Only shown when app is in idle state

### During Review

#### Mute Button
- **Location**: Top-right corner during review
- **Purpose**: Mute/unmute the microphone
- **What it does**: 
  - When muted: Stops speech recognition, microphone icon shows muted state
  - When unmuted: Resumes speech recognition
  - Provides instant feedback

#### Read Answer Button
- **Location**: Below card display
- **Purpose**: Skip LLM grading and read the answer
- **What it does**: 
  - Shows and reads the card back
  - Moves to action phase where you can grade or ask questions
- **Visibility**: Shown when not in idle state

#### Grade Buttons (Again / Hard / Good / Easy)
- **Location**: Bottom of screen, horizontal layout
- **Purpose**: Submit a grade for the current card
- **What it does**: 
  - **During question reading**: Skips to answer phase
  - **During answer phase**: Immediately submits grade (skips LLM)
  - **During explanation**: Stops TTS and immediately submits grade
  - **During action phase**: Immediately submits grade
  - **During confirmation**: Confirms the pending grade
- **Ease values**: 
  - Again = 1 (red)
  - Hard = 2 (orange)
  - Good = 3 (green)
  - Easy = 4 (blue)

#### "Say 'undo' to change the last grade" Hint
- **Location**: Below grade buttons
- **Purpose**: Reminds you that you can undo the last grade
- **Visibility**: Shown briefly after submitting a grade

## 🔄 Complete Review Flow

1. **Start Review**: Tap "Start Review" button or select a deck and start
2. **Question Read**: App speaks the card front using text-to-speech
3. **Answer Phase**: 
   - App listens for your spoken answer
   - Live transcript appears as you speak
   - You can use voice commands (reread question, read answer, etc.)
   - After ~1.8 seconds of silence, your answer is captured
4. **Grading**:
   - **Normal path**: Answer is sent to GPT-5 for semantic grading
   - **Skip paths**: If you say "read answer" or "I don't know", grading is skipped
   - **Immediate grade**: If you say an unambiguous grade command, it's submitted immediately
5. **Explanation**: App speaks feedback about your answer (if using normal path)
6. **Action Phase**: 
   - App listens for grade commands or questions
   - You can grade via voice or buttons
   - You can ask follow-up questions
7. **Grade Submission**: Grade is sent to Anki via AnkiConnect
8. **Next Card**: App automatically fetches and speaks the next card

## 🌍 Multilingual TTS Support

The app supports different TTS voices for different languages:

### How It Works

1. **README Div Extraction**: The app only reads content inside `<div>` elements with the `README` class
2. **Language Detection**: The app looks for `lang` attributes in the README div (e.g., `lang="es-ES"`, `lang="en-US"`)
3. **Language Priority**:
   - Innermost `lang` attribute in README div (most specific)
   - Deck-level configuration (from `_ankiVoice.deck.<deck>.json` in Anki media folder)
   - Note-level tags (e.g., `av:front=es-ES`, `av:back=en-US`)
   - Default: `en-US` (English)

### Setting Up Multilingual Decks

Use the `anki-deck-update/anki_voice_lang_setup.py` script:

```bash
cd anki-deck-update
python3 anki_voice_lang_setup.py \
  --deck "Spanish 1" \
  --front-lang es-ES \
  --back-lang en-US \
  --tag-notes
```

This will:
- Create a deck-level language config file in Anki's media folder
- Optionally tag all notes in the deck with language hints
- Use Castilian Spanish for card fronts and US English for card backs

### Card Template Example

```html
<!-- Front Template -->
<div class="README" lang="es-ES">{{SpanishWord}}</div>

<!-- Back Template -->
{{FrontSide}}
<div class="README" lang="en-US">{{EnglishDefinition}}</div>
```

The app will:
- **Show**: The entire card (all HTML content)
- **Read**: Only the content inside the `README` div
- **Use language**: The `lang` attribute from the README div (or deck/note config)

## 🔧 Configuration

### Server (.env)
```env
OPENAI_API_KEY=sk-your-key-here
OPENAI_API_BASE=https://api.openai.com/v1
OPENAI_MODEL=gpt-5-mini
USE_GPT5=1
```

### iOS App
- Set server URL to your desktop's IP (e.g., `http://192.168.1.50:8000`)
- Grant speech recognition permission when prompted
- Grant microphone permission when prompted

## 🧪 Testing

### Test Anki Add-on
```bash
curl http://127.0.0.1:8770/current
```

### Test Server
```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/current
```

### Test Grading
```bash
curl -X POST http://127.0.0.1:8000/grade-with-explanation \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 123,
    "transcript": "there are three: embb, urllc, and mmtc",
    "question_text": "How many SNASSI settings?",
    "reference_text": "Three: enhanced mobile broadband, ultra reliable low latency, massive machine type"
  }'
```

## 🐛 Troubleshooting

### Common Issues

1. **"No card is ready"**: Make sure you're in Anki's reviewer (not deck browser)
2. **Speech recognition fails**: Requires physical iOS device, not simulator
3. **Server connection fails**: Check iPhone and desktop are on same network
4. **Grading fails**: Verify OpenAI API key is correct and has GPT-5 access
5. **Sync button does nothing**: Check that Anki is running and AnkiConnect is installed
6. **Mute button doesn't work**: Make sure you're using the latest version of the app

### Health Check

```bash
# Check AnkiConnect
curl -X POST http://127.0.0.1:8765 \
  -H "Content-Type: application/json" \
  -d '{"action":"version","version":6}'

# Check add-on
curl http://127.0.0.1:8770/current

# Check server
curl http://127.0.0.1:8000/health
```

## 📚 References

- [AnkiConnect Documentation](https://github.com/amikey/anki-connect)
- [Anki Add-ons Guide](https://addon-docs.ankiweb.net/)
- [Apple Speech Framework](https://developer.apple.com/documentation/speech)
- [OpenAI API Documentation](https://platform.openai.com/docs)

## 🤝 Contributing

This is a complete working system. Each component can be extended independently:

- Add more grading rules in `judge.py`
- Extend iOS UI with additional features
- Add concept Q&A endpoint in server
- Create additional Anki add-on endpoints

## 📄 License

This project implements the specifications provided by the expert. Use responsibly and in accordance with OpenAI's API terms of service.
