# Anki Voice Bridge Add-on

This is a minimal Anki add-on that exposes the current reviewer card's rendered front/back via a local HTTP endpoint.

## Installation

1. Copy the `anki-voice-bridge` folder to your Anki add-ons directory:
   - macOS: `~/Library/Application Support/Anki2/addons21/anki_voice_bridge/`
   - Windows: `%APPDATA%\Anki2\addons21\anki_voice_bridge\`
   - Linux: `~/.local/share/Anki2/addons21/anki_voice_bridge/`

2. Restart Anki

3. The add-on will automatically start a server on `127.0.0.1:8770` when Anki loads

## Usage

While reviewing cards in Anki, you can access the current card data at:
- `GET http://127.0.0.1:8770/current`

This returns JSON with:
- `status`: "ok" if a card is shown, "idle" if no card
- `cardId`: Anki card ID
- `noteId`: Anki note ID  
- `deckId`: Anki deck ID
- `front_html`: Rendered HTML of the card front
- `back_html`: Rendered HTML of the card back

## Requirements

- Anki 2.1.x
- AnkiConnect add-on (for the main voice system to work)

## Troubleshooting

- If `/current` returns `{"status": "idle"}`, make sure you're in the reviewer (not deck browser or other screens)
- The server only listens on localhost (127.0.0.1) for security
- Port 8770 must be available (not used by other applications)

