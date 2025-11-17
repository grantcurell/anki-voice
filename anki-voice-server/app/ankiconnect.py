# app/ankiconnect.py
import base64
import httpx
from typing import List

AC = "http://127.0.0.1:8765"

async def ac_call_raw(action, params=None, version=6):
    """Low-level helper: returns raw AnkiConnect JSON response {"result": ..., "error": ...}"""
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

async def ac_call_checked(action, params=None, version=6):
    """High-level helper: returns the result value, handling both dict and list responses"""
    data = await ac_call_raw(action, params=params, version=version)
    
    # Handle "we actually got a list directly" just in case
    if isinstance(data, list):
        return data
    
    if not isinstance(data, dict):
        raise Exception(f"Unexpected AnkiConnect response type for {action}: {type(data)} - {data!r}")
    
    err = data.get("error")
    if err:
        raise Exception(f"AnkiConnect error on {action}: {err}")
    
    return data.get("result")

# Keep ac_call as alias for backward compatibility (but prefer ac_call_checked for new code)
async def ac_call(action, params=None, version=6):
    """Legacy alias - returns raw response. Use ac_call_checked() for new code."""
    return await ac_call_raw(action, params=params, version=version)

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

async def get_deck_names():
    """Get list of all deck names"""
    try:
        result = await ac_call("deckNames")
        if isinstance(result, dict):
            if result.get("error"):
                raise Exception(result["error"])
            return result.get("result", [])
        return []
    except Exception as e:
        raise Exception(f"Failed to get deck names: {str(e)}")

async def gui_deck_review(deck_name: str):
    """Open the reviewer for a specific deck"""
    try:
        result = await ac_call("guiDeckReview", {"name": deck_name})
        if isinstance(result, dict):
            if result.get("error"):
                raise Exception(result["error"])
            return result.get("result")
        return None
    except Exception as e:
        raise Exception(f"Failed to open deck reviewer: {str(e)}")

async def gui_current_card():
    """Get current card from headless backend (replaces bridge add-on)"""
    try:
        return await ac_call("guiCurrentCard")
    except Exception as e:
        return {"error": str(e)}

async def sync():
    """Synchronize the local Anki collection with AnkiWeb"""
    try:
        # Sync can take a while, so use a longer timeout
        payload = {"action": "sync", "version": 6}
        timeout_seconds = 120.0  # 2 minutes for sync
        
        async with httpx.AsyncClient(timeout=timeout_seconds) as x:
            r = await x.post(AC, json=payload)
            r.raise_for_status()
            result = r.json()
            
        if isinstance(result, dict):
            if result.get("error"):
                raise Exception(result["error"])
            return result.get("result")
        return None
    except httpx.ConnectError:
        raise Exception("Cannot connect to AnkiConnect. Make sure Anki is running and AnkiConnect add-on is installed.")
    except httpx.TimeoutException:
        raise Exception("Sync timeout. The sync operation is taking longer than expected.")
    except httpx.HTTPStatusError as e:
        raise Exception(f"AnkiConnect error: {e.response.status_code} - {e.response.text}")
    except Exception as e:
        raise Exception(f"Failed to sync: {str(e)}")

async def get_deck_stats(deck_name: str):
    """Get statistics for a deck: new cards and review cards count"""
    import logging
    log = logging.getLogger("uvicorn.error")
    
    try:
        # Find new cards in the deck
        new_cards_raw = await ac_call_raw("findCards", {"query": f'deck:"{deck_name}" is:new'})
        log.info(f"[DECK_STATS] new_cards_raw response type: {type(new_cards_raw)}, value: {repr(new_cards_raw)[:200]}")
        
        new_cards = await ac_call_checked(
            "findCards",
            {"query": f'deck:"{deck_name}" is:new'}
        )
        log.info(f"[DECK_STATS] new_cards after ac_call_checked type: {type(new_cards)}, length: {len(new_cards) if isinstance(new_cards, list) else 'N/A'}")
        
        # Find review cards (due cards) in the deck
        review_cards_raw = await ac_call_raw("findCards", {"query": f'deck:"{deck_name}" is:due'})
        log.info(f"[DECK_STATS] review_cards_raw response type: {type(review_cards_raw)}, value: {repr(review_cards_raw)[:200]}")
        
        review_cards = await ac_call_checked(
            "findCards",
            {"query": f'deck:"{deck_name}" is:due'}
        )
        log.info(f"[DECK_STATS] review_cards after ac_call_checked type: {type(review_cards)}, length: {len(review_cards) if isinstance(review_cards, list) else 'N/A'}")
        
        new_count = len(new_cards) if isinstance(new_cards, list) else 0
        review_count = len(review_cards) if isinstance(review_cards, list) else 0
        
        log.info(f"[DECK_STATS] Final counts - new: {new_count}, review: {review_count}")
        
        return {
            "new": new_count,
            "review": review_count
        }
    except Exception as e:
        log.error(f"[DECK_STATS] Exception: {str(e)}")
        raise Exception(f"Failed to get deck stats: {str(e)}")
