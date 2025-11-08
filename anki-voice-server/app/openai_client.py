# app/openai_client.py
import os, httpx
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_API_BASE = os.getenv("OPENAI_API_BASE", "https://api.openai.com/v1")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-5-mini")

HEADERS = {"Authorization": f"Bearer {OPENAI_API_KEY}", "Content-Type": "application/json"}

async def grade_with_gpt5_explanation(question: str, reference: str, transcript: str) -> str:
    """
    Returns a brief explanation of what was wrong, if anything.
    Returns empty string if the answer is correct.
    """
    system = (
        "You evaluate spoken answers to flashcards."
        "Provide a brief explanation of what was wrong, if anything. "
        "If the answer is correct, respond with an empty string or just say it's correct."
        "Understand we are using TTS and acronyms often will be wrong. If the acronym is close say nothing."
        "The focus is that the user covers what is in the flashcard and understands the concept. Do not nitpick the answer."
        "Keep explanations concise. Unless absolutely necessary your feedback should be limited to a few sentences."
    )
    user = (
        f"Question: {question}\n"
        f"Reference answer: {reference}\n"
        f"Spoken transcript: {transcript}\n"
        "Briefly explain what was incorrect about this answer, if anything. If correct, just say it's correct."
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
        
        # Return the explanation text directly, stripping whitespace
        return text.strip() or "Correct."

async def answer_followup(question_text: str, reference_text: str, user_question: str) -> str:
    """
    Returns a brief textual explanation that uses the card's front/back as context.
    """
    system = (
        "You answer follow-up questions about flashcards. "
        "Be brief and direct. Use the card context provided."
    )
    user = (
        f"Card front: {question_text}\n"
        f"Card back (reference): {reference_text}\n"
        f"User question: {user_question}\n"
        "Provide a brief answer (1-3 sentences)."
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
