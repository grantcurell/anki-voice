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
├── anki-voice-bridge/     # Anki add-on (Python)
├── anki-voice-server/     # FastAPI server (Python)  
├── anki-voice-ios/        # iOS app (SwiftUI)
└── README.md             # This file
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
   python3 -m venv venv
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
   # Edit .env file with your OpenAI API key
   ```

4. **Start the server**:
   ```bash
   cd anki-voice-server
   source venv/bin/activate  # Activate virtual environment
   uvicorn app.main:app --host 0.0.0.0 --port 8000
   ```
   
   Or use the activation script:
   ```bash
   cd anki-voice-server
   ./activate.sh
   ```

5. **Build iOS app**:
   - Open `anki-voice-ios` in Xcode
   - Add "Speech Recognition" capability
   - Build and run on device

## 🐍 Virtual Environments

Each repository uses Python 3.12 virtual environments for dependency isolation:

- **anki-voice-server**: Contains FastAPI server with all dependencies
- **anki-voice-bridge**: Minimal virtual environment for consistency

### Virtual Environment Commands

```bash
# Activate server environment
cd anki-voice-server
source venv/bin/activate

# Install/update dependencies
pip install -r requirements.txt

# Start server
uvicorn app.main:app --host 0.0.0.0 --port 8000

# Deactivate when done
deactivate
```

## 🎤 Voice Commands

The app recognizes voice commands for grading and asking questions. Commands are processed after you finish speaking your answer.

### Grade Commands (Auto-Submit - No Confirmation)

Clear, unambiguous grade commands are submitted immediately:

**Again (Ease 1):**
- `"again"`
- `"wrong"`
- `"grade 1"`
- `"mark one"`
- `"mark it 1"`
- `"set to 1"`
- `"repeat"`
- `"fail"` or `"failed"`

**Hard (Ease 2):**
- `"hard"`
- `"difficult"`
- `"grade 2"`
- `"mark two"`
- `"mark it 2"`

**Good (Ease 3):**
- `"good"`
- `"grade 3"`
- `"mark three"`
- `"ok"` or `"okay"`
- `"correct"`
- `"decent"`
- `"solid"`

**Easy (Ease 4):**
- `"easy"`
- `"grade 4"`
- `"mark four"`
- `"trivial"`
- `"simple"`

**Number Words:**
- `"one"`, `"two"`, `"three"`, `"four"` (bare numbers)
- `"grade one"`, `"mark two"`, etc.

### Grade Commands (Require Confirmation)

Ambiguous or descriptive phrases require confirmation:

- `"that was good"`
- `"pretty easy"`
- `"kind of hard"`
- `"sort of difficult"`

The app will ask: *"Mark good? Say confirm to proceed, or say a different grade."*

### Question Commands

Ask follow-up questions about the current card:

**Question Starters:**
- `"why is..."`
- `"what does..."`
- `"how does..."`
- `"explain more about..."`
- `"tell me more"`
- `"give me an example"`
- `"what does NEF mean"`
- `"i don't understand"`
- `"not clear"`
- `"can you explain"`
- `"help me understand"`

Any sentence starting with question words (what, why, how, when, where, who, which) or containing "explain", "clarify", "more about", "don't understand", or similar phrases will be treated as a question.

### Confirmation Commands

When prompted to confirm a grade:

**Confirm:**
- `"confirm"`
- `"yes"`
- `"do it"`
- `"that's fine"`
- `"okay"` or `"ok"`

**Cancel:**
- `"no"`
- `"cancel"`
- `"wait"`
- `"hold on"`
- `"change"`

Or simply wait 3 seconds for auto-confirmation.

### Undo Commands

After submitting a grade, you can undo it:

- `"undo"`
- `"change"`
- `"take back"`

This calls Anki's undo review function to revert the last grade.

### Usage Flow

1. **Card is read aloud** - Listen to the question
2. **Speak your answer** - The app listens until you pause (~1.8s silence)
3. **Explanation provided** - You hear feedback about your answer
4. **Grade or ask questions:**
   - Say **`"grade good"`** → Submitted immediately
   - Say **`"that was pretty good"`** → Confirmation requested
   - Ask **`"explain more about URLLC"`** → Get detailed explanation
5. **After grading** - Say **`"undo"`** within a few seconds to change it

## 🔄 How It Works

1. **iPhone fetches current card** from server
2. **Server gets card data** from Anki add-on
3. **iPhone speaks the card front** using text-to-speech
4. **iPhone captures your answer** using speech recognition
5. **Server grades your answer** using rules + GPT-5
6. **iPhone announces verdict** and suggested ease
7. **You select ease** via voice commands or buttons
8. **Server sends result** to Anki via AnkiConnect

## 🧪 Testing

### Test Anki Add-on
```bash
curl http://127.0.0.1:8770/current
```

### Test Server
```bash
curl http://127.0.0.1:8000/current
```

### Test Grading
```bash
curl -X POST http://127.0.0.1:8000/grade \
  -H "Content-Type: application/json" \
  -d '{"cardId": 123, "transcript": "there are three: embb, urllc, and mmtc", "question_text": "How many SNASSI settings...?", "reference_text": "Three: enhanced mobile broadband, ultra reliable low latency, massive machine type"}'
```

## 🔧 Configuration

### Server (.env)
```env
OPENAI_API_KEY=sk-your-key-here
OPENAI_API_BASE=https://api.openai.com/v1
OPENAI_MODEL=gpt-5-chat-latest
USE_GPT5=1
```

### iOS App
- Set server URL to your desktop's IP (e.g., `http://192.168.1.50:8000`)
- Grant speech recognition permission when prompted

## 🛠️ Development

Each component has its own README with detailed setup instructions:

- [Anki Voice Bridge](./anki-voice-bridge/README.md) - Anki add-on
- [Anki Voice Server](./anki-voice-server/README.md) - FastAPI server  
- [Anki Voice iOS](./anki-voice-ios/README.md) - iOS app

## 🔒 Security

- All services run on localhost by default
- Server can be opened to LAN for iPhone access (use VPN/firewall)
- Never expose AnkiConnect directly to internet
- OpenAI API calls are made server-side only

## 🐛 Troubleshooting

### Common Issues

1. **"No card is ready"**: Make sure you're in Anki's reviewer (not deck browser)
2. **Speech recognition fails**: Requires physical iOS device, not simulator
3. **Server connection fails**: Check iPhone and desktop are on same network
4. **Grading fails**: Verify OpenAI API key is correct and has GPT-5 access

### Health Check

```bash
# Check AnkiConnect
curl -X POST 127.0.0.1:8765 -d '{"action":"version","version":6}'

# Check add-on
curl http://127.0.0.1:8770/current

# Check server
curl http://127.0.0.1:8000/current
```

## 📚 References

- [AnkiConnect Documentation](https://github.com/amikey/anki-connect)
- [Anki Add-ons Guide](https://addon-docs.ankiweb.net/)
- [Apple Speech Framework](https://developer.apple.com/documentation/speech)
- [OpenAI API Documentation](https://platform.openai.com/docs)

## 🤝 Contributing

This is a complete working system following the expert's specifications. Each component can be extended independently:

- Add more grading rules in `judge.py`
- Extend iOS UI with additional features
- Add concept Q&A endpoint in server
- Create additional Anki add-on endpoints

## 📄 License

This project implements the specifications provided by the expert. Use responsibly and in accordance with OpenAI's API terms of service.
