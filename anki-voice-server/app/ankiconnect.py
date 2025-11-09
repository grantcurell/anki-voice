# app/ankiconnect.py
import base64
import httpx
from typing import List

AC = "http://127.0.0.1:8765"

async def ac_call(action, params=None, version=6):
    payload = {"action": action, "version": version}
    if params:
        payload["params"] = params
    
    # Standardize timeouts: shorter for addon (2s), longer for ankiconnect (4s)
    timeout_seconds = 4.0 if action.startswith("gui") else 2.0
    
    try:
        async with httpx.AsyncClient(timeout=timeout_seconds) as x:
            r = await x.post(AC, json=payload)
            r.raise_for_status()
            return r.json()
    except httpx.ConnectError:
        raise Exception("Cannot connect to AnkiConnect. Make sure Anki is running and AnkiConnect add-on is installed.")
    except httpx.TimeoutException:
        raise Exception("AnkiConnect timeout. Anki may be busy or not responding.")
    except httpx.HTTPStatusError as e:
        raise Exception(f"AnkiConnect error: {e.response.status_code} - {e.response.text}")
    except Exception as e:
        raise Exception(f"AnkiConnect error: {str(e)}")

async def show_answer():
    try:
        return await ac_call("guiShowAnswer")
    except Exception as e:
        return {"error": str(e)}

async def answer_card(ease:int):
    # ease: 1=Again, 2=Hard, 3=Good, 4=Easy
    try:
        return await ac_call("guiAnswerCard", {"ease": ease})
    except Exception as e:
        return {"error": str(e)}

async def undo_review():
    try:
        return await ac_call("guiUndoReview")
    except Exception as e:
        return {"error": str(e)}

async def close_reviewer():
    """Close the reviewer window to prevent crashes when deleting notes"""
    try:
        # guiDeckOverview closes the reviewer and shows deck overview
        return await ac_call("guiDeckOverview")
    except Exception as e:
        return {"error": str(e)}

async def get_note_id(card_id: int):
    """Get the note ID for a given card ID"""
    try:
        result = await ac_call("cardsInfo", {"cards": [card_id]})
        if isinstance(result, dict) and result.get("error") is None:
            cards = result.get("result", [])
            if cards and len(cards) > 0:
                return cards[0].get("note")
        return None
    except Exception as e:
        return None

async def delete_note(note_id: int):
    """Delete a note by note ID"""
    try:
        return await ac_call("deleteNotes", {"notes": [note_id]})
    except Exception as e:
        return {"error": str(e)}

async def suspend_cards(card_ids: List[int]):
    """Suspend cards (they won't appear in reviews but aren't deleted)"""
    try:
        return await ac_call("suspend", {"cards": card_ids})
    except Exception as e:
        return {"error": str(e)}

async def get_card_info(card_id: int):
    """Get card information including deck name"""
    try:
        result = await ac_call("cardsInfo", {"cards": [card_id]})
        if isinstance(result, dict) and result.get("error") is None:
            cards = result.get("result", [])
            if cards and len(cards) > 0:
                return cards[0]
        return None
    except Exception as e:
        return None

async def get_note_info(note_id: int):
    """Get note information including tags"""
    try:
        result = await ac_call("notesInfo", {"notes": [note_id]})
        if isinstance(result, dict) and result.get("error") is None:
            notes = result.get("result", [])
            if notes and len(notes) > 0:
                return notes[0]
        return None
    except Exception as e:
        return None

async def retrieve_media_file(filename: str):
    """Retrieve a media file from Anki's media folder"""
    try:
        result = await ac_call("retrieveMediaFile", {"filename": filename})
        if isinstance(result, dict) and result.get("error") is None:
            # result is base64-encoded data
            data = result.get("result", "")
            if data:
                return base64.b64decode(data).decode("utf-8")
        return None
    except Exception as e:
        return None
