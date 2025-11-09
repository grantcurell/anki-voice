# app/main.py
import os
import traceback
import logging
import json
import re
import asyncio
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from typing import Optional, Dict, Any, List
import httpx
from dotenv import load_dotenv
from .normalize import html_to_text, html_to_text_readme_only
from .judge import list_set_match, ease_from_verdict
from .ankiconnect import show_answer, answer_card, undo_review, get_note_id, delete_note, suspend_cards, get_card_info, get_note_info, retrieve_media_file, close_reviewer, AC
from .openai_client import grade_with_gpt5_explanation, answer_followup

# Load environment variables from .env file
load_dotenv()

log = logging.getLogger("uvicorn.error")

ADDON_BASE = "http://127.0.0.1:8770"

USE_GPT5 = os.getenv("USE_GPT5", "1") == "1"

app = FastAPI(title="Anki Voice Server")

# Cache for deck language configs (key: deck name, value: config dict)
_deck_lang_cache: Dict[str, Dict[str, str]] = {}


def sanitize_deck_name_for_filename(deck_name: str) -> str:
    """Sanitize deck name for use in filename"""
    return re.sub(r"[^A-Za-z0-9._-]+", "_", deck_name.strip())


async def get_deck_language_config(deck_name: str) -> Optional[Dict[str, str]]:
    """Get language configuration for a deck from media file"""
    # Check cache first
    if deck_name in _deck_lang_cache:
        return _deck_lang_cache[deck_name]
    
    # Try to read from media file
    sanitized = sanitize_deck_name_for_filename(deck_name)
    filename = f"_ankiVoice.deck.{sanitized}.json"
    
    try:
        content = await retrieve_media_file(filename)
        if content:
            config = json.loads(content)
            # Cache it
            _deck_lang_cache[deck_name] = config
            return config
    except Exception as e:
        log.debug(f"Could not read deck config for {deck_name}: {e}")
    
    return None


def extract_lang_from_tags(tags: List[str], prefix: str) -> Optional[str]:
    """Extract language from tags like 'av:front=es-ES' or 'av:back=en-US'"""
    for tag in tags:
        if tag.startswith(f"{prefix}="):
            return tag[len(prefix) + 1:]
    return None


async def get_language_hints(card_id: int) -> Dict[str, Optional[str]]:
    """Get language hints for front and back of a card"""
    front_lang = None
    back_lang = None
    
    # Get card info to find deck name
    card_info = await get_card_info(card_id)
    if not card_info:
        return {"front_language": None, "back_language": None}
    
    deck_name = card_info.get("deckName")
    if not deck_name:
        return {"front_language": None, "back_language": None}
    
    # Get note info to check for per-note tags
    note_id = card_info.get("note")
    note_tags = []
    if note_id:
        note_info = await get_note_info(note_id)
        if note_info:
            note_tags = note_info.get("tags", [])
    
    # Check for per-note tag overrides first (these take precedence)
    front_lang = extract_lang_from_tags(note_tags, "av:front")
    back_lang = extract_lang_from_tags(note_tags, "av:back")
    
    # If no per-note tags, check deck-level config
    if not front_lang or not back_lang:
        deck_config = await get_deck_language_config(deck_name)
        if deck_config:
            if not front_lang:
                front_lang = deck_config.get("frontLang")
            if not back_lang:
                back_lang = deck_config.get("backLang")
    
    return {
        "front_language": front_lang,
        "back_language": back_lang
    }

