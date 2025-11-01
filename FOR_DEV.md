# FOR_DEV.md - Complete Developer Guide

## 🎯 Project Overview

**Anki Voice** is a hands-free flashcard review system that enables voice-based interaction with Anki cards while preserving Anki's sophisticated spaced repetition scheduling algorithm. The system consists of three interconnected components that work together to provide a seamless voice-driven learning experience.

### What We're Building

- **iPhone App**: Reads card fronts aloud, captures spoken answers, and announces grading results
- **FastAPI Server**: Bridges iPhone and Anki, provides semantic grading using GPT-5
- **Anki Add-on**: Exposes current card data for the voice system to access
- **AnkiConnect Integration**: Sends review results back to Anki's scheduler

### Why This Matters

Traditional Anki review requires visual attention and manual clicking. This system enables:
- **Hands-free learning** while walking, exercising, or multitasking
- **Accessibility** for users with visual impairments
- **Efficient review sessions** without needing to look at screens
- **Preserved scheduling** - all of Anki's spaced repetition benefits remain intact

## 🏗️ System Architecture

```
┌─────────────────┐    HTTP/JSON    ┌─────────────────┐
│   iPhone App    │◄──────────────►│  FastAPI Server │
│   (SwiftUI)     │                 │   (Python 3.12) │
│                 │                 │                 │
│ • Speech-to-Text│                 │ • Card Proxy    │
│ • Text-to-Speech│                 │ • GPT-5 Grading │
│ • UI Controls   │                 │ • Rule Engine   │
└─────────────────┘                 └─────────────────┘
                                              │
                                              │ HTTP
                                              ▼
                                    ┌─────────────────┐
                                    │  Anki Add-on    │
                                    │   (Python)      │
                                    │                 │
                                    │ • Card Access   │
                                    │ • HTML Rendering│
                                    └─────────────────┘
                                              │
                                              │ AnkiConnect API
                                              ▼
                                    ┌─────────────────┐
                                    │   Anki Desktop  │
                                    │                 │
                                    │ • Card Display  │
                                    │ • Scheduler     │
                                    │ • Statistics    │
                                    └─────────────────┘
```

### Data Flow

1. **Card Fetch**: iPhone → Server → Anki Add-on → Anki Desktop
2. **Voice Input**: iPhone captures speech → Server grades → Anki receives result
3. **Scheduling**: Anki's algorithm determines next review time based on ease rating

## 📁 Repository Structure

```
Anki Voice/
├── anki-voice-bridge/          # Anki Add-on (Python)
│   ├── __init__.py            # Main add-on code
│   ├── venv/                  # Python 3.12 virtual environment
│   └── README.md              # Add-on specific docs
│
├── anki-voice-server/          # FastAPI Server (Python)
│   ├── app/
│   │   ├── __init__.py        # Package init
│   │   ├── main.py            # FastAPI app & endpoints
│   │   ├── ankiconnect.py     # AnkiConnect API client
│   │   ├── judge.py           # Grading logic & rules
│   │   ├── normalize.py       # Text processing utilities
│   │   └── openai_client.py   # GPT-5 API integration
│   ├── venv/                  # Python 3.12 virtual environment
│   ├── requirements.txt       # Python dependencies
│   ├── .env                   # Environment variables (API keys)
│   ├── activate.sh            # Virtual env activation script
│   └── README.md              # Server specific docs
│
├── anki-voice-ios/             # iOS App (SwiftUI)
│   ├── ContentView.swift       # Main app interface
│   └── README.md              # iOS specific docs
│
├── secrets                     # API keys (gitignored)
├── setup-venv.sh              # Automated setup with venvs
├── setup.sh                   # Basic setup script
├── setup-macos.sh             # macOS specific setup
├── .gitignore                 # Git ignore rules
└── README.md                  # Main project documentation
```

## 🚀 Quick Start for New Developers

### Prerequisites

