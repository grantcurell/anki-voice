# Anki Voice iOS App

SwiftUI iOS app that provides hands-free Anki card review using speech recognition and text-to-speech.

## Features

- Speech-to-text for answering cards
- Text-to-speech for reading card fronts
- Automatic grading using the voice server
- Manual ease selection (Again/Hard/Good/Easy)
- Configurable server URL

## Setup

1. Open the project in Xcode
2. Add "Speech Recognition" capability in project settings
3. Add to Info.plist:
```xml
<key>NSSpeechRecognitionUsageDescription</key>
<string>This app uses speech recognition to capture your spoken answers to flashcards.</string>
```

4. Build and run on device (speech recognition requires physical device)

## Usage

1. Set the server URL to your desktop's IP address (e.g., `http://192.168.1.50:8000`)
2. Tap "Authorize STT" to grant speech recognition permission
3. Tap "Start Review" to begin a review session
4. The app will:
   - Fetch the current card from Anki
   - Speak the card front
   - Listen for your answer
   - Grade your response
   - Announce the verdict and suggested ease
   - Allow you to select the final ease rating

## Requirements

- iOS 13.0+
- Physical device (speech recognition doesn't work in simulator)
- Anki Voice Server running on desktop
- Anki with AnkiConnect and Voice Bridge add-ons

## Architecture

The app communicates with the FastAPI server which:
- Fetches current card data from the Anki add-on
- Grades spoken answers using rule-based matching and GPT-5
- Sends review results back to Anki via AnkiConnect

## Troubleshooting

- Make sure your iPhone and desktop are on the same network
- Check that the server URL is correct and accessible
- Ensure Anki is open with a card ready for review
- Grant microphone permissions when prompted