# Add CORS middleware to allow iPhone app on LAN
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, specify your iPhone's IP range
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.get("/health")
async def health_check():
    """Check the health of all components"""
    status = {
        "server": "ok",
        "anki_addon": "unknown",
        "ankiconnect": "unknown",
        "anki_running": "unknown"
    }
    
    # Check Anki add-on
    try:
        async with httpx.AsyncClient(timeout=2) as x:
            r = await x.get(f"{ADDON_BASE}/ping")
        if r.status_code == 200 and r.json().get("ok"):
            status["anki_addon"] = "ok"
        else:
            status["anki_addon"] = f"error_{r.status_code}"
    except Exception as e:
        status["anki_addon"] = f"error: {str(e)}"
    
    # Check AnkiConnect
    try:
        async with httpx.AsyncClient(timeout=2) as x:
            r = await x.post(AC, json={"action": "version", "version": 6})
        if r.status_code == 200:
            status["ankiconnect"] = "ok"
            status["anki_running"] = "ok"
        else:
            status["ankiconnect"] = f"error_{r.status_code}"
    except Exception as e:
        status["ankiconnect"] = f"error: {str(e)}"
        status["anki_running"] = "not_running"
    
    return status

class GradeIn(BaseModel):
    cardId: int
    transcript: str
    question_text: Optional[str] = None
    reference_text: Optional[str] = None

class SubmitGradeIn(BaseModel):
    cardId: int
    ease: int  # 1..4

class AskIn(BaseModel):
    cardId: int
    question: str
    question_text: Optional[str] = None
    reference_text: Optional[str] = None

class DeleteNoteIn(BaseModel):
    cardId: int

@app.get("/current")
async def current():
    try:
        async with httpx.AsyncClient(timeout=2.0) as x:
            r = await x.get(f"{ADDON_BASE}/current")
        data = r.json()
        
        if data.get("status") != "ok":
            return {
                "status": "error",
                "message": f"Anki add-on returned: {data.get('status', 'unknown')}",
                "details": "Make sure Anki is open with a card ready for review"
            }
        
        # Extract text from README div if present, otherwise use full content
        # Also extract lang attribute from README div
        # For front: don't exclude .from-front (there shouldn't be any)
        # For back: exclude .from-front to avoid picking up front content that's included via {{FrontSide}}
        front_text_readme, front_lang_from_div = html_to_text_readme_only(data.get("front_html"), exclude_from_front=False)
        back_text_readme, back_lang_from_div = html_to_text_readme_only(data.get("back_html"), exclude_from_front=True)
        
        # For display: use full HTML converted to text (for showing entire card)
        # For TTS: use only README div content
        data["front_text"] = html_to_text(data.get("front_html"))  # Full front for display
        data["back_text"] = html_to_text(data.get("back_html"))     # Full back for display
        data["front_text_tts"] = front_text_readme  # README div only for TTS
        data["back_text_tts"] = back_text_readme    # README div only for TTS
        
        # Get language hints for TTS (from deck config or note tags)
        card_id = data.get("cardId")
        if card_id:
            lang_hints = await get_language_hints(card_id)
            # Use lang attribute from README div if present, otherwise use deck/note config, otherwise default to en-US
            data["front_language"] = front_lang_from_div or lang_hints.get("front_language") or "en-US"
            data["back_language"] = back_lang_from_div or lang_hints.get("back_language") or "en-US"
        else:
            # Fallback if no card ID
            data["front_language"] = front_lang_from_div or "en-US"
            data["back_language"] = back_lang_from_div or "en-US"
        
        return data
        
    except httpx.ConnectError:
        return {
            "status": "error",
            "message": "Cannot connect to Anki add-on",
            "details": "Make sure Anki is running and the add-on is installed"
        }
    except httpx.TimeoutException:
        return {
            "status": "error", 
            "message": "Anki add-on timeout",
            "details": "Anki may be busy or not responding"
        }
    except Exception as e:
        return {
            "status": "error",
            "message": f"Unexpected error: {str(e)}",
            "details": "Check server logs for more information"
        }

@app.post("/show-answer")
async def api_show_answer():
    return await show_answer()

@app.post("/answer/{ease}")
async def api_answer(ease:int):
    if ease not in (1,2,3,4):
        raise HTTPException(400, "ease must be 1..4")
    return await answer_card(ease)