- **macOS**: For iOS development (Xcode required)
- **Anki**: Desktop application installed
- **Python 3.12+**: Latest version via Homebrew
- **OpenAI API Key**: With GPT-5 access
- **iPhone**: Physical device (speech recognition doesn't work in simulator)

### 1. Clone and Setup

```bash
git clone <repository-url>
cd "Anki Voice"

# Run automated setup (installs Python 3.12, creates venvs, installs deps)
./setup-venv.sh
```

### 2. Install AnkiConnect

1. Open Anki desktop application
2. Go to Tools → Add-ons → Get Add-ons
3. Enter code: `2055492159`
4. Restart Anki

### 3. Configure API Keys

The `secrets` file contains your OpenAI API key. It's automatically copied to the server's `.env` file during setup.

### 4. Start the Server

```bash
cd anki-voice-server
./activate.sh  # Activates venv and shows instructions
# Then run: uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### 5. Build iOS App

1. Open `anki-voice-ios` in Xcode
2. Add "Speech Recognition" capability in project settings
3. Add to Info.plist:
   ```xml
   <key>NSSpeechRecognitionUsageDescription</key>
   <string>This app uses speech recognition to capture your spoken answers to flashcards.</string>
   ```
4. Build and run on physical iPhone device

## 🔧 Development Workflow

### Testing Individual Components

**Test Anki Add-on:**
```bash
# Start Anki, open a deck for review
curl http://127.0.0.1:8770/current
# Should return JSON with current card data
```

**Test Server:**
```bash
cd anki-voice-server
source venv/bin/activate
uvicorn app.main:app --host 127.0.0.1 --port 8000

# In another terminal:
curl http://127.0.0.1:8000/current
curl http://127.0.0.1:8000/docs  # Interactive API docs
```

**Test Grading:**
```bash
curl -X POST http://127.0.0.1:8000/grade \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 123,
    "transcript": "there are three: embb, urllc, and mmtc",
    "question_text": "How many SNASSI settings are there?",
    "reference_text": "Three: enhanced mobile broadband, ultra reliable low latency, massive machine type"
  }'
```

### Development Tips

1. **Virtual Environments**: Always work within the activated virtual environment
2. **API Testing**: Use the FastAPI docs at `http://127.0.0.1:8000/docs` for interactive testing
3. **Logging**: Server logs appear in the terminal where uvicorn is running
4. **Hot Reload**: Server automatically reloads on code changes (--reload flag)

## 🧩 Component Deep Dive

### Anki Voice Bridge (Add-on)

**Purpose**: Exposes current reviewer card data via HTTP API

**Key Files**:
- `__init__.py`: Main add-on code using Anki hooks

**How it Works**:
- Uses Anki's `profileLoaded` hook to start HTTP server
- Exposes `/current` endpoint returning card HTML and metadata
- Runs on port 8770 (localhost only for security)

**Anki Integration**:
- Accesses `mw.reviewer` to get current card
- Uses `reviewer._mungeQA()` for rendered HTML
- Leverages Anki's built-in template rendering

### Anki Voice Server (FastAPI)

**Purpose**: Central hub for all voice system operations

**Key Endpoints**:
- `GET /current`: Proxy to add-on, adds plain text versions
- `POST /grade`: Hybrid grading (rules + GPT-5)
- `POST /answer/{ease}`: Send review result to Anki
- `POST /show-answer`: Reveal card back on desktop

**Grading System**:
1. **Rule-based**: Fast deterministic matching for structured cards
2. **GPT-5 Fallback**: Semantic analysis for complex answers
3. **Confidence Scoring**: Combines multiple signals for accuracy

**Key Files**:
- `main.py`: FastAPI app and endpoint definitions
- `judge.py`: Grading logic and rule engine
- `openai_client.py`: GPT-5 API integration
- `ankiconnect.py`: AnkiConnect API client
- `normalize.py`: Text processing utilities

### Anki Voice iOS (SwiftUI)

**Purpose**: Voice-driven user interface for card review

**Key Features**:
- Speech-to-text using `SFSpeechRecognizer`
- Text-to-speech using `AVSpeechSynthesizer`
- HTTP client for server communication
- Manual ease selection (Again/Hard/Good/Easy)

