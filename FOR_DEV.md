# FOR_DEV.md - Complete Developer Guide

## 🎯 Project Overview

**Anki Voice** is a hands-free flashcard review system that enables voice-based interaction with Anki cards while preserving Anki's sophisticated spaced repetition scheduling algorithm. The system consists of four interconnected components that work together to provide a seamless voice-driven learning experience.

### What We're Building

- **iPhone App (SwiftUI)**: Reads card fronts aloud, captures spoken answers, and announces grading results
- **FastAPI Server (Python)**: Bridges iPhone and Anki, provides semantic grading using LLM (Ollama with GPU acceleration)
- **Anki Voice Bridge Add-on (Python)**: Exposes current card data for the voice system to access
- **AnkiConnect Integration**: Sends review results back to Anki's scheduler

### Why This Matters

Traditional Anki review requires visual attention and manual clicking. This system enables:
- **Hands-free learning** while walking, exercising, or multitasking
- **Accessibility** for users with visual impairments
- **Efficient review sessions** without needing to look at screens
- **Preserved scheduling** - all of Anki's spaced repetition benefits remain intact

## 🏗️ System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     iPhone App (iOS)                        │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  ContentView.swift                                    │  │
│  │  • Speech Recognition (SFSpeechRecognizer)          │  │
│  │  • Text-to-Speech (AVSpeechSynthesizer)             │  │
│  │  • HTTP Client (URLSession)                         │  │
│  │  • State Machine (ReviewState enum)                 │  │
│  │  • Authentication UI (Register/Logout buttons)      │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  AuthService.swift                                    │  │
│  │  • Sign in with Apple integration                    │  │
│  │  • JWT token management                               │  │
│  │  • API authentication (Authorization headers)       │  │
│  │  • Sync credentials auto-generated on registration │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  KeychainHelper.swift                                 │  │
│  │  • Secure JWT storage in iOS Keychain                │  │
│  │  • Credential retrieval on app launch                │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  IntentParser.swift                                   │  │
│  │  • Parses voice commands into UserIntent             │  │
│  │  • Handles grade commands, questions, ambiguity      │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  MicPermissionKit (Framework)                        │  │
│  │  • Objective-C shim for deprecated APIs              │  │
│  │  • Wraps AVAudioSession microphone permissions       │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ HTTPS/JSON
                           │ Production: https://api.grantcurell.com
                           │ Dev: http://<mac-ip>:8000 (when not authenticated)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              Backend API (Kubernetes)                        │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  POST /auth/apple - Apple Sign-In authentication     │  │
│  │  GET /anki/sync-setup - View sync credentials (web) │  │
│  │  POST /anki/sync - Trigger Anki sync                  │  │
│  │  POST /secrets/decrypt - Decrypt credentials (sidecar)│ │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Gateway Service                                       │  │
│  │  POST /ac - Proxy AnkiConnect requests to tenants     │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ HTTP/JSON (port 8000)
                           │ Legacy: http://<mac-ip>:8000
                           ▼
┌─────────────────────────────────────────────────────────────┐
│              FastAPI Server (Python 3.12)                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  app/main.py                                          │  │
│  │  • FastAPI app with CORS middleware                   │  │
│  │  • API endpoints (see API Documentation section)     │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  app/openai_client.py                                 │  │
│  │  • grade_with_llm() - Basic grading                   │  │
│  │  • grade_with_llm_explanation() - Detailed feedback    │  │
│  │  • answer_followup() - Q&A about cards                │  │
│  │  • Uses Ollama LLM API (GPU-accelerated)              │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  app/judge.py                                         │  │
│  │  • list_set_match() - Rule-based matching             │  │
│  │  • ease_from_verdict() - Maps verdict to ease (1-4)   │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  app/normalize.py                                    │  │
│  │  • html_to_text() - Strips HTML for TTS              │  │
│  │  • html_to_text_readme_only() - Extracts README div │  │
│  │  • normalize_text() - Normalizes speech transcripts │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  app/ankiconnect.py                                  │  │
│  │  • ac_call() - Generic AnkiConnect API wrapper       │  │
│  │  • show_answer() - Reveals card back                  │  │
│  │  • answer_card(ease) - Submits grade                  │  │
│  │  • undo_review() - Undoes last grade                  │  │
│  │  • get_deck_names() - Gets all deck names              │  │
│  │  • gui_deck_review() - Switches to a deck             │  │
│  │  • get_deck_stats() - Gets new/review card counts     │  │
│  │  • ac_call_checked() - Helper for AnkiConnect calls  │  │
│  │  • sync() - Synchronizes with self-hosted server      │  │
│  │  • suspend_cards() - Suspends cards                    │  │
│  │  • retrieve_media_file() - Reads from media folder    │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ HTTP (port 8770)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│          Anki Voice Bridge Add-on (Python)                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  __init__.py (Anki add-on file)                       │  │
│  │  • Starts HTTP server on port 8770                    │  │
│  │  • Exposes /current endpoint                          │  │
│  │  • Accesses mw.reviewer for current card              │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ Internal API
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                  Anki Desktop Application                    │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  AnkiConnect Add-on (port 8765)                       │  │
│  │  • guiShowAnswer - Shows card back                    │  │
│  │  • guiAnswerCard - Submits grade                      │  │
│  │  • guiUndoReview - Undoes last grade                  │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                              │
│  ┌───────────────────────────────────────────────────────┐  │
│  │  Anki Scheduler                                       │  │
│  │  • Calculates next review time                        │  │
│  │  • Updates card ease/intervals                        │  │
│  │  • Maintains spaced repetition algorithm              │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                           │
                           │ HTTP (port 8765)
                           ▲
                           │
              (AnkiConnect API calls)
```

### Data Flow (Step-by-Step)

**User Registration and Setup:**

1. **User opens iOS app for the first time**
   - App shows "Register" button in top-right corner
   - User taps "Register" button
   - iOS presents Sign in with Apple dialog
   - User authenticates with Apple ID

2. **Apple Sign-In completes**
   - iOS app receives Apple identity token (JWT)
   - App calls `POST https://api.grantcurell.com/auth/apple` with identity token
   - Backend API verifies Apple token with Apple's JWKS
   - Backend creates/updates user account in database
   - Backend issues app JWT (RS256, 7-day expiration)
   - App stores JWT and user_id in iOS Keychain
   - App shows "Signed in" status

3. **Sync credentials are auto-generated**
   - When user registers/logs in, sync credentials are automatically created
   - User can access `https://api.grantcurell.com/anki/sync-setup` to view credentials
   - Credentials are used to configure Anki Desktop to sync with self-hosted server
   - Backend encrypts credentials (libsodium sealed box)
   - Backend creates tenant in Kubernetes (namespace, PVC, Deployment, etc.)
   - Backend stores encrypted credentials in database
   - App shows success message
   - App optionally triggers initial sync via `POST /anki/sync`

**Complete Review Cycle:**

1. **User taps "Start Review" in iOS app**
   - iOS app checks if authenticated (JWT in Keychain)
   - If authenticated, uses production API: `https://api.grantcurell.com`
   - If not authenticated, uses local dev server URL
   - iOS app sends `GET /current` with `Authorization: Bearer <JWT>` header
   - Gateway service verifies JWT and routes to user's tenant
   - Tenant sidecar proxies to AnkiConnect
   - AnkiConnect returns current card data

2. **iOS app receives card data**
   - Sets state to `.readingFront(cardId, front, back)`
   - Displays question text in UI
   - Calls `tts.speakAndWait(front)` to speak the question

3. **After TTS finishes**
   - Sets state to `.awaitingAnswer(cardId, front, back)`
   - Calls `listenForAnswerContinuous()` which:
     - Starts `SpeechSTT` (speech recognition)
     - Listens continuously for user's answer
     - Waits for user to stop speaking (~1.8s silence)
     - Captures transcript

4. **User provides answer**
   - iOS app detects one of several paths:
     - **"Reread Question" phrases** → Calls `handleRereadQuestion()`, repeats question, stays in answer phase
     - **"Reread Answer" phrases** → Calls `handleRereadAnswer()`, reads answer, stays in answer phase
     - **"Read Answer" phrases** → Calls `handleReadAnswer()`, skips LLM, moves to action phase
     - **"Delete Note" phrases** → Transitions to `.confirmingDelete`, asks for confirmation
     - **"I don't know"** → Reads back text, skips LLM, moves to action phase
     - **"Undo" phrases** → Calls `undoLastGrade()`, undoes last grade, returns to previous card
     - **Unambiguous grade** (e.g., "good") → Immediately submits grade, skips LLM
     - **Normal path** → Sends to LLM for grading

5. **Grading with LLM (normal path)**
   - Sets `showBackDuringProcessing = true` (shows answer in UI)
   - Sends `POST /grade-with-explanation` to server with:
     ```json
     {
       "cardId": 123,
       "transcript": "user's spoken answer",
       "question_text": "card front",
       "reference_text": "card back"
     }
     ```
   - Server processes:
     - First tries rule-based matching in `judge.py`
     - If not perfect, calls `grade_with_llm_explanation()` in `openai_client.py`
     - Returns: `{correct: bool, explanation: string, confidence: float, missing: [], extras: []}`

6. **iOS app receives explanation**
   - Sets state to `.explaining(cardId, front, back, explanation)`
   - Displays answer text in UI
   - Speaks explanation using TTS

7. **After explanation finishes**
   - Sets state to `.awaitingAction(cardId, front, back)`
   - Calls `listenForAction()` which:
     - Starts continuous speech recognition
     - Listens for grade commands or questions

8. **User provides grade or question**
   - **Unambiguous grade** (e.g., "good") → Immediately submits via `submitGrade(3)`
   - **Ambiguous grade** (e.g., "that was good") → Transitions to `.confirmingGrade`, asks for confirmation
   - **Question** → Sends to `/ask` endpoint, speaks answer
   - **"Read Answer"** → Reads back text again
   - **"Undo"** → Calls `/undo` endpoint, reverts last grade, returns to previous card

9. **Grade submission**
   - iOS app sends `POST /submit-grade` with `{cardId, ease}`
   - Server calls `show_answer()` to ensure Anki is showing the answer
   - Server calls `answer_card(ease)` via AnkiConnect
   - Anki processes grade and updates scheduler
   - iOS app receives success, speaks confirmation, calls `startReview()` to fetch next card

## 📁 Repository Structure

