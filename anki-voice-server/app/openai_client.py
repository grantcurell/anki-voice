# app/openai_client.py
import os, httpx, json, re
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_API_BASE = os.getenv("OPENAI_API_BASE", "https://api.openai.com/v1")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-5-mini")

HEADERS = {"Authorization": f"Bearer {OPENAI_API_KEY}", "Content-Type": "application/json"}

async def grade_with_gpt5(question: str, reference: str, transcript: str) -> dict:
    system = (
        "You grade short spoken answers to flashcards. "
        "Return STRICT JSON with keys: correct (bool), missing (array of strings), "
        "extras (array of strings), confidence (0..1), short_reason (string)."
    )
    user = (
        f"Question: {question}\n"
        f"Reference answer: {reference}\n"
        f"Spoken transcript: {transcript}\n"
        "Judge semantic equivalence; accept paraphrases and standard acronyms."
    )
    payload = {
        "model": OPENAI_MODEL,
        "input": [
            {"role": "system", "content": system},
            {"role": "user",   "content": user}
        ]
    }
    async with httpx.AsyncClient(base_url=OPENAI_API_BASE, headers=HEADERS, timeout=30) as x:
        r = await x.post("/responses", json=payload)
        r.raise_for_status()
        data = r.json()
        
        # Extract text from GPT-5 Responses API format
        text = ""
        if "output" in data and len(data["output"]) > 1:
            output_item = data["output"][1]  # The message output
            if "content" in output_item and len(output_item["content"]) > 0:
                text = output_item["content"][0].get("text", "")
        
        m = re.search(r"\{.*\}", text, re.S)
        try:
            return json.loads(m.group(0)) if m else {"correct": False, "missing": [], "extras": [], "confidence": 0.0, "short_reason": "no-json"}
        except Exception:
            return {"correct": False, "missing": [], "extras": [], "confidence": 0.0, "short_reason": "parse-error"}

async def grade_with_gpt5_explanation(question: str, reference: str, transcript: str) -> dict:
    """
    Returns STRICT JSON:
      { correct: bool, explanation: string, confidence: 0..1,
        missing: string[], extras: string[] }
    """
    system = (
        "You evaluate spoken answers to flashcards and explain the reasoning. "
        "Return STRICT JSON with keys: correct (bool), explanation (string), "
        "confidence (0..1), missing (array of strings), extras (array of strings). "
        "Focus on explaining what was right/wrong, not suggesting grades."
    )
    user = (
        f"Question: {question}\n"
        f"Reference answer: {reference}\n"
        f"Spoken transcript: {transcript}\n"
        "Explain what was correct or incorrect about this answer. Be detailed and educational."
    )
    payload = {
        "model": OPENAI_MODEL,
        "input": [
            {"role":"system","content":system},
            {"role":"user","content":user}
        ]
    }
    async with httpx.AsyncClient(base_url=OPENAI_API_BASE, headers=HEADERS, timeout=45) as x:
        r = await x.post("/responses", json=payload)
        r.raise_for_status()
        data = r.json()

        # Prefer 'output_text' if present; fallback to concatenating content
        text = data.get("output_text", "")
        if not text:
            # Fallback: collect any content blocks
            chunks = []
            for item in data.get("output", []):
                c = item.get("content")
                if isinstance(c, list):
                    for part in c:
                        t = part.get("text")
                        if t: chunks.append(t)
            text = "\n".join(chunks)

        import re, json as pyjson
        m = re.search(r"\{.*\}", text, re.S)
        try:
            return pyjson.loads(m.group(0)) if m else {
                "correct": False, "explanation": "No JSON returned.",
                "confidence": 0.0, "missing": [], "extras": []
            }
        except Exception:
            return {
                "correct": False, "explanation": "Parse error.",
                "confidence": 0.0, "missing": [], "extras": []
            }

async def answer_followup(question_text: str, reference_text: str, user_question: str) -> str:
    """
    Returns a short, clear textual explanation that uses the card's front/back as context.
    """
    system = (
        "You are a concise tutor. Answer follow-up questions using the provided card context. "
        "Be concrete and brief. If the follow-up asks beyond the card, answer but be clear about scope."
    )
    user = (
        f"Card front: {question_text}\n"
        f"Card back (reference): {reference_text}\n"
        f"User follow-up question: {user_question}\n"
        "Answer succinctly (3-6 sentences)."
    )
    payload = {
        "model": OPENAI_MODEL,
        "input": [
            {"role":"system","content":system},
            {"role":"user","content":user}
        ]
    }
    async with httpx.AsyncClient(base_url=OPENAI_API_BASE, headers=HEADERS, timeout=45) as x:
        r = await x.post("/responses", json=payload)
        r.raise_for_status()
        data = r.json()
        text = data.get("output_text", "")
        if not text:
            chunks = []
            for item in data.get("output", []):
                c = item.get("content")
                if isinstance(c, list):
                    for part in c:
                        t = part.get("text")
                        if t: chunks.append(t)
            text = "\n".join(chunks)
        return text.strip() or "I don't have an answer."