**User Flow**:
1. Fetch current card from server
2. Speak card front using TTS
3. Capture user's spoken answer
4. Send transcript for grading
5. Announce verdict and suggested ease
6. Allow user to select final ease rating
7. Send result to Anki via server

## 🔒 Security Considerations

- **Local Network Only**: All services run on localhost by default
- **API Key Protection**: OpenAI key stored in `.env` (gitignored)
- **CORS Configuration**: Server allows iPhone app access
- **No Internet Exposure**: AnkiConnect never exposed to internet

## 🐛 Troubleshooting Guide

### Common Issues

**"No card is ready"**
- Ensure you're in Anki's reviewer (not deck browser)
- Check that a card is actually displayed
- Verify add-on is running: `curl http://127.0.0.1:8770/current`

**Speech recognition fails**
- Requires physical iPhone device (not simulator)
- Check microphone permissions
- Ensure device is on same network as server

**Server connection fails**
- Verify server is running: `curl http://127.0.0.1:8000/current`
- Check iPhone and desktop are on same network
- Update server URL in iOS app to desktop's IP address

**Grading fails**
- Check OpenAI API key in `.env` file
- Verify API key has GPT-5 access
- Check server logs for API errors

### Debug Commands

```bash
# Check AnkiConnect
curl -X POST 127.0.0.1:8765 -d '{"action":"version","version":6}'

# Check add-on
curl http://127.0.0.1:8770/current

# Check server
curl http://127.0.0.1:8000/current

# View server logs
cd anki-voice-server
source venv/bin/activate
uvicorn app.main:app --host 127.0.0.1 --port 8000 --log-level debug
```

## 🚀 Future Enhancements

### Planned Features

1. **Concept Q&A**: Ask follow-up questions about card topics
2. **Deck-specific Rules**: Custom grading rules per deck
3. **Voice Commands**: "Mark that hard" voice shortcuts
4. **Statistics**: Review session analytics
5. **Shortcuts Integration**: iOS Shortcuts app support

### Technical Improvements

1. **WebSocket Streaming**: Real-time partial transcript updates
2. **Offline Mode**: On-device grading for common cards
3. **Multi-language Support**: Internationalization
4. **Performance Optimization**: Caching and async improvements

## 📚 Key Technologies

### Backend
- **FastAPI**: Modern Python web framework
- **Pydantic**: Data validation and serialization
- **httpx**: Async HTTP client
- **BeautifulSoup4**: HTML parsing
- **OpenAI API**: GPT-5 integration

### Frontend
- **SwiftUI**: iOS app framework
- **Speech Framework**: Apple's speech recognition
- **AVFoundation**: Text-to-speech
- **URLSession**: HTTP networking

### Integration
- **AnkiConnect**: Anki API bridge
- **Anki Hooks**: Add-on integration
- **CORS**: Cross-origin resource sharing

## 🤝 Contributing

### Code Style
- **Python**: Follow PEP 8, use type hints
- **Swift**: Follow Apple's Swift style guide
- **Documentation**: Update this file for architectural changes

### Testing
- Test each component individually before integration
- Use the provided curl commands for API testing
- Test on physical iPhone device for speech features

### Pull Requests
1. Update relevant README files
2. Test on macOS with Python 3.12
3. Ensure virtual environments work correctly
4. Update this developer guide if needed

## 📖 Additional Resources

- [AnkiConnect Documentation](https://github.com/amikey/anki-connect)
- [Anki Add-ons Guide](https://addon-docs.ankiweb.net/)
- [Apple Speech Framework](https://developer.apple.com/documentation/speech)
- [OpenAI API Documentation](https://platform.openai.com/docs)
- [FastAPI Documentation](https://fastapi.tiangolo.com/)

---

**Remember**: This system preserves Anki's sophisticated scheduling algorithm while adding voice interaction. The core learning benefits remain unchanged - we're just changing the interface from visual/manual to voice-driven.

