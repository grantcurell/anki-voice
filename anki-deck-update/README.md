# Anki Voice Language Setup

This script helps you configure language settings for Anki Voice decks, enabling proper multilingual text-to-speech support.

## Overview

The script:
- Writes a deck-level language config JSON to Anki's media folder (persists and syncs)
- Optionally bulk-tags all notes in the deck with `av:front=...` / `av:back=...` overrides
- Supports dry-run and rollback

## Requirements

- Python 3.6+
- Anki Desktop running with AnkiConnect add-on installed
- AnkiConnect accessible at `http://127.0.0.1:8765`

## Usage

### Basic Setup

Set language defaults for a deck:

```bash
python anki_voice_lang_setup.py --deck "Spanish 1" --front-lang es-ES --back-lang en-US
```

### With Note Tagging

Also tag all notes in the deck with language overrides:

```bash
python anki_voice_lang_setup.py --deck "Spanish 1" --front-lang es-ES --back-lang en-US --tag-notes
```

### Remove Tags

Remove language tags from all notes in a deck:

```bash
python anki_voice_lang_setup.py --deck "Spanish 1" --remove-note-tags
```

### Dry Run

See what would change without applying:

```bash
python anki_voice_lang_setup.py --deck "Spanish 1" --front-lang es-MX --back-lang en-US --dry-run
```

## How It Works

1. **Connects to Anki** via AnkiConnect API
2. **Validates the deck** exists
3. **Writes deck config** to media file: `_ankiVoice.deck.<sanitized-deck-name>.json`
4. **Optionally tags notes** with `av:front=<lang>` and `av:back=<lang>` tags
5. **Supports rollback** via `--remove-note-tags`

## Language Codes

Use BCP-47 language tags, for example:
- `es-ES` - Spanish (Spain / Castilian) - **Recommended for Spanish decks**
- `es-MX` - Spanish (Mexico)
- `en-US` - English (United States)
- `en-GB` - English (United Kingdom)
- `fr-FR` - French (France)
- `de-DE` - German (Germany)

## Files Created

The script creates a JSON file in Anki's media folder:
- Filename: `_ankiVoice.deck.<sanitized-deck-name>.json`
- Format:
  ```json
  {
    "frontLang": "es-ES",
    "backLang": "en-US"
  }
  ```

The leading underscore prevents Anki from purging the file even if no notes reference it.

## Integration

Your Bridge add-on or iOS app should:
1. Read the deck config file from Anki's media folder
2. Use the language hints when calling TTS
3. Respect per-note tag overrides (e.g., `av:front=es-ES`) if present

## Examples

### Spanish Deck (Castilian Spanish, US English)

```bash
python anki_voice_lang_setup.py --deck "Spanish 1" --front-lang es-ES --back-lang en-US --tag-notes
```

### French Deck (France French, US English)

```bash
python anki_voice_lang_setup.py --deck "French Basics" --front-lang fr-FR --back-lang en-US
```

### Update Existing Config

Just run the script again with new values - it overwrites the same media file:

```bash
python anki_voice_lang_setup.py --deck "Spanish 1" --front-lang es-ES --back-lang en-GB
```