@app.post("/grade")
async def api_grade(inp: GradeIn):
    # 1) quick deterministic checks for known structured cards (example: SNASSI)
    verdict, hits, missing = list_set_match(inp.transcript, canonical={
        "enhanced mobile broadband":{"embb","enhanced mobile broadband"},
        "ultra reliable low latency":{"urllc","ultra reliable low latency"},
        "massive machine type":{"mmtc","massive machine type","massive machine type communications"},
    })
    suggested = ease_from_verdict(verdict)
    reasons = {"rule_hits": list(hits), "rule_missing": list(missing)}

    return {"verdict": verdict, "suggested_ease": suggested, "reasons": reasons}

@app.post("/grade-with-explanation")
async def api_grade_with_explanation(inp: GradeIn):
    # Require question_text and reference_text for the explanation route
    if not inp.question_text or not inp.reference_text:
        raise HTTPException(400, "grade-with-explanation requires question_text and reference_text")

    # Test mode: return dummy response without calling LLM
    if not USE_GPT5:
        return {"explanation": "Test mode: looks correct."}

    # Check for API key early and fail clearly
    if not os.getenv("OPENAI_API_KEY"):
        raise HTTPException(503, detail="OPENAI_API_KEY is not set on the server")

    try:
        explanation = await grade_with_gpt5_explanation(
            question=inp.question_text,
            reference=inp.reference_text,
            transcript=inp.transcript
        )
        return {"explanation": explanation}
    except Exception as e:
        log.error("LLM call failed: %s\n%s", e, traceback.format_exc())
        raise HTTPException(502, detail=f"LLM backend failed: {e}")

@app.post("/submit-grade")
async def submit_manual_grade(inp: SubmitGradeIn):
    if inp.ease not in (1,2,3,4):
        raise HTTPException(400, "ease must be 1..4")
    
    # Ensure reviewer is in "answer shown" state; harmless if already shown
    # This is required by AnkiConnect: guiAnswerCard only works when answer is visible
    sa = await show_answer()
    if isinstance(sa, dict) and sa.get("error"):
        # e.g., reviewer closed or not in a review session
        raise HTTPException(409, detail=f"Reviewer not ready: {sa['error']}")
    
    # Now submit the grade
    ans = await answer_card(inp.ease)
    # Some AnkiConnect GUI actions return {"result": null, "error": null}; treat that as success.
    if isinstance(ans, dict) and ans.get("error"):
        raise HTTPException(502, detail=f"AnkiConnect error: {ans['error']}")
    
    return ans

@app.post("/undo")
async def undo_last_grade():
    return await undo_review()

@app.post("/ask")
async def ask_about_card(inp: AskIn):
    if not inp.question_text or not inp.reference_text:
        raise HTTPException(400, "ask requires question_text and reference_text")
    text = await answer_followup(
        question_text=inp.question_text,
        reference_text=inp.reference_text,
        user_question=inp.question
    )
    return {"answer": text}

@app.post("/delete-note")
async def delete_current_note(inp: DeleteNoteIn):
    """Suspend the card (safer than deleting - card won't appear in reviews but note is preserved)"""
    try:
        # Suspend the card directly (no need to get note ID or close reviewer)
        # Suspending is safe and won't cause crashes
        result = await suspend_cards([inp.cardId])
        if isinstance(result, dict) and result.get("error"):
            raise HTTPException(502, detail=f"AnkiConnect error: {result['error']}")
        
        return {"result": result.get("result"), "error": result.get("error")}
    except HTTPException:
        raise
    except Exception as e:
        log.error("Suspend card failed: %s\n%s", e, traceback.format_exc())
        raise HTTPException(500, detail=f"Failed to suspend card: {str(e)}")

if __name__ == "__main__":
    import uvicorn
    # host="0.0.0.0" binds to all network interfaces, including:
    # - localhost (127.0.0.1)
    # - local network IPs (e.g., 192.168.x.x)
    # - VPN/Tailscale IPs (e.g., 100.101.120.23)
    # - any other network interface on the machine
    uvicorn.run(app, host="0.0.0.0", port=8000)