```
Anki Voice/
├── .gitignore                      # Git ignore patterns (venv, .env, logs, etc.)
├── README.md                       # Main project documentation
├── FOR_DEV.md                      # This file - comprehensive developer guide
├── LICENSE                         # Project license
├── secrets                         # API keys (gitignored, NOT committed)
│
├── anki-voice-server/              # FastAPI Server (Python 3.12)
│   ├── app/
│   │   ├── __init__.py             # Package marker (empty)
│   │   ├── main.py                 # FastAPI app, all API endpoints
│   │   ├── ankiconnect.py          # AnkiConnect API client wrapper
│   │   ├── judge.py               # Rule-based grading logic
│   │   ├── normalize.py           # Text processing (HTML stripping, normalization)
│   │   ├── openai_client.py       # LLM API integration (Ollama)
│   │   └── __pycache__/           # Python bytecode cache (gitignored)
│   ├── venv/                       # Python 3.12 virtual environment (gitignored)
│   │   ├── bin/                    # Executables (python, pip, uvicorn, etc.)
│   │   ├── lib/                    # Installed packages
│   │   └── pyvenv.cfg              # Virtual environment config
│   ├── requirements.txt            # Python dependencies
│   │   # Contents:
│   │   # fastapi==0.119.0
│   │   # uvicorn[standard]==0.38.0
│   │   # httpx==0.28.1
│   │   # python-dotenv==1.1.1
│   │   # beautifulsoup4==4.14.2
│   │   # pydantic==2.12.3
│   ├── pyproject.toml              # Poetry config (not actively used)
│   ├── .env                        # Environment variables (gitignored)
│   │   # Contents:
│   │   # OPENAI_API_KEY=sk-...
│   │   # OPENAI_API_BASE=https://api.openai.com/v1
│   │   # OLLAMA_MODEL=llama2:latest
│   │   # USE_LLM=1
│   ├── activate.sh                 # Helper script to activate venv and show instructions
│   ├── server.log                  # Server logs (gitignored, may not exist)
│   └── README.md                   # Server-specific documentation
│
└── anki-voice-ios/                 # iOS App (SwiftUI)
    ├── AnkiVoice/
    │   ├── AnkiVoice/
    │   │   ├── AnkiVoiceApp.swift          # App entry point (@main struct)
    │   │   ├── ContentView.swift           # Main view (3600+ lines, all app logic)
    │   │   ├── AuthService.swift           # Authentication service (Sign in with Apple, JWT management)
    │   │   ├── KeychainHelper.swift        # Secure Keychain storage for JWT tokens
    │   │   ├── IntentParser.swift          # Voice command parsing logic
    │   │   ├── Info.plist                  # App metadata, permissions, ATS config
    │   │   ├── AnkiVoice.entitlements      # App capabilities (speech recognition, Sign in with Apple)
    │   │   └── Assets.xcassets/            # App icon and colors
    │   ├── AnkiVoice.xcodeproj/             # Xcode project file
    │   │   └── project.pbxproj              # Xcode project settings
    │   ├── AnkiVoiceTests/
    │   │   └── IntentParserTests.swift     # Unit tests for IntentParser
    │   ├── MicPermissionKit/                # Framework for mic permissions
    │   │   ├── MicPermissionKit.h          # Framework umbrella header
    │   │   ├── MicPermissionShim.h          # Objective-C header
    │   │   ├── MicPermissionShim.m          # Objective-C implementation (suppresses warnings)
    │   │   └── MicPermissionKit.docc/       # Documentation (may be empty)
    │   └── README.md                        # iOS-specific documentation
    │
    └── README.md                            # iOS app documentation (duplicate in root)
```

**Important Note**: The `anki-voice-bridge` directory mentioned in some documentation does not exist in the current codebase. The Anki add-on code would need to be installed separately in Anki's add-ons directory.

## 🚀 Complete Setup Instructions for New Developers

### Prerequisites (Install These First)

