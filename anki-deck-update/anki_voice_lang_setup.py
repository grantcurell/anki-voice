#!/usr/bin/env python3

"""
Anki Voice – deck language setup

- Writes a deck-level language config JSON to Anki's media folder (filename starts with "_"
  so Anki won't purge it). The iOS app / your bridge add-on can read this to pick TTS voices.
- Optionally bulk-adds/removes av:* tags on notes in the deck.

Examples
  python anki_voice_lang_setup.py --deck "Spanish 1" --front-lang es-ES --back-lang en-US
  python anki_voice_lang_setup.py --deck "Spanish 1" --front-lang es-ES --back-lang en-GB --tag-notes
  python anki_voice_lang_setup.py --deck "Spanish 1" --remove-note-tags
  python anki_voice_lang_setup.py --deck "Spanish 1" --front-lang es-ES --back-lang en-US --dry-run
"""

import argparse
import base64
import json
import re
import sys
from typing import Any, Dict, Optional

import urllib.request


ANKICONNECT_URL = "http://127.0.0.1:8765"
API_VERSION = 6  # works with 5/6; 6 is fine


def ac(action: str, params: Optional[Dict[str, Any]] = None) -> Any:
    """Call AnkiConnect and return `result` (raises on error)."""
    payload = {"action": action, "version": API_VERSION}
    if params:
        payload["params"] = params
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(ANKICONNECT_URL, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as resp:
            jr = json.loads(resp.read().decode("utf-8"))
    except Exception as e:
        raise RuntimeError(f"Failed to reach AnkiConnect at {ANKICONNECT_URL}: {e}")
    if jr.get("error"):
        raise RuntimeError(f"AnkiConnect error from '{action}': {jr['error']}")
    return jr.get("result")


def sanitize_for_filename(deck_name: str) -> str:
    # Produce a safe filename suffix based on the deck name.
    return re.sub(r"[^A-Za-z0-9._-]+", "_", deck_name.strip())


def ensure_deck_exists(deck_name: str) -> None:
    decks = set(ac("deckNames"))
    if deck_name not in decks:
        # Try exact path-style name with spaces normalized?
        raise SystemExit(f"Deck '{deck_name}' not found. Known decks: {sorted(decks)}")


def write_deck_config_media(deck_name: str, front_lang: str, back_lang: str, dry_run: bool = False) -> str:
    """Write _ankiVoice.deck.<sanitized>.json to media with front/back languages."""
    cfg = {"frontLang": front_lang, "backLang": back_lang}
    contents = json.dumps(cfg, ensure_ascii=False, indent=2)
    fname = f"_ankiVoice.deck.{sanitize_for_filename(deck_name)}.json"
    if dry_run:
        print(f"[dry-run] Would storeMediaFile: {fname}\n{contents}")
        return fname
    # storeMediaFile expects base64-encoded "data"
    ac("storeMediaFile", {
        "filename": fname,
        "data": base64.b64encode(contents.encode("utf-8")).decode("ascii")
    })
    return fname


def find_notes_in_deck(deck_name: str) -> list[int]:
    # Same query syntax as Anki's browser. Example: deck:"Spanish 1"
    return ac("findNotes", {"query": f'deck:"{deck_name}"'})


def add_lang_tags_to_notes(note_ids: list[int], front_lang: str, back_lang: str, dry_run: bool = False) -> None:
    if not note_ids:
        print("No notes found; skipping tag add.")
        return
    tags = f"av:front={front_lang} av:back={back_lang}"
    if dry_run:
        print(f"[dry-run] Would addTags to {len(note_ids)} notes: {tags}")
        return
    ac("addTags", {"notes": note_ids, "tags": tags})


def remove_lang_tags_from_notes(note_ids: list[int], dry_run: bool = False) -> None:
    if not note_ids:
        print("No notes found; skipping tag removal.")
        return
    # Remove both keys regardless of value
    # (Anki tags are whole tokens; remove matches via search filter)
    # We'll compute matching notes via a query to be precise:
    #   tag:av:front=* OR tag:av:back=*
    # But for simplicity, just run removeTags on the deck's notes; removing a tag that isn't present is harmless.
    tags_to_remove = " ".join(["av:front=es", "av:front=en", "av:front=*", "av:back=es", "av:back=en", "av:back=*"])
    # AnkiConnect doesn't support wildcards in removeTags; provide concrete prefixes.
    # Use two broad tokens to catch typical usage:
    #   av:front=  av:back=
    # (Tags are exact tokens; removing a token that doesn't exist is a no-op.)
    tags_to_remove = "av:front= av:back="
    if dry_run:
        print(f"[dry-run] Would removeTags from {len(note_ids)} notes: {tags_to_remove}")
        return
    ac("removeTags", {"notes": note_ids, "tags": tags_to_remove})


def main():
    p = argparse.ArgumentParser(description="Set deck-level language defaults (and optional note tags) for Anki Voice.")
    p.add_argument("--deck", required=True, help="Deck name (exact as shown in Anki, e.g., 'Spanish 1')")
    p.add_argument("--front-lang", help="BCP-47 language tag for front (e.g., es-MX)", default=None)
    p.add_argument("--back-lang", help="BCP-47 language tag for back (e.g., en-US)", default=None)
    p.add_argument("--tag-notes", action="store_true", help="Also add av:front=/av:back= tags to all notes in the deck")
    p.add_argument("--remove-note-tags", action="store_true", help="Remove av:front=/av:back= tags from all notes in the deck")
    p.add_argument("--dry-run", action="store_true", help="Print what would change without applying")
    args = p.parse_args()

    if not args.front_lang or not args.back_lang:
        if not args.remove_note_tags:
            p.error("--front-lang and --back-lang are required unless --remove-note-tags is given.")

    # 0) connectivity check (cheap)
    try:
        ver = ac("version")
        print(f"Connected to AnkiConnect (version={ver}).")
    except Exception as e:
        raise SystemExit(str(e))

    # 1) sanity: deck exists
    ensure_deck_exists(args.deck)

    # 2) write deck config to media (unless we're only removing tags)
    if not args.remove_note_tags:
        fname = write_deck_config_media(args.deck, args.front_lang, args.back_lang, args.dry_run)
        print(f"{'[dry-run] ' if args.dry_run else ''}Wrote deck config media: {fname}")

    # 3) note tagging operations
    note_ids = find_notes_in_deck(args.deck)
    print(f"Deck '{args.deck}': {len(note_ids)} notes.")

    if args.tag_notes and not args.remove_note_tags:
        add_lang_tags_to_notes(note_ids, args.front_lang, args.back_lang, args.dry_run)
        print(f"{'[dry-run] ' if args.dry_run else ''}Tagged notes with av:front={args.front_lang} av:back={args.back_lang}")

    if args.remove_note_tags:
        remove_lang_tags_from_notes(note_ids, args.dry_run)
        print(f"{'[dry-run] ' if args.dry_run else ''}Removed av:front=/av:back= tags from notes.")

    print("Done.")


if __name__ == "__main__":
    main()

