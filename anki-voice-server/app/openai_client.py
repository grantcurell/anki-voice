# app/openai_client.py
import os
import httpx
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Ollama configuration
OLLAMA_API_BASE = os.getenv("OLLAMA_API_BASE", "http://localhost:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "llama2:latest")

# Shared helper for Ollama chat API
async def _call_ollama_chat(system: str, user: str, timeout: int = 45) -> str:
    payload = {
        "model": OLLAMA_MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "stream": False,
    }

    async with httpx.AsyncClient(base_url=OLLAMA_API_BASE, timeout=timeout) as client:
        resp = await client.post("/api/chat", json=payload)
        resp.raise_for_status()
        data = resp.json()

    # Ollama non-streaming chat response: data["message"]["content"]
    message = data.get("message") or {}
    text = ""
    if isinstance(message, dict):
        text = message.get("content") or ""

    return (text or "").strip()


async def grade_with_llm_explanation(question: str, reference: str, transcript: str) -> str:
    """
    Returns a brief explanation of what was wrong, if anything.
    Returns 'Correct.' if the answer is correct or the model returns nothing.
    """
    system = (
        "You provide brief feedback on the user's answer to a flashcard."
        "Provide a brief explanation of what was wrong, if anything."
        "If the answer is correct, respond with an empty string or just say it's correct."
        "Understand we are using TTS and acronyms often will be wrong. If the acronym is close say nothing."
        "The focus is that the user covers what is in the flashcard and understands the concept. Do not nitpick the answer."
        "Keep explanations concise. Your feedback should only be a few sentences at the very most."
    )
    user = (
        f"Question: {question}\n"
        f"Reference answer: {reference}\n"
        f"Spoken transcript: {transcript}\n"
        "Briefly explain if the user's answer was correct or not. If correct, just say it's correct."
    )

    text = await _call_ollama_chat(system=system, user=user)
    return text or "Correct."


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

    text = await _call_ollama_chat(system=system, user=user)
    return text or "I don't have an answer."


async def get_example_in_spanish(question_text: str, reference_text: str) -> str:
    """
    Returns an example usage in Spanish based on the flashcard content.
    The AI should respond entirely in Spanish.
    """
    system = (
        "Eres un asistente que proporciona ejemplos de uso de palabras en español basados en tarjetas de estudio. "
        "Siempre responde completamente en español. "
        "Proporciona un ejemplo práctico y claro de cómo usar la palabra de la tarjeta. "
        "Tu respuesta debe ser UNA oración. No más."
    )
    user = (
        f"Frente de la tarjeta: {question_text}\n"
        f"Reverso de la tarjeta (respuesta de referencia): {reference_text}\n"
        "Proporciona un ejemplo de uso práctico en español que demuestre este concepto."
    )

    text = await _call_ollama_chat(system=system, user=user)
    return text or "No puedo proporcionar un ejemplo en este momento."