**macOS System Requirements:**
- macOS 12.0 or later
- Xcode 15.0 or later (download from App Store or Apple Developer)
- Command Line Tools (install via Xcode or `xcode-select --install`)
- Homebrew (install from https://brew.sh)

**Python Requirements:**
- Python 3.12 or later
  - Check version: `python3 --version` (should show 3.12.x or higher)
  - If missing: `brew install python@3.12`
  - Verify: `python3.12 --version`

**Anki Requirements:**
- Anki Desktop 2.1.x installed (download from https://apps.ankiweb.net)
- AnkiConnect add-on installed (code: `2055492159`)

**iOS Requirements:**
- Physical iPhone device (iOS 13.0+)
- iPhone connected to same Wi-Fi network as development Mac
- Xcode configured with your Apple Developer account (for device deployment)

**API Requirements:**
- LLM backend configured (Ollama with GPU acceleration)
- API key must start with `sk-` and have sufficient credits

### Step 1: Clone the Repository

```bash
# Navigate to your development directory
cd ~/Documents/code  # or wherever you keep projects

# Clone the repository (replace with actual URL)
git clone <repository-url>

# Navigate into the project
cd "Anki Voice"

# Verify you're in the right directory (should see the structure above)
ls -la
```

### Step 2: Set Up Python Virtual Environments

**You MUST use Python 3.12. The project explicitly requires it.**

```bash
# Verify Python 3.12 is available
python3.12 --version
# Should output: Python 3.12.x

# Navigate to server directory
cd anki-voice-server

# Create virtual environment with Python 3.12
python3.12 -m venv venv

# Activate the virtual environment
source venv/bin/activate

# Verify you're using the venv Python
which python
# Should show: .../anki-voice-server/venv/bin/python
python --version
# Should show: Python 3.12.x

# Install all dependencies
pip install --upgrade pip  # Always upgrade pip first
pip install -r requirements.txt

# Verify installation
pip list
# Should show: fastapi, uvicorn, httpx, python-dotenv, beautifulsoup4, pydantic

# Deactivate when done (for now)
deactivate
```

### Step 3: Configure Environment Variables

**Create the `.env` file in `anki-voice-server/` directory:**

```bash
cd anki-voice-server

# Create .env file
cat > .env << EOF
OPENAI_API_KEY=sk-your-actual-key-here
OPENAI_API_BASE=https://api.openai.com/v1
OLLAMA_MODEL=llama2:latest
USE_LLM=1
EOF

# Replace sk-your-actual-key-here with your real OpenAI API key
# The .env file is gitignored and will NOT be committed

# Verify the file was created
cat .env
# Should show your configuration (but DON'T commit this!)
```

**Environment Variable Details:**
- `OPENAI_API_KEY`: Your OpenAI API key starting with `sk-`. **REQUIRED** for LLM grading.
- `OPENAI_API_BASE`: Base URL for OpenAI API. Default: `https://api.openai.com/v1`. **Only change if using proxy or custom endpoint.**
- `OLLAMA_MODEL`: Model to use. Default: `llama2:latest`. **Must be a model available in Ollama.**
- `USE_LLM`: Set to `1` to enable LLM grading, `0` to disable (test mode). Default: `1`.

**Important**: Never commit the `.env` file. It's already in `.gitignore`.

### Step 4: Install and Configure AnkiConnect

**AnkiConnect is a separate add-on that must be installed in Anki Desktop:**

1. Open Anki Desktop application
2. Go to menu: **Tools → Add-ons → Get Add-ons**
3. Enter code: `2055492159`
4. Click **OK**
5. **Restart Anki** (completely quit and reopen)

**Verify AnkiConnect is Working:**
```bash
# AnkiConnect runs on port 8765
# Test with curl (Anki must be running):
curl -X POST http://127.0.0.1:8765 \
  -H "Content-Type: application/json" \
  -d '{"action": "version", "version": 6}'

# Should return JSON like: {"result": 6, "error": null}
# If you get connection refused, AnkiConnect is not running or Anki is not open
```

### Step 5: Install Anki Voice Bridge Add-on

**This add-on exposes the current card data. It must be manually installed:**

**Note**: The add-on code is not in this repository. You need to:

1. Create the add-on file at: `~/Library/Application Support/Anki2/addons21/anki_voice_bridge/__init__.py`
2. The add-on should start an HTTP server on port 8770
3. It should expose a `/current` endpoint that returns card data

**Since the add-on code is not in the repo, you'll need to either:**
- Get the add-on code from another source
- Write a simple add-on that:
  - Uses Anki's `profileLoaded` hook
  - Starts an HTTP server on `127.0.0.1:8770`
  - Exposes `/current` endpoint returning card HTML from `mw.reviewer`

**Verify Add-on is Working:**
```bash
# Make sure Anki is open with a card ready for review
curl http://127.0.0.1:8770/current

# Should return JSON with card data
# If you get connection refused, the add-on is not installed or not running
```

### Step 6: Start the FastAPI Server

```bash
# Navigate to server directory
cd anki-voice-server

# Activate virtual environment
source venv/bin/activate

# Start the server (bind to 0.0.0.0 so iPhone can connect)
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

# The --reload flag enables auto-reload on code changes (development only)
# In production, remove --reload for better performance
```

**You should see output like:**
```
INFO:     Uvicorn running on http://0.0.0.0:8000 (Press CTRL+C to quit)
INFO:     Started reloader process [xxxxx] using WatchFiles
INFO:     Started server process [xxxxx]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
```

**Keep this terminal window open. The server must stay running.**

**Test the Server:**
```bash
# In another terminal, test the server:
curl http://127.0.0.1:8000/health

# Should return JSON with status of all components
# Also visit: http://127.0.0.1:8000/docs for interactive API documentation
```

### Step 7: Configure iOS App

**Open the iOS project in Xcode:**
```bash
cd anki-voice-ios/AnkiVoice
open AnkiVoice.xcodeproj
```

**Configure Signing & Capabilities:**

1. Select the `AnkiVoice` target in Xcode
2. Go to "Signing & Capabilities" tab
3. Select your Team (Apple Developer account)
4. Xcode will automatically create a provisioning profile
5. Ensure the following capabilities are enabled:
   - **Speech Recognition** (automatic from entitlements)
   - **Sign in with Apple** (required for authentication)

**Verify Info.plist Configuration:**

The `Info.plist` file should already contain:
- `NSSpeechRecognitionUsageDescription` - Required for speech recognition
- `NSMicrophoneUsageDescription` - Required for microphone access
- `NSAppTransportSecurity` - Allows HTTP connections to local network

**These should already be configured. Do NOT remove them.**

**Authentication Setup:**

The app now supports two modes:

1. **Production Mode (Authenticated)**:
   - User signs in with Apple ID
   - App uses production API: `https://api.grantcurell.com`
   - All requests include JWT token in Authorization header
   - Sync credentials are auto-generated for self-hosted sync server

2. **Development Mode (Not Authenticated)**:
   - App uses local dev server URL (configurable in UI)
   - No authentication required
   - Direct connection to FastAPI server on Mac

**Get your Mac's IP address (for dev mode only):**

```bash
# On your Mac, run:
ifconfig | grep "inet " | grep -v 127.0.0.1

# Or use Tailscale MagicDNS:
# Your Mac's hostname.tail73fcb8.ts.net
```

# Write this down - you'll need it in the iOS app (dev mode only)

### Step 8: Build and Run iOS App

**Connect iPhone to Mac:**
1. Connect iPhone to Mac via USB cable
2. Unlock iPhone and trust the computer if prompted
3. In Xcode, select your iPhone from the device dropdown (top toolbar)

**Build and Run:**
1. In Xcode, click the **Play button** (or press `Cmd+R`)
2. Xcode will build the app and install it on your iPhone
3. The app will launch automatically

**If build fails:**
- Check that you selected the correct target (AnkiVoice)
- Check that Speech Recognition capability is enabled
- Check that your Apple Developer account is configured
- Look at the error messages in Xcode's Issue Navigator

**Grant Permissions:**
- When the app launches, it will request microphone permission - **Tap "Allow"**
- When prompted for speech recognition - **Tap "Allow"**
- If you denied these previously, go to iPhone Settings → AnkiVoice → Permissions and enable them

**First Launch - Production Mode (Recommended):**

1. Tap the "Register" button in the top-right corner
2. Sign in with your Apple ID
3. App will automatically store your JWT token
4. Sync credentials are automatically generated when you register/login
5. Access `https://api.grantcurell.com/anki/sync-setup` to view your credentials
6. Configure Anki Desktop to use the self-hosted sync server
7. Optionally tap "Sync" to perform initial sync
8. Tap "Start Review" to begin

**First Launch - Development Mode (Local Testing):**

1. If you don't want to authenticate, the app will show a "Server URL" text field
2. Enter your Mac's IP address or Tailscale MagicDNS hostname
   - Example: `http://grants-macbook-air.tail73fcb8.ts.net:8000`
   - Or: `http://192.168.1.50:8000` (your Mac's local IP)
3. Ensure your FastAPI server is running on your Mac
4. Tap "Start Review" to begin

## 📡 Complete API Documentation

### FastAPI Server Endpoints

**Base URL**: `http://<your-mac-ip>:8000` or `http://127.0.0.1:8000` for local testing

All endpoints return JSON. All POST endpoints accept JSON in the request body.

#### GET /health

**Purpose**: Check health status of all system components.

**Request**: No parameters needed.

**Response**:
```json
{
  "server": "ok",
  "anki_addon": "ok" | "unknown" | "error_<status>" | "error: <message>",
  "ankiconnect": "ok" | "error_<status>" | "error: <message>",
  "anki_running": "ok" | "not_running" | "unknown"
}
```

**Example**:
```bash
curl http://127.0.0.1:8000/health
```

**Status Codes**:
- `200 OK` - Always returns 200, check the JSON for component status

**Use Cases**:
- Debugging connectivity issues
- Verifying all services are running
- Health monitoring

---

#### GET /current

**Purpose**: Fetch the current card from Anki. This is the main endpoint used by the iOS app to get card data.

**Request**: No parameters needed.

**Response (Success)**:
```json
{
  "status": "ok",
  "cardId": 123,
  "front_html": "<html>Card front with formatting</html>",
  "back_html": "<html>Card back with formatting</html>",
  "front_text": "Plain text version of card front (full content for display)",
  "back_text": "Plain text version of card back (full content for display)",
  "front_text_tts": "Content from README div only (for TTS)",
  "back_text_tts": "Content from README div only (for TTS)",
  "front_language": "es-ES",
  "back_language": "en-US"
}
```

**Response (Error)**:
```json
{
  "status": "error",
  "message": "Error description",
  "details": "Detailed error message"
}
```

**Example**:
```bash
curl http://127.0.0.1:8000/current
```

**Status Codes**:
- `200 OK` - Request succeeded (check `status` field in response)
- Server internally handles errors and returns 200 with error JSON

**Implementation Details**:
- Server forwards request to Anki add-on at `http://127.0.0.1:8770/current`
- Server uses `html_to_text()` from `normalize.py` to convert HTML to plain text for display
- Server uses `html_to_text_readme_only()` to extract only README div content for TTS
- Server extracts `lang` attributes from README divs (innermost lang attribute is authoritative)
- Server gets language hints from deck config files (`_ankiVoice.deck.<deck>.json`) or note tags (`av:front=`, `av:back=`)
- Language priority: README div `lang` attribute > deck config > note tags > default `en-US`
- Returns both full text (for display) and README-only text (for TTS) with language hints

**Error Cases**:
- `"Cannot connect to Anki add-on"` - Add-on not running or Anki not open
- `"Anki add-on timeout"` - Add-on took too long to respond
- `"Anki add-on returned: error"` - Add-on returned an error status
- `"Unexpected error"` - Other server-side errors

---

#### POST /grade

**Purpose**: Grade a spoken transcript using rule-based matching and optionally LLM (Ollama).

**Request Body**:
```json
{
  "cardId": 123,
  "transcript": "user's spoken answer",
  "question_text": "Card front text (optional, for LLM fallback)",
  "reference_text": "Card back text (optional, for LLM fallback)"
}
```

**Response**:
```json
{
  "verdict": "correct" | "partial" | "wrong",
  "suggested_ease": 1 | 2 | 3 | 4,
  "reasons": {
    "rule_hits": ["enhanced mobile broadband", "ultra reliable low latency"],
    "rule_missing": ["massive machine type"],
    "llm": {
      "correct": true,
      "confidence": 0.85,
      "missing": [],
      "extras": [],
      "short_reason": "Semantic match"
    }
  }
}
```

**Example**:
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

**Status Codes**:
- `200 OK` - Grading completed successfully

**Implementation Details**:
1. First calls `list_set_match()` from `judge.py` with hardcoded SNASSI rules
2. If verdict is not "correct" AND `USE_LLM=1` AND `question_text`/`reference_text` are provided:
   - Calls `grade_with_llm()` from `openai_client.py`
   - If LLM returns `correct=true` and `confidence >= 0.65`, overrides verdict
3. Maps verdict to ease using `ease_from_verdict()`:
   - `"correct"` with `confidence > 0.85` → ease 4 (Easy)
   - `"correct"` → ease 3 (Good)
   - `"partial"` → ease 2 (Hard)
   - `"wrong"` → ease 1 (Again)

**Note**: This endpoint is used for quick grading. The iOS app primarily uses `/grade-with-explanation` for the full review flow.

---

#### POST /grade-with-explanation

**Purpose**: Grade a spoken transcript and return a detailed explanation. This is the main grading endpoint used by the iOS app.

**Request Body**:
```json
{
  "cardId": 123,
  "transcript": "user's spoken answer",
  "question_text": "Card front text (REQUIRED)",
  "reference_text": "Card back text (REQUIRED)"
}
```

**Response (Success)**:
```json
{
  "correct": true | false,
  "explanation": "Detailed explanation of what was right or wrong",
  "confidence": 0.85,
  "missing": ["point 1", "point 2"],
  "extras": ["incorrect point"]
}
```

**Response (Test Mode - when USE_LLM=0)**:
```json
{
  "correct": true,
  "explanation": "Test mode: looks correct.",
  "confidence": 0.9,
  "missing": [],
  "extras": []
}
```

**Error Responses**:
- `400 Bad Request`: `"grade-with-explanation requires question_text and reference_text"`
- `502 Bad Gateway`: `"LLM backend failed: <error message>"`
- `503 Service Unavailable`: `"OPENAI_API_KEY is not set on the server"`
- `500 Internal Server Error`: `"Server response formatting error"`

**Example**:
```bash
curl -X POST http://127.0.0.1:8000/grade-with-explanation \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 123,
    "transcript": "there are three: embb, urllc, and mmtc",
    "question_text": "How many SNASSI settings are there?",
    "reference_text": "Three: enhanced mobile broadband, ultra reliable low latency, massive machine type"
  }'
```

**Status Codes**:
- `200 OK` - Grading completed successfully
- `400 Bad Request` - Missing required fields
- `502 Bad Gateway` - LLM API call failed
- `503 Service Unavailable` - API key not configured
- `500 Internal Server Error` - Response parsing failed

**Implementation Details**:
1. Validates that `question_text` and `reference_text` are provided
2. If `USE_LLM=0`, returns test mode response (no LLM call)
3. Checks for `OLLAMA_BASE_URL` environment variable
4. Calls `grade_with_llm_explanation()` from `openai_client.py`
5. Parses JSON from LLM response
6. Returns formatted response with type coercion

**Timeout**: 45 seconds (configured in `openai_client.py`)

---

#### POST /submit-grade

**Purpose**: Submit a grade to Anki via AnkiConnect. This is called after the user selects an ease rating.

**Request Body**:
```json
{
  "cardId": 123,
  "ease": 1 | 2 | 3 | 4
}
```

**Response (Success)**:
```json
{
  "result": null,
  "error": null
}
```
or any valid AnkiConnect response

**Error Responses**:
- `400 Bad Request`: `"ease must be 1..4"`
- `409 Conflict`: `"Reviewer not ready: <error message>"`
- `502 Bad Gateway`: `"AnkiConnect error: <error message>"`

**Example**:
```bash
curl -X POST http://127.0.0.1:8000/submit-grade \
  -H "Content-Type: application/json" \
  -d '{"cardId": 123, "ease": 3}'
```

**Status Codes**:
- `200 OK` - Grade submitted successfully
- `400 Bad Request` - Invalid ease value
- `409 Conflict` - Anki reviewer not ready (card not shown)
- `502 Bad Gateway` - AnkiConnect error

**Implementation Details**:
1. Validates ease is 1-4
2. **CRITICAL**: Calls `show_answer()` first to ensure Anki is showing the answer
   - `guiAnswerCard` only works when the answer is visible
   - If `show_answer()` fails, returns 409 Conflict
3. Calls `answer_card(ease)` via AnkiConnect
4. If AnkiConnect returns an error, returns 502 Bad Gateway

**Important**: Always call `show_answer()` before `answer_card()` because AnkiConnect requires the answer to be visible.

---

#### POST /undo

**Purpose**: Undo the last grade submitted to Anki. Calls Anki's undo review function.

**Request**: No parameters needed.

**Response**:
```json
{
  "result": null,
  "error": null
}
```
or any valid AnkiConnect response

**Example**:
```bash
curl -X POST http://127.0.0.1:8000/undo
```

**Status Codes**:
- `200 OK` - Always returns 200 (check response for errors)

**Implementation Details**:
- Calls `undo_review()` which calls AnkiConnect's `guiUndoReview` action
- Returns whatever AnkiConnect returns

---

#### POST /ask

**Purpose**: Ask a follow-up question about the current card. Uses LLM (Ollama) to answer questions using card context.

**Request Body**:
```json
{
  "cardId": 123,
  "question": "User's follow-up question",
  "question_text": "Card front text (REQUIRED)",
  "reference_text": "Card back text (REQUIRED)"
}
```

**Response**:
```json
{
  "answer": "LLM's answer to the question"
}
```

**Error Responses**:
- `400 Bad Request`: `"ask requires question_text and reference_text"`

**Example**:
```bash
curl -X POST http://127.0.0.1:8000/ask \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 123,
    "question": "What does URLLC stand for?",
    "question_text": "What are the three SNASSI settings?",
    "reference_text": "Enhanced mobile broadband, ultra reliable low latency, massive machine type"
  }'
```

**Status Codes**:
- `200 OK` - Question answered successfully
- `400 Bad Request` - Missing required fields

**Implementation Details**:
- Validates `question_text` and `reference_text` are provided
- Calls `answer_followup()` from `openai_client.py`
- Uses LLM (Ollama) to generate a concise answer (3-6 sentences)
- Returns plain text answer

**Timeout**: 45 seconds

---

#### POST /show-answer

**Purpose**: Show the answer on Anki Desktop. This reveals the card back in the Anki reviewer.

**Request**: No parameters needed.

**Response**:
```json
{
  "result": null,
  "error": null
}
```
or any valid AnkiConnect response

**Example**:
```bash
curl -X POST http://127.0.0.1:8000/show-answer
```

**Status Codes**:
- `200 OK` - Always returns 200 (check response for errors)

**Implementation Details**:
- Calls `show_answer()` which calls AnkiConnect's `guiShowAnswer` action
- Returns whatever AnkiConnect returns
- This is idempotent - safe to call multiple times

**Note**: This endpoint is typically called internally by `/submit-grade` but can be called directly.

---

#### POST /answer/{ease}

**Purpose**: Legacy endpoint. Submits grade directly without showing answer first. **NOT USED BY iOS APP**.

**Request**: Path parameter `ease` (1-4)

**Response**: AnkiConnect response

**Status Codes**:
- `200 OK` - Grade submitted
- `400 Bad Request` - Invalid ease value

**Note**: The iOS app uses `/submit-grade` instead, which properly calls `show_answer()` first.

---

#### GET /decks

**Purpose**: Get a list of all available deck names from Anki.

**Request**: No parameters needed.

**Response (Success)**:
```json
{
  "status": "ok",
  "decks": ["Deck 1", "Deck 2", "Spanish 1", "Math Basics"]
}
```

**Error Responses**:
- `502 Bad Gateway`: `"Failed to get decks: <error message>"`

**Example**:
```bash
curl http://127.0.0.1:8000/decks
```

**Status Codes**:
- `200 OK` - Request succeeded
- `502 Bad Gateway` - AnkiConnect error

**Implementation Details**:
- Calls `get_deck_names()` which uses AnkiConnect's `deckNames` action
- Returns list of all deck names as strings

---

#### POST /switch-deck

**Purpose**: Switch Anki's reviewer to a different deck.

**Request**: Query parameter `name` (deck name as string)

**Response (Success)**:
```json
{
  "status": "ok",
  "deck": "Spanish 1"
}
```

**Error Responses**:
- `404 Not Found`: `"Deck not found: <deck name>"`
- `502 Bad Gateway`: `"Failed to switch deck: <error message>"`

**Example**:
```bash
curl -X POST "http://127.0.0.1:8000/switch-deck?name=Spanish%201"
```

**Status Codes**:
- `200 OK` - Deck switched successfully
- `404 Not Found` - Deck name not found
- `502 Bad Gateway` - AnkiConnect error

**Implementation Details**:
1. Validates that the deck exists using `get_deck_names()`
2. Calls `gui_deck_review(deck_name)` which uses AnkiConnect's `guiDeckReview` action
3. Opens the reviewer for the specified deck in Anki Desktop

**Note**: After switching decks, the iOS app should call `/current` to fetch the new deck's current card.

---

#### GET /anki/deck-stats (Production) or GET /deck-stats (Local Dev)

**Purpose**: Get statistics for a specific deck: count of new cards and review cards (due cards).

**Authentication**: 
- Production (`/anki/deck-stats`): Requires JWT Bearer token
- Local Dev (`/deck-stats`): No authentication required

**Request**: Query parameter `name` (deck name as string)

**Response (Success - 200 OK)**:
```json
{
  "status": "ok",
  "deck": "Norwegian",
  "new": 18,
  "review": 50
}
```

**Response (Error)**:
- `404 Not Found`: `"Deck not found: <deck name>"` or `"Not Found"` (if endpoint doesn't exist)
- `502 Bad Gateway`: `"Failed to get deck stats: <error message>"`
- `401 Unauthorized`: `"Invalid or expired token"` (production only)

**Example (Production)**:
```bash
curl -H "Authorization: Bearer <JWT_TOKEN>" \
  "https://api.grantcurell.com/anki/deck-stats?name=Norwegian"
```

**Example (Local Dev)**:
```bash
curl "http://127.0.0.1:8000/deck-stats?name=Norwegian"
```

**Status Codes**:
- `200 OK` - Successfully retrieved deck statistics
- `404 Not Found` - Deck doesn't exist or endpoint not found
- `502 Bad Gateway` - AnkiConnect error
- `401 Unauthorized` - Invalid/expired token (production only)

**Implementation Details**:
1. Validates that the deck exists using `get_deck_names()` (optional, can return 0/0 if deck doesn't exist)
2. Calls AnkiConnect `findCards` with query `deck:"<name>" is:new` to get new cards
3. Calls AnkiConnect `findCards` with query `deck:"<name>" is:due` to get review cards
4. Counts the card IDs in each result array
5. Returns the counts in the response

**AnkiConnect Queries**:
- New cards: `{"action": "findCards", "version": 6, "params": {"query": "deck:\"Norwegian\" is:new"}}`
- Review cards: `{"action": "findCards", "version": 6, "params": {"query": "deck:\"Norwegian\" is:due"}}`

**Important Notes**:
- Deck names in queries are quoted: `deck:"Norwegian"` (not `deck:Norwegian`) to handle spaces and special characters
- Uses `ac_call_checked()` helper which handles both dict `{"result": [...], "error": null}` and direct list responses from AnkiConnect
- The endpoint automatically selects the correct path based on authentication status in the iOS app

**Server Implementation**:
- `get_deck_stats(deck_name)` in `app/ankiconnect.py` - Makes AnkiConnect queries and counts results
- Uses `ac_call_checked()` helper for robust response handling
- Returns `{"new": count, "review": count}` dictionary

---

#### POST /sync

**Purpose**: Synchronize Anki collection with self-hosted sync server.

**Request**: No parameters needed.

**Response (Success)**:
```json
{
  "status": "ok",
  "result": null
}
```

**Error Responses**:
- `502 Bad Gateway`: `"Failed to sync: <error message>"`

**Example**:
```bash
curl -X POST http://127.0.0.1:8000/sync
```

**Status Codes**:
- `200 OK` - Sync completed successfully
- `502 Bad Gateway` - AnkiConnect error or timeout

**Implementation Details**:
- Calls `sync()` which uses AnkiConnect's `sync` action
- Uses a 120-second timeout (sync can take a while for large collections)
- Synchronizes the local Anki collection with self-hosted sync server

**Timeout**: 120 seconds (2 minutes)

---

#### POST /delete-note

**Purpose**: Suspend a card (safer than deleting - card won't appear in reviews but note is preserved).

**Request Body**:
```json
{
  "cardId": 123
}
```

**Response (Success)**:
```json
{
  "result": null,
  "error": null
}
```

**Error Responses**:
- `502 Bad Gateway`: `"AnkiConnect error: <error message>"`
- `500 Internal Server Error`: `"Failed to suspend card: <error message>"`

**Example**:
```bash
curl -X POST http://127.0.0.1:8000/delete-note \
  -H "Content-Type: application/json" \
  -d '{"cardId": 123}'
```

**Status Codes**:
- `200 OK` - Card suspended successfully
- `502 Bad Gateway` - AnkiConnect error
- `500 Internal Server Error` - Server-side error

**Implementation Details**:
- Calls `suspend_cards([cardId])` which uses AnkiConnect's `suspend` action
- Suspends the card (it won't appear in reviews but the note is preserved)
- This is safer than deleting, which can cause Anki to crash if done on the currently displayed card

**Note**: Despite the endpoint name "delete-note", this actually suspends the card. The name is kept for backward compatibility with the iOS app.

---

### AnkiConnect API (Internal)

**Base URL**: `http://127.0.0.1:8765`

AnkiConnect is a separate add-on that must be installed in Anki. The server uses it via `app/ankiconnect.py`.

**Actions Used**:
- `guiShowAnswer` - Shows the card back in Anki reviewer
- `guiAnswerCard` - Submits a grade (ease: 1-4)
- `guiUndoReview` - Undoes the last review action
- `deckNames` - Gets list of all deck names
- `guiDeckReview` - Opens reviewer for a specific deck
- `findCards` - Finds cards matching a query (used for deck statistics: `deck:"<name>" is:new` and `deck:"<name>" is:due`)
- `sync` - Synchronizes collection with self-hosted sync server
- `suspend` - Suspends cards (they won't appear in reviews)
- `cardsInfo` - Gets card information including deck name
- `notesInfo` - Gets note information including tags
- `retrieveMediaFile` - Retrieves files from Anki's media folder

**All AnkiConnect calls use version 6 of the API.**

---

### Anki Voice Bridge Add-on API (Internal)

**Base URL**: `http://127.0.0.1:8770`

**Endpoints**:
- `GET /current` - Returns current card HTML and metadata

**Note**: This add-on code is not in the repository. It must be installed separately in Anki's add-ons directory.

## 📱 iOS App Architecture

### Authentication and Registration

The iOS app now includes a complete authentication system using Sign in with Apple and JWT tokens.

#### AuthService (`AuthService.swift`)

**Purpose**: Centralized authentication service that handles Sign in with Apple, JWT token management, and API authentication.

**Key Features**:
- Sign in with Apple integration using `ASAuthorizationController`
- JWT token storage and retrieval from iOS Keychain
- Automatic Authorization header injection for all API requests
- Sync credentials auto-generated on registration/login
- Anki sync triggering

**Key Methods**:
```swift
// Sign in with Apple
func signInWithApple()

// Register with backend API
func registerWithApple(identityToken: String) async throws -> AppleAuthResponse

// Sync credentials are auto-generated - no linking required

// Trigger Anki sync
func syncAnki() async throws -> SyncAnkiResponse

// Get stored JWT token
func getJWT() -> String?

// Add Authorization header to requests
func addAuthHeader(to request: inout URLRequest)

// Logout (clears Keychain)
func logout()
```

**Observable Properties**:
- `@Published var isAuthenticated: Bool` - Authentication status
- `@Published var currentUserID: String?` - Current user ID
- `@Published var isLoading: Bool` - Loading state
- `@Published var errorMessage: String?` - Error messages

#### KeychainHelper (`KeychainHelper.swift`)

**Purpose**: Secure storage and retrieval of sensitive data (JWT tokens, user IDs) in iOS Keychain.

**Key Methods**:
```swift
// Save data to Keychain
static func save(key: String, value: String, service: String)

// Retrieve data from Keychain
static func get(key: String, service: String) -> String?

// Delete data from Keychain
static func delete(key: String, service: String)
```

**Security**:
- Uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for maximum security
- Data is encrypted by iOS Keychain
- Only accessible when device is unlocked
- Bound to specific device (not synced via iCloud)

#### Authentication Flow in ContentView

**Registration UI**:
- "Register" button appears in top-right when not authenticated
- Tapping button triggers Sign in with Apple
- Shows loading state during authentication
- Displays error messages if authentication fails

**Post-Registration**:
- Sync credentials are automatically generated after successful registration
- Form with email and password fields
- Validates input before submission
- Shows success/error feedback

**API Integration**:
- All API requests automatically include `Authorization: Bearer <JWT>` header
- Production API URL (`https://api.grantcurell.com`) used when authenticated
- Local dev server URL used when not authenticated (for development)

**URL Routing**:
```swift
func validatedBaseURL() -> String? {
    // If authenticated, use production API
    if authService.isAuthenticated {
        return "https://api.grantcurell.com"
    }
    // Otherwise use local dev server
    return validatedServerURL()
}
```

#### Entitlements

The app now requires Sign in with Apple capability in `AnkiVoice.entitlements`:
```xml
<key>com.apple.developer.applesignin</key>
<array>
    <string>Default</string>
</array>
```

### State Machine (ReviewState)

The iOS app uses a state machine to manage the review flow. All state transitions happen in `ContentView.swift`.

**State Enum**:
```swift
enum ReviewState: Equatable {
    case idle
    case readingFront(cardId: Int, front: String, back: String)
    case awaitingAnswer(cardId: Int, front: String, back: String)
    case explaining(cardId: Int, front: String, back: String, explanation: String)
    case awaitingAction(cardId: Int, front: String, back: String)
    case confirmingGrade(cardId: Int, ease: Int, front: String, back: String)
    case confirmingDelete(cardId: Int, front: String, back: String)
}
```

**State Descriptions**:

1. **`.idle`**
   - Initial state when app starts
   - No card loaded
   - User can configure server URL and grant permissions
   - Transitions to `.readingFront` when user taps "Start Review"

2. **`.readingFront(cardId, front, back)`**
   - Card data has been fetched
   - TTS is speaking the question (card front)
   - UI displays the question text
   - Transitions to `.awaitingAnswer` after TTS finishes

3. **`.awaitingAnswer(cardId, front, back)`**
   - Question has been spoken
   - STT is listening for user's answer
   - UI displays question (or answer if `showBackDuringProcessing = true`)
   - UI shows live transcript as user speaks
   - Transitions to `.explaining` when answer is captured and sent to LLM
   - OR transitions directly to `.awaitingAction` if user says "Read Answer" or "I don't know"

4. **`.explaining(cardId, front, back, explanation)`**
   - LLM has provided explanation
   - TTS is speaking the explanation
   - UI displays the answer text
   - User can press grade buttons to immediately submit grade
   - Transitions to `.awaitingAction` after TTS finishes

5. **`.awaitingAction(cardId, front, back)`**
   - Explanation has been spoken
   - STT is listening for grade commands or questions
   - UI displays the answer text
   - User can:
     - Say a grade command (e.g., "good")
     - Ask a question (e.g., "explain more about X")
     - Press grade buttons
     - Say "read answer" to hear the answer again
     - Say "undo" to undo last grade
   - Transitions to `.confirmingGrade` if grade is ambiguous
   - Transitions to `.readingFront` after successful grade submission (next card)

6. **`.confirmingGrade(cardId, ease, front, back)`**
   - User said an ambiguous grade (e.g., "that was good")
   - TTS is asking for confirmation
   - UI displays answer text
   - User can confirm or cancel
   - Transitions to `.awaitingAction` after confirmation/cancellation

7. **`.confirmingDelete(cardId, front, back)`**
   - User said "delete note" during answer phase
   - TTS is asking for confirmation
   - UI displays answer text
   - User can confirm or cancel
   - If confirmed, suspends the card and advances to next card
   - If cancelled, returns to `.awaitingAnswer` state

**State Transition Diagram**:
```
idle
  ↓ (startReview)
readingFront
  ↓ (TTS finishes)
awaitingAnswer
  ↓ (answer captured)
  ├→ explaining (normal path)
  │    ↓ (TTS finishes)
  │    awaitingAction
  │         ↓ (grade submitted)
  │         readingFront (next card)
  │
  ├→ awaitingAction (if "Read Answer" or "I don't know")
  │    ↓ (grade or question)
  │    confirmingGrade (if ambiguous)
  │    OR readingFront (if grade submitted)
  │
  ├→ confirmingDelete (if "delete note")
  │    ↓ (confirmed)
  │    readingFront (next card, card suspended)
  │    ↓ (cancelled)
  │    awaitingAnswer
  │
  └→ awaitingAction (if immediate grade voice command)
        ↓ (grade submitted)
        readingFront (next card)
```

### Key Classes and Functions

#### ContentView

**Purpose**: Main SwiftUI view containing all app logic (~3600 lines).

**New Authentication Properties**:
```swift
@StateObject private var authService = AuthService.shared
@State private var showLinkAnkiForm: Bool = false
@State private var ankiEmail: String = ""
@State private var ankiPassword: String = ""
@State private var isLinkingAnki: Bool = false
```

**New Authentication Methods**:
```swift
// Link AnkiWeb account
func linkAnkiWeb() async

// Sync Anki (now uses auth service)
func syncAnki() async
```

**Key Properties**:
- `@AppStorage("serverBaseURL") private var server` - Server URL (persisted)
- `@State private var state: ReviewState` - Current review state
- `@StateObject private var tts: SpeechTTS` - Text-to-speech engine
- `@StateObject private var stt: SpeechSTT` - Speech recognition engine
- `@State private var isListening: Bool` - Whether STT is currently listening
- `@State private var currentNetworkTask: Task<Void, Never>?` - Cancellable LLM call
- `@State private var showBackDuringProcessing: Bool` - Show answer while LLM is grading

**Key Functions**:

1. **`startReview() async`**
   - Fetches current card from server (`GET /current`)
   - Handles errors and provides TTS feedback
   - Sets state to `.readingFront` and speaks card front
   - Called when user taps "Start Review" or after successful grade submission

2. **`startAnswerPhase(cardId:front:back:) async`**
   - Prompts user "What's your answer?" (only once via `hasPromptedForAnswer`)
   - Sets state to `.awaitingAnswer`
   - Calls `listenForAnswerContinuous()`

3. **`listenForAnswerContinuous() async`**
   - Continuous listening loop for user's answer
   - Starts STT once and keeps it running
   - Detects when user stops speaking (~1.8s silence)
   - Handles special commands:
     - "Read Answer" phrases → `handleReadAnswer()`
     - Unambiguous grades → Immediate grade submission
     - "I don't know" → Reads back text
   - Normal path: Sends transcript to `getExplanation()`

4. **`getExplanation(transcript:) async`**
   - Sends `POST /grade-with-explanation` to server
   - Sets `showBackDuringProcessing = true` (shows answer in UI)
   - Handles timeouts and errors
   - Sets state to `.explaining` and speaks explanation
   - Transitions to `.awaitingAction` after TTS finishes

5. **`listenForAction() async`**
   - Continuous listening loop for commands
   - Parses utterances with `IntentParser.parse()`
   - Handles:
     - Unambiguous grades → `submitGrade()`
     - Ambiguous grades → Transitions to `.confirmingGrade`
     - Questions → `askFollowUp()`
     - "Read Answer" → `handleReadAnswer()`
     - "Undo" → `undoLastGrade()`

6. **`submitGrade(_ ease: Int) async -> Bool`**
   - Sends `POST /submit-grade` to server
   - Returns `true` on success, `false` on failure
   - Provides TTS feedback
   - On success, calls `startReview()` to fetch next card

7. **`handleGradeButton(_ ease: Int) async`**
   - Called when user presses grade buttons (Again/Hard/Good/Easy)
   - State-specific behavior:
     - `.readingFront` → Skip to answer phase
     - `.awaitingAnswer` → Immediate grade submission
     - `.explaining` → Stop TTS, immediate grade submission
     - `.awaitingAction` → Immediate grade submission
     - `.confirmingGrade` → Confirm pending grade

8. **`handleReadAnswer() async`**
   - Reads the card back text using TTS
   - Skips LLM grading
   - Sets state to `.awaitingAction` and starts listening

9. **`askFollowUp(question:) async`**
   - Sends `POST /ask` to server
   - Speaks the answer using TTS
   - Returns to `.awaitingAction` state

10. **`undoLastGrade() async`**
    - Sends `POST /undo` to server (calls AnkiConnect's `guiUndoReview`)
    - Calls `startReview()` to refetch current card (which will be the previous card after undo)

11. **`handleRereadQuestion() async`**
    - Rereads the question using TTS
    - Stays in `.awaitingAnswer` state
    - Resumes listening for answer

12. **`handleRereadAnswer() async`**
    - Rereads the answer using TTS
    - Stays in `.awaitingAnswer` state
    - Resumes listening for answer

13. **`listenForDeleteConfirmation() async`**
    - Listens for confirmation after user says "delete note"
    - If confirmed, calls `/delete-note` endpoint (suspends card)
    - Advances to next card or returns to answer phase if cancelled

14. **`switchDeck(to deck: String) async`**
    - Sends `POST /switch-deck` to server
    - Calls `startReview()` to fetch current card from new deck

15. **`fetchDecks() async`**
    - Sends `GET /decks` to server
    - Populates `availableDecks` state variable

16. **`fetchDeckStats(for deckName: String) async`**
    - Sends `GET /anki/deck-stats?name=<deck>` (production) or `GET /deck-stats?name=<deck>` (local dev)
    - Automatically selects endpoint path based on authentication status
    - Uses `URLComponents` for proper URL construction and query encoding
    - Updates `deckNewCount` and `deckReviewCount` state variables
    - Sets counts to 0 on error (so UI shows "New: 0 Review: 0" instead of nothing)
    - Includes comprehensive debug logging for troubleshooting

17. **`syncAnki() async`**
    - Sends `POST /sync` to server
    - Shows loading indicator while syncing
    - Provides TTS feedback when complete

18. **`returnToDeckSelection() async`**
    - Stops all audio I/O
    - Resets state to `.idle`
    - Returns to home screen

19. **`stopAllIO(deactivateSession:)`**
    - Stops TTS and STT
    - Optionally deactivates `AVAudioSession`
    - Used during state transitions

**Computed Properties**:

- `displayTitle: String` - Current UI title ("Question", "Answer", "Confirm", or "")
- `displayText: String` - Current UI text (question or answer based on state)
- `shouldShowTranscript: Bool` - Whether to show live transcript
- `stateDescription: String` - Human-readable state name for debugging

#### SpeechTTS

**Purpose**: Text-to-speech engine using `AVSpeechSynthesizer`.

**Key Properties**:
- `nonisolated(unsafe) let synth: AVSpeechSynthesizer` - Apple's TTS engine
- `private var voice: AVSpeechSynthesisVoice` - Selected voice (determined by `normalUSVoice()`)
- `private var waitCont: CheckedContinuation<Void, Never>?` - Continuation for async waiting

**Key Functions**:

1. **`speak(_ text: String)`**
   - Immediately speaks text (fire and forget)
   - Stops any current speech first
   - Used for short messages

2. **`speakAndWait(_ text: String) async`**
   - Speaks text and waits for completion
   - Uses `CheckedContinuation` to allow cancellation
   - Returns when speech finishes or is stopped
   - Used for main content (questions, explanations)

3. **`stopSpeaking()`**
   - Immediately stops all speech
   - Resumes any waiting continuations (prevents deadlock)
   - Called when user presses mute or skip

**Voice Selection**:
- Uses `normalUSVoice()` function to select voice
- Prioritizes: US Siri voices → Natural US voices → High-quality US voices → Default US voice
- Blacklists novelty/gag voices
- Voice is selected once at initialization

#### SpeechSTT

**Purpose**: Speech recognition engine using `SFSpeechRecognizer` and `AVAudioEngine`.

**Key Properties**:
- `@Published var transcript: String` - Current transcript (live updates)
- `@Published var isFinal: Bool` - Whether current transcript is final
- `private var engine: AVAudioEngine` - Audio input engine
- `private var recognitionTask: SFSpeechRecognitionTask?` - Current recognition task
- `private var isRunning: Bool` - Whether engine is running

**Key Functions**:

1. **`start() throws`**
   - Starts audio engine and speech recognition
   - Configures `AVAudioSession` for `.playAndRecord` with `.voiceChat` mode
   - Installs audio tap on input bus
   - Creates `SFSpeechRecognitionTask` with live updates
   - Updates `transcript` and `isFinal` as recognition progresses
   - Idempotent - checks `isRunning` before starting

2. **`stop()`**
   - Stops recognition task
   - Removes audio tap
   - Stops audio engine
   - Resets `transcript` and `isFinal`

**Audio Configuration**:
- Category: `.playAndRecord` (allows simultaneous input/output)
- Mode: `.voiceChat` (echo cancellation, duplex)
- Options: `.duckOthers`, `.allowBluetooth`, `.defaultToSpeaker`
- Preferred sample rate: 16000 Hz
- Preferred IO buffer duration: 0.005 seconds

#### IntentParser

**Purpose**: Parses user utterances into `UserIntent`.

**UserIntent Enum**:
```swift
enum UserIntent {
    case grade(ease: Int, canonical: String, unambiguous: Bool)
    case question(text: String)
    case ambiguous
}
```

**Key Function**:

**`parse(_ raw: String) -> UserIntent`**
- Normalizes input (lowercase, removes punctuation)
- Tries to match grade commands first
- Then checks if it looks like a question
- Returns `.ambiguous` if neither matches

**Grade Command Matching**:
1. **Explicit numerals**: "grade 3", "mark 2" → unambiguous
2. **Number words with verbs**: "grade three", "mark two" → unambiguous if verb present
3. **Bare grade words**: "good", "hard" → unambiguous if single word or with verb
4. **Ambiguous phrases**: "that was good", "pretty easy" → requires confirmation

**Question Detection**:
- Starts with question words: what, why, how, when, where, who, which
- Contains question phrases: explain, clarify, tell me, give me, help me
- Contains "don't understand", "not clear"
- Ends with "?"

**Grade Words Mapped**:
- Ease 1: again, wrong, repeat, fail, failed, miss, missed, red
- Ease 2: hard, difficult, struggled
- Ease 3: good, ok, okay, decent, solid, correct
- Ease 4: easy, trivial, simple

### Permission Management

**Two permissions are required**:

1. **Microphone Permission** (`NSMicrophoneUsageDescription`)
   - Required for speech recognition
   - Handled by `MicPermission` struct
   - Uses `MicPermissionKit` framework on iOS (wraps deprecated APIs)
   - Uses `AVAudioApplication` on macOS/visionOS

2. **Speech Recognition Permission** (`NSSpeechRecognitionUsageDescription`)
   - Required for `SFSpeechRecognizer`
   - Handled by `SpeechPermission` struct
   - Uses `SFSpeechRecognizer.requestAuthorization()`

**Permission Flow**:
1. App checks permissions on launch
2. If not granted, shows "Authorize STT" button
3. Button requests both permissions sequentially
4. If denied, shows error message and "Open Settings" button
5. User must grant permissions in Settings if previously denied

### UI Components

**Main UI Structure**:
```
VStack {
  // Permission status / error messages
  // Server URL text field
  // "Start Review" button
  // Card display (question/answer/transcript)
  // "Listening..." indicator
  // State debug info
  // "Read Answer" button (if not idle)
  // Grade buttons (Again/Hard/Good/Easy) (if not idle)
  // "Say 'undo' to change it" hint
}
```

**Grade Buttons**:
- Always visible when not in `.idle` state
- Full-width, horizontal layout
- Pressing a button immediately submits grade (state-dependent behavior)
- Provides haptic feedback on press

**Card Display**:
- Shows question during answer phase
- Shows live transcript as user speaks
- Shows answer during explanation and action phases
- Uses `displayTitle`, `displayText`, and `shouldShowTranscript` computed properties

## 🔧 Development Workflow

### Starting Development Session

**1. Start Anki Desktop:**
```bash
# Make sure Anki is running
# Open a deck
# Start a review session (card must be displayed)
```

**2. Verify AnkiConnect:**
```bash
curl -X POST http://127.0.0.1:8765 \
  -H "Content-Type: application/json" \
  -d '{"action": "version", "version": 6}'
# Should return: {"result": 6, "error": null}
```

**3. Verify Anki Add-on:**
```bash
curl http://127.0.0.1:8770/current
# Should return card data JSON
```

**4. Start FastAPI Server:**
```bash
cd anki-voice-server
source venv/bin/activate
uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
# Keep this terminal open
```

**5. Verify Server:**
```bash
# In another terminal:
curl http://127.0.0.1:8000/health
# Should return status of all components
```

**6. Build and Run iOS App:**
- Open `anki-voice-ios/AnkiVoice/AnkiVoice.xcodeproj` in Xcode
- Select iPhone device
- Press `Cmd+R` to build and run
- Grant permissions when prompted
- Set server URL to Mac's IP address
- Tap "Start Review"

### Making Code Changes

**Server Changes (Python):**
- Server auto-reloads when `--reload` flag is used
- Check server terminal for errors
- Test endpoints with `curl` or visit `http://127.0.0.1:8000/docs`

**iOS Changes (Swift):**
- Xcode auto-builds when you save
- Press `Cmd+R` to rebuild and run
- Check Xcode console for errors
- Test on physical device (speech recognition doesn't work in simulator)

### Testing Individual Components

**Test AnkiConnect:**
```bash
# Version check
curl -X POST http://127.0.0.1:8765 \
  -H "Content-Type: application/json" \
  -d '{"action": "version", "version": 6}'

# Show answer (requires card in reviewer)
curl -X POST http://127.0.0.1:8765 \
  -H "Content-Type: application/json" \
  -d '{"action": "guiShowAnswer", "version": 6}'
```

**Test Anki Add-on:**
```bash
# Get current card (requires card in reviewer)
curl http://127.0.0.1:8770/current
```

**Test Server Endpoints:**
```bash
# Health check
curl http://127.0.0.1:8000/health

# Get current card
curl http://127.0.0.1:8000/current

# Grade an answer
curl -X POST http://127.0.0.1:8000/grade \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 123,
    "transcript": "there are three: embb, urllc, and mmtc",
    "question_text": "How many SNASSI settings?",
    "reference_text": "Three: enhanced mobile broadband, ultra reliable low latency, massive machine type"
  }'

# Grade with explanation
curl -X POST http://127.0.0.1:8000/grade-with-explanation \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 123,
    "transcript": "there are three: embb, urllc, and mmtc",
    "question_text": "How many SNASSI settings?",
    "reference_text": "Three: enhanced mobile broadband, ultra reliable low latency, massive machine type"
  }'

# Submit grade (requires card in reviewer with answer shown)
curl -X POST http://127.0.0.1:8000/submit-grade \
  -H "Content-Type: application/json" \
  -d '{"cardId": 123, "ease": 3}'
```

**Use Interactive API Docs:**
- Visit `http://127.0.0.1:8000/docs` in browser
- All endpoints are documented with request/response schemas
- Can test endpoints directly from browser

### Debugging Tips

**Server Logs:**
- All server logs appear in the terminal where uvicorn is running
- `--log-level debug` provides more verbose output
- Check for Python exceptions and stack traces

**iOS Console:**
- View logs in Xcode console (bottom panel)
- Look for `#if DEBUG` print statements
- Check for Swift errors and warnings

**Network Debugging:**
- Use `curl` to test endpoints manually
- Check server URL in iOS app matches Mac's IP
- Verify iPhone and Mac are on same Wi-Fi network
- Check firewall settings on Mac (may block incoming connections)

**Audio Debugging:**
- Check microphone permissions in iPhone Settings
- Verify audio session is active (check `AVAudioSession.sharedInstance().isOtherAudioPlaying`)
- Check for audio route changes (headphones, Bluetooth, etc.)

**State Machine Debugging:**
- UI shows current state: `Text("State: \(stateDescription)")`
- Add breakpoints in state transition functions
- Check `showBackDuringProcessing` flag if answer not showing

## 🐛 Troubleshooting Guide

### Authentication Issues

**"Sign in was canceled"**:
- User canceled the Sign in with Apple dialog
- Solution: Tap "Register" again and complete the sign-in process

**"Invalid Apple sign-in token"**:
- Apple token verification failed on backend
- Solution: Try signing in again, ensure you're using a valid Apple ID

**"Not authenticated. Please sign in."**:
- JWT token is missing or expired
- Solution: Tap "Register" to sign in again, or check if token expired (7-day expiration)

**Sync credentials**:
- Check error message for specific issue:
  - "Invalid email or password format" - Verify credentials are correct
  - "Failed to provision your Anki environment" - Backend provisioning failed, check backend logs
  - "Anki environment is not ready yet" - Wait a moment and try again

**JWT Token Not Persisting**:
- Check that Keychain access is working
- Verify app has proper entitlements
- Check Xcode console for Keychain errors

**401 Unauthorized on API Calls**:
- JWT token is missing, expired, or invalid
- Solution: Log out and sign in again
- Check that `Authorization: Bearer <JWT>` header is being sent

### Common Error Messages and Solutions

**"Open Anki on your mac and start a review"**
- **Cause**: Server cannot fetch card from Anki add-on
- **Solution Steps**:
  1. Verify Anki Desktop is open
  2. Verify you're in Anki's reviewer (not deck browser)
  3. Verify a card is displayed (start a review session)
  4. Test add-on directly: `curl http://127.0.0.1:8770/current`
  5. Check server logs for connection errors
  6. Verify add-on is installed and running

**"I couldn't reach the grader. Check the server is running and the URL is correct"**
- **Cause**: Network error reaching `/grade-with-explanation` endpoint
- **Solution Steps**:
  1. Verify server is running: `curl http://127.0.0.1:8000/health`
  2. Verify server URL in iOS app matches Mac's IP address
  3. Verify iPhone and Mac are on same Wi-Fi network
  4. Check Mac firewall settings (may need to allow incoming connections)
  5. Test endpoint directly: `curl -X POST http://127.0.0.1:8000/grade-with-explanation ...`
  6. Check server logs for errors

**"The grader backend failed" (HTTP 502)**
- **Cause**: LLM API call failed
- **Solution Steps**:
  1. Check `OPENAI_API_KEY` in `.env` file
  2. Verify API key is valid and has credits
  3. Check server logs for OpenAI API errors
  4. Verify `OLLAMA_MODEL` is correct (default: `llama2:latest`)
  5. Check network connectivity from server to OpenAI

**"OPENAI_API_KEY is not set on the server" (HTTP 503)**
- **Cause**: Environment variable not loaded
- **Solution Steps**:
  1. Verify `.env` file exists in `anki-voice-server/` directory
  2. Verify `.env` file contains `OPENAI_API_KEY=sk-...`
  3. Restart the server (environment variables loaded at startup)
  4. Check server logs to confirm `.env` file is being read

**"Failed to submit grade. Make sure Anki Desktop is in review mode."**
- **Cause**: AnkiConnect error or reviewer not ready
- **Solution Steps**:
  1. Verify Anki is open and in reviewer
  2. Verify a card is displayed
  3. Verify answer is shown (tap spacebar in Anki to show answer)
  4. Test AnkiConnect: `curl -X POST http://127.0.0.1:8765 ...`
  5. Check server logs for AnkiConnect errors
  6. Verify `/submit-grade` endpoint calls `show_answer()` first

**"Microphone permission required" but no popup appears**
- **Cause**: Permission was previously denied
- **Solution Steps**:
  1. Go to iPhone Settings → AnkiVoice → Permissions
  2. Enable Microphone permission
  3. Enable Speech Recognition permission
  4. Restart the app

**Speech recognition not hearing anything**
- **Cause**: Audio session not configured correctly or microphone issue
- **Solution Steps**:
  1. Check microphone permissions are granted
  2. Verify audio session is active (check logs)
  3. Check for audio route changes (headphones, Bluetooth)
  4. Verify `AVAudioSession` is configured for `.playAndRecord` mode
  5. Test microphone with another app to rule out hardware issue
  6. Check if audio tap is installed on correct bus (input bus 0)

**"Listening..." but transcript never updates**
- **Cause**: Speech recognition not receiving audio or silently failing
- **Solution Steps**:
  1. Check `SpeechSTT.isRunning` is `true`
  2. Verify audio tap format is correct (`input.inputFormat(forBus: 0)`)
  3. Check for recognition task errors in logs
  4. Verify `SFSpeechRecognizer` is authorized
  5. Check if on-device recognition is enabled (may have issues)

**App gets stuck in a state**
- **Cause**: State transition failed or loop broken
- **Solution Steps**:
  1. Check current state in UI: `Text("State: \(stateDescription)")`
  2. Add breakpoints in state transition functions
  3. Check if `Task.isCancelled` is preventing execution
  4. Verify network calls are completing (check logs)
  5. Force-quit app and restart

**Server connection timeout**
- **Cause**: Network issue or server not responding
- **Solution Steps**:
  1. Verify server is running and accessible
  2. Test connectivity: `ping <mac-ip>` from iPhone (if possible)
  3. Check Mac firewall allows incoming connections on port 8000
  4. Verify server URL doesn't have trailing slash
  5. Try increasing timeout in iOS app (currently 30s/60s)

**Voice sounds robotic or British accent**
- **Cause**: Wrong voice selected for TTS
- **Solution Steps**:
  1. Check `normalUSVoice()` function in `ContentView.swift`
  2. Verify voice selection logic is working
  3. Check available voices: `AVSpeechSynthesisVoice.speechVoices()`
  4. Voice is selected once at initialization, may need app restart

**Grade buttons require two presses**
- **Cause**: State transition logic issue
- **Solution Steps**:
  1. Check `handleGradeButton()` function
  2. Verify state-specific behavior is correct
  3. Check if `submitGrade()` guard is preventing execution
  4. Verify state transitions are happening correctly

### Debug Commands Reference

```bash
# Check AnkiConnect
curl -X POST http://127.0.0.1:8765 \
  -H "Content-Type: application/json" \
  -d '{"action": "version", "version": 6}'

# Check Anki add-on
curl http://127.0.0.1:8770/current

# Check server health
curl http://127.0.0.1:8000/health

# Check server current card endpoint
curl http://127.0.0.1:8000/current

# Test grading endpoint
curl -X POST http://127.0.0.1:8000/grade-with-explanation \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 123,
    "transcript": "test answer",
    "question_text": "Test question?",
    "reference_text": "Test answer"
  }'

# Check Mac IP address
ifconfig | grep "inet " | grep -v 127.0.0.1

# Check if port is in use
lsof -i :8000
lsof -i :8765
lsof -i :8770

# Check Python version
python3.12 --version

# Check virtual environment
which python  # Should show .../anki-voice-server/venv/bin/python

# View server logs with debug level
cd anki-voice-server
source venv/bin/activate
uvicorn app.main:app --host 0.0.0.0 --port 8000 --log-level debug
```

## 📚 Key Technologies and Dependencies

### Python Dependencies (anki-voice-server)

**requirements.txt**:
```
fastapi==0.119.0          # Web framework
uvicorn[standard]==0.38.0  # ASGI server (with standard extras for performance)
httpx==0.28.1              # Async HTTP client
python-dotenv==1.1.1       # Environment variable loading
beautifulsoup4==4.14.2     # HTML parsing
pydantic==2.12.3           # Data validation
```

**Installation**:
```bash
cd anki-voice-server
source venv/bin/activate
pip install -r requirements.txt
```

### iOS Dependencies

**Frameworks Used** (all built-in, no external dependencies):
- `SwiftUI` - UI framework
- `Speech` - Speech recognition (`SFSpeechRecognizer`)
- `AVFoundation` - Text-to-speech (`AVSpeechSynthesizer`)
- `AVFAudio` - Audio session management (macOS/visionOS)
- `UIKit` - Settings URL opening (iOS only)

**External Frameworks**:
- `MicPermissionKit` - Custom framework wrapping deprecated APIs
  - `MicPermissionShim.h/m` - Objective-C shim
  - Suppresses deprecation warnings for `AVAudioSession` microphone APIs

### System Requirements

**Server**:
- Python 3.12 or later
- macOS, Linux, or Windows (tested on macOS)
- Network access to OpenAI API
- Local network access for iPhone connectivity

**iOS App**:
- iOS 13.0 or later (tested on iOS 17+)
- Physical iPhone device (speech recognition doesn't work in simulator)
- Microphone access
- Speech recognition permission
- Network access to server

**Anki**:
- Anki Desktop 2.1.x
- AnkiConnect add-on (code: 2055492159)
- Anki Voice Bridge add-on (not in repo, must be installed separately)

## 🔒 Security Considerations

### Authentication and Token Security

**JWT Token Storage**:
- JWT tokens are stored securely in iOS Keychain
- Uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for maximum security
- Tokens are encrypted by iOS and only accessible when device is unlocked
- Tokens are device-bound (not synced via iCloud Keychain)

**Sign in with Apple**:
- Uses Apple's secure authentication flow
- Identity tokens are never stored (only used once for registration)
- Only the app's JWT token is stored after successful authentication

**API Authentication**:
- All API requests include `Authorization: Bearer <JWT>` header
- JWT tokens expire after 7 days
- Backend API verifies JWT signature using RS256 public key
- Invalid or expired tokens result in 401 Unauthorized responses

**Sync Credentials** (Auto-Generated):
- Credentials are encrypted using libsodium sealed box encryption
- Only ciphertext is stored in database
- Plaintext credentials are never logged or stored insecurely
- Decryption only happens server-side when needed

### API Key Protection

**DO**:
- Store `OPENAI_API_KEY` in `.env` file (gitignored)
- Never commit `.env` file to git
- Use environment variables, not hardcoded keys
- Restrict API key permissions in OpenAI dashboard

**DON'T**:
- Commit API keys to git
- Hardcode API keys in source code
- Share API keys in chat or email
- Use production keys in development

### Network Security

**Current Configuration**:
- Server binds to `0.0.0.0:8000` (all interfaces) for iPhone access
- CORS allows all origins (`allow_origins=["*"]`)
- AnkiConnect only accessible on `127.0.0.1:8765` (localhost)
- Anki add-on only accessible on `127.0.0.1:8770` (localhost)

**Security Recommendations**:
- Use firewall to restrict port 8000 to local network only
- Consider restricting CORS to specific IP ranges in production
- Never expose AnkiConnect or add-on to internet
- Use VPN for remote access if needed

### App Transport Security (iOS)

**Current Configuration**:
- `NSAllowsLocalNetworking = true` - Allows HTTP to local network
- Exceptions for `localhost` and `127.0.0.1` - Allows insecure HTTP
- No HTTPS required for local development

**For Production**:
- Consider using HTTPS with self-signed certificates for local network
- Or use mDNS/Bonjour for service discovery

## 🤝 Contributing Guidelines

### Code Style

**Python**:
- Follow PEP 8 style guide
- Use type hints for function parameters and returns
- Use `async`/`await` for all I/O operations
- Use f-strings for string formatting
- Maximum line length: 100 characters (relaxed from 80)

**Swift**:
- Follow Apple's Swift style guide
- Use `@MainActor` for UI updates
- Use `async`/`await` for async operations
- Use `Task` for concurrent work
- Prefer `let` over `var` when possible
- Use computed properties for derived values

### File Organization

**Python Files**:
- One class/function per logical unit
- Group related functions together
- Use module-level docstrings
- Import order: stdlib, third-party, local

**Swift Files**:
- Group related code with `// MARK:` comments
- Place `@State` and `@StateObject` properties together
- Place computed properties after stored properties
- Place functions in logical order (UI, network, helpers)

### Documentation

**When to Update FOR_DEV.md**:
- Adding new API endpoints
- Changing state machine structure
- Adding new dependencies
- Changing environment variables
- Modifying architecture significantly

**Code Comments**:
- Explain "why", not "what" (code should be self-documenting)
- Document complex algorithms
- Explain non-obvious workarounds
- Add TODO comments for known issues

### Testing

**Before Submitting Changes**:
1. Test server endpoints with `curl`
2. Test iOS app on physical device
3. Verify permissions work correctly
4. Test error cases (network failures, missing data, etc.)
5. Check for linter errors

**Test Checklist**:
- [ ] Server starts without errors
- [ ] All API endpoints respond correctly
- [ ] iOS app connects to server (or authenticates with production API)
- [ ] User can register with Sign in with Apple
- [ ] JWT token is stored in Keychain
- [ ] Sync credentials are auto-generated on registration
- [ ] All API calls include Authorization header
- [ ] Speech recognition captures audio
- [ ] TTS speaks clearly
- [ ] Grading works (both rule-based and LLM)
- [ ] Grade submission works
- [ ] Undo works
- [ ] Questions work
- [ ] Error handling provides clear feedback

## 📖 Additional Resources

### Official Documentation

- [AnkiConnect Documentation](https://github.com/amikey/anki-connect) - Complete API reference
- [Anki Add-ons Guide](https://addon-docs.ankiweb.net/) - How to write Anki add-ons
- [Apple Speech Framework](https://developer.apple.com/documentation/speech) - Speech recognition API
- [Apple AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer) - Text-to-speech API
- [Ollama Documentation](https://github.com/ollama/ollama) - LLM API reference
- [FastAPI Documentation](https://fastapi.tiangolo.com/) - Web framework docs

### Project-Specific Files

- `README.md` - User-facing documentation
- `anki-voice-server/README.md` - Server-specific docs
- `anki-voice-ios/README.md` - iOS-specific docs
- This file (`FOR_DEV.md`) - Comprehensive developer guide

---

## 🎛️ Input Language Selection

The app supports selecting the **input language** for speech recognition on the home page. When you choose Spanish, both speech recognition and all voice commands use Spanish.

**Location**: Home page, below the Sync button (dropdown labeled "Input language")

**Options**:
- **English** (`en-US`) - Default; speech recognition and commands in English
- **Spanish** (`es-ES`) - Speech recognition and commands in Spanish

**How it works**:
- **Speech recognition**: `SFSpeechRecognizer` uses the selected locale to transcribe your spoken answers
- **Voice commands**: All command phrases (grades, "read answer", "undo", etc.) are matched in the selected language
- **TTS prompts**: Feedback prompts ("Marked good. Say 'undo' to change it") are spoken in the selected language
- **Persistence**: Selection is stored in `UserDefaults` via `@AppStorage("inputLanguage")`

**Implementation**:
- `VoiceCommands.swift` - Centralized phrase sets and TTS prompts per language
- `IntentParser.swift` - Accepts `localeIdentifier`; uses Spanish grade words, verbs, and question starters when `es-ES`
- `SpeechSTT` - `inputLocaleIdentifier` property; recognizer created with selected locale

**Spanish command examples**:
- Grades: `"bien"`, `"bueno"`, `"difícil"`, `"fácil"`, `"otra vez"`, `"calificar 3"`, `"marcar bien"`
- Read answer: `"lee la respuesta"`, `"dime la respuesta"`
- Undo: `"deshacer"`, `"cambiar"`
- I don't know: `"no sé"`, `"no tengo idea"`
- Delete note: `"eliminar nota"`, `"borrar tarjeta"`

---

## 🎤 Complete Voice Commands Reference

### Commands During Answer Phase

These commands work while you're providing your answer or after you've finished speaking:

#### Reread Question
- `"reread question"`, `"reread the question"`, `"say the question again"`, `"read question again"`, `"repeat question"`, `"repeat the question"`
- **Implementation**: `handleRereadQuestion()` in `ContentView.swift`
- **Behavior**: Repeats the question without changing state, stays in `.awaitingAnswer`

#### Reread Answer
- `"reread answer"`, `"reread the answer"`, `"say the answer again"`, `"read answer again"`
- **Implementation**: `handleRereadAnswer()` in `ContentView.swift`
- **Behavior**: Reads the answer while still in answer phase (before grading)

#### Read Answer (Skip Grading)
- `"read answer"`, `"read the answer"`, `"show answer"`, `"tell me the answer"`
- **Implementation**: `handleReadAnswer()` in `ContentView.swift`
- **Behavior**: Skips LLM grading, reads answer, moves to action phase

#### I Don't Know
- `"i don't know"`, `"i have no idea"`, `"i'm not sure"`, `"no idea"`, `"don't know"`, `"i dunno"`
- **Implementation**: Detected in `listenForAnswerContinuous()` in `ContentView.swift`
- **Behavior**: Skips LLM, immediately shows and reads answer, moves to action phase

#### Delete Note (Suspend Card)
- `"delete note"`, `"delete the note"`, `"remove note"`, `"remove the note"`, `"delete this note"`, `"delete card"`, `"delete the card"`
- **Implementation**: `listenForDeleteConfirmation()` and `/delete-note` endpoint
- **Behavior**: Asks for confirmation, then suspends card (preserves note), advances to next card

#### Undo Last Grade
- `"undo"`, `"change"`, `"take back"`, `"undo that"`, `"change that"`
- **Implementation**: `undoLastGrade()` in `ContentView.swift`, calls `/undo` endpoint
- **Behavior**: Undoes last grade, returns to previous card

#### Immediate Grade Commands
- Unambiguous grade commands (see Grade Commands section) can be used during answer phase
- **Implementation**: Detected in `listenForAnswerContinuous()` via `IntentParser.parse()`
- **Behavior**: Skips LLM, immediately submits grade, advances to next card

### Commands During Action Phase

After the explanation is read, you can use these commands:

#### Grade Commands
- **Unambiguous**: `"good"`, `"grade 3"`, `"mark one"`, `"hard"`, `"easy"`, etc.
- **Ambiguous**: `"that was good"`, `"pretty easy"`, `"kind of hard"` (requires confirmation)
- **Implementation**: `IntentParser.parse()` in `IntentParser.swift`, handled in `listenForAction()`
- **Behavior**: Unambiguous grades submit immediately, ambiguous grades require confirmation

#### Question Commands
- Any sentence starting with question words (what, why, how, when, where, who, which)
- Phrases containing: `"explain"`, `"clarify"`, `"tell me"`, `"give me"`, `"help me"`, `"don't understand"`, `"not clear"`
- **Implementation**: `IntentParser.parse()` detects questions, handled in `listenForAction()`
- **Behavior**: Sends to `/ask` endpoint, speaks LLM's answer

#### Read Answer (During Action Phase)
- `"read answer"`, `"read the answer"`, `"show answer"`, `"tell me the answer"`
- **Implementation**: `handleReadAnswer()` in `ContentView.swift`
- **Behavior**: Reads the answer text again

#### Undo Commands (During Action Phase)
- `"undo"`, `"change"`, `"take back"`
- **Implementation**: `undoLastGrade()` in `ContentView.swift`
- **Behavior**: Undoes last grade, returns to previous card

### Grade Command Details

**Ease 1 (Again)**:
- Words: `"again"`, `"wrong"`, `"repeat"`, `"fail"`, `"failed"`, `"miss"`, `"missed"`, `"red"`
- Numbers: `"grade 1"`, `"mark one"`, `"mark it 1"`, `"set to 1"`

**Ease 2 (Hard)**:
- Words: `"hard"`, `"difficult"`, `"struggled"`
- Numbers: `"grade 2"`, `"mark two"`, `"mark it 2"`

**Ease 3 (Good)**:
- Words: `"good"`, `"ok"`, `"okay"`, `"decent"`, `"solid"`, `"correct"`
- Numbers: `"grade 3"`, `"mark three"`, `"mark it 3"`

**Ease 4 (Easy)**:
- Words: `"easy"`, `"trivial"`, `"simple"`
- Numbers: `"grade 4"`, `"mark four"`, `"mark it 4"`

**Unambiguous Detection**:
- Explicit numerals: `"grade 3"`, `"mark 2"` → always unambiguous
- Number words with verbs: `"grade three"`, `"mark two"` → unambiguous
- Bare grade words: `"good"`, `"hard"` → unambiguous if single word or with verb
- Ambiguous phrases: `"that was good"`, `"pretty easy"` → requires confirmation

**Spanish equivalents** (when Input Language is Spanish):
- Ease 1: `"otra vez"`, `"repetir"`, `"mal"`, `"equivocado"`; `"calificar 1"`, `"marcar uno"`
- Ease 2: `"difícil"`, `"duro"`; `"calificar 2"`, `"marcar dos"`
- Ease 3: `"bien"`, `"bueno"`, `"correcto"`; `"calificar 3"`, `"marcar tres"`
- Ease 4: `"fácil"`, `"simple"`; `"calificar 4"`, `"marcar cuatro"`

## 🌍 Multilingual TTS Implementation

### README Div Extraction

The app uses a special HTML structure to control what gets read by TTS:

- **Display**: Shows the entire card (all HTML content converted to text)
- **TTS**: Only reads content inside `<div>` elements with the `README` class

### Language Detection

Language is determined by the `lang` attribute in README divs:

```html
<div class="README" lang="es-ES">Spanish text</div>
<div class="english README" lang="en-US">English text</div>
```

**Language Priority**:
1. Innermost `lang` attribute within README div (most specific/nested)
2. Deck-level configuration (from `_ankiVoice.deck.<deck>.json` in Anki media folder)
3. Note-level tags (e.g., `av:front=es-ES`, `av:back=en-US`)
4. Default: `en-US` (English)

### Implementation Details

**Server Side** (`app/main.py`):
- `get_deck_language_config()`: Reads deck config from Anki media folder
- `extract_lang_from_tags()`: Extracts language from note tags
- `get_language_hints()`: Combines deck config and note tags
- `/current` endpoint returns `front_language` and `back_language` hints

**HTML Processing** (`app/normalize.py`):
- `html_to_text_readme_only()`: Extracts text from README divs only
- Finds innermost `lang` attribute (most deeply nested element with lang)
- Excludes README divs inside `.from-front` containers (prevents reading front content on back card)

**iOS Side** (`ContentView.swift`):
- `SpeechTTS.speak()` and `speakAndWait()` accept optional `language` parameter
- Uses `AVSpeechSynthesisVoice(language:)` to select appropriate voice
- All TTS calls pass `current?.front_language` or `current?.back_language`

## 🎛️ UI Controls and Buttons

### Authentication UI

**Top Bar (Always Visible)**:
- **Register Button** (when not authenticated):
  - Location: Top-left corner
  - Action: Triggers Sign in with Apple
  - Shows loading spinner during authentication
  - Displays error messages if authentication fails

- **Logout Button** (when authenticated):
  - Location: Top-left corner
  - Action: Clears JWT token from Keychain and logs out
  - Returns app to unauthenticated state

- **Microphone Mute Button**:
  - Location: Top-right corner
  - Toggles microphone on/off
  - Visual indicator when muted (red slash icon)

**Authentication Status**:
- "Signed in" (green text) - User is authenticated
- "Not signed in" (orange text) - User needs to register

**Sync Credentials**:
- Automatically generated when user registers/logs in
- User can view credentials at `https://api.grantcurell.com/anki/sync-setup`
- No UI needed in app - credentials are managed server-side

### Home Screen (Idle State)

- **Server URL Text Field**: Enter Mac's IP address (e.g., `http://192.168.1.50:8000`) - **Only shown in development mode when not authenticated**
- **Input Language Dropdown**: Select English or Spanish for speech recognition and voice commands (below Sync button)
- **Authorize Speech & Mic Button**: Requests permissions (only shown if not granted)
- **Open Settings Button**: Opens iPhone Settings (shown if permissions denied)
- **Deck Selection Dropdown**: Select which deck to review (loads via `/decks` endpoint)
- **Deck Statistics Display**: Shows "New: X Review: Y" below selected deck (fetched via `/anki/deck-stats` or `/deck-stats`)
- **Start Review Button**: Begins review session (changes to "Return to deck selection" during review)
- **Sync Button**: Synchronizes Anki with self-hosted sync server (only shown when idle)

### During Review

- **Mute Button**: Mutes/unmutes microphone (top-right corner)
- **Read Answer Button**: Skips LLM grading, reads answer
- **Grade Buttons**: Again/Hard/Good/Easy (state-dependent behavior)
- **"Say 'undo' to change the last grade" Hint**: Reminder text below grade buttons

### Button Behaviors

**Grade Buttons**:
- **During question reading**: Skips to answer phase
- **During answer phase**: Immediately submits grade (skips LLM)
- **During explanation**: Stops TTS, immediately submits grade
- **During action phase**: Immediately submits grade
- **During confirmation**: Confirms pending grade

**Start Review / Return to Deck Selection**:
- **Start Review**: Fetches card, speaks question, begins listening
- **Return to Deck Selection**: Stops I/O, resets to idle state

---

## Recent Bug Fixes and Improvements

### iOS App Debug Logging (November 2024)

**Problem**: When the app failed to retrieve cards, there was insufficient logging to diagnose the issue. The app would show "Open Anki on your Mac and start a review" without providing details about what went wrong.

**Fix**: Added comprehensive debug logging to `ContentView.swift`:
- Logs HTTP status codes and response body (truncated to 1000 chars) for `/current` requests
- Logs JSON decoding results with detailed field information
- Logs card validation failures with specific reasons (missing fields, empty text, etc.)
- All debug logs prefixed with `[CURRENT_CARD]` or `[START_REVIEW]` for easy filtering

**Files Changed**:
- `anki-voice-ios/AnkiVoice/AnkiVoice/ContentView.swift`: Added extensive debug logging in `fetchCurrentCard()` and `startReview()` functions

**Note**: Debug logging is only enabled in DEBUG builds (wrapped in `#if DEBUG` blocks), so it won't affect production performance.

### Gateway Response Parsing Fix (November 2024)

**Problem**: The gateway was incorrectly parsing AnkiConnect responses, causing the app to receive "Backend returned: unknown" errors even when cards were available.

**Root Cause**: AnkiConnect returns responses in the format `{"result": {...}, "error": null}`, but the gateway was checking `result.get("status")` on the top-level dict instead of extracting the nested `result` field first.

**Fix**: The gateway was updated to correctly extract the `result` field from AnkiConnect responses before checking status. This fix is in the `anki-voice-deployer` repository.

**Impact**: The iOS app now correctly receives card data when cards are available, eliminating false "no cards available" errors.

### Input Language and Spanish Voice Commands (February 2025)

**Feature**: Added user-selectable input language (English/Spanish) for speech recognition and voice commands.

**What was added**:
1. **Input language dropdown** on home page (below Sync button)
   - Chooses speech recognition locale (`en-US` or `es-ES`)
   - Persisted via `@AppStorage("inputLanguage")`

2. **VoiceCommands.swift** - New file with language-aware phrase sets:
   - Command phrases: reread question/answer, read answer, delete note, I don't know, undo, example
   - Confirm/cancel phrases for confirmation flows
   - TTS prompts: undo prompt, delete confirm, grade confirm, "didn't get that", cancelled, note deleted

3. **IntentParser** - Spanish support:
   - `parse(_ raw: String, localeIdentifier: String)` overload
   - Spanish grade words (bien, bueno, difícil, fácil, otra vez)
   - Spanish grade verbs (calificar, marcar, poner, dar)
   - Spanish number words (uno, dos, tres, cuatro)
   - Spanish question starters (qué, por qué, cómo, explicar, etc.)

4. **SpeechSTT** - Dynamic locale:
   - `@Published var inputLocaleIdentifier`
   - Recognizer created with selected locale (computed property)

5. **ContentView** - All phrase matching and TTS prompts use `VoiceCommandPhrases.xxx(locale: inputLanguage)`
   - `listenForAnswerContinuous`, `listenForAction` use language-aware phrases
   - `listenForConfirmation`, `listenForDeleteConfirmation` use confirm/cancel phrases
   - Grade feedback, undo prompt, etc. use `VoiceCommandPhrases`

**Files Changed**:
- `anki-voice-ios/AnkiVoice/AnkiVoice/ContentView.swift` - Input language UI, phrase lookups, TTS prompts
- `anki-voice-ios/AnkiVoice/AnkiVoice/IntentParser.swift` - Locale-aware parse, Spanish dictionaries
- `anki-voice-ios/AnkiVoice/AnkiVoice/VoiceCommands.swift` - New file

---

**Last Updated**: 2025-02-08

**Remember**: This system preserves Anki's sophisticated scheduling algorithm while adding voice interaction. The core learning benefits remain unchanged - we're just changing the interface from visual/manual to voice-driven.
