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


async def grade_with_llm_explanation(question: str, reference: str, transcript: str, language: str = "en-US") -> str:
    """
    Returns a brief explanation of what was wrong, if anything.
    Returns 'Correct.' if the answer is correct or the model returns nothing.
    
    Args:
        language: Language code (e.g., "en-US", "es-ES"). Determines prompt and response language.
    """
    is_spanish = language.startswith("es")
    
    if is_spanish:
        system = (
            "Eres un asistente que proporciona retroalimentación breve sobre las respuestas del usuario a tarjetas de estudio. "
            "Proporciona una explicación breve de lo que estaba mal, si es que había algo. "
            "Si la respuesta es correcta, responde con una cadena vacía o simplemente di que es correcta. "
            "Entendemos que estamos usando TTS y los acrónimos a menudo estarán mal. Si el acrónimo es cercano, no digas nada. "
            "El enfoque es que el usuario cubra lo que está en la tarjeta y entienda el concepto. No seas quisquilloso con la respuesta. "
            "Mantén las explicaciones concisas. Tu retroalimentación debe ser solo unas pocas oraciones como máximo. "
            "SIEMPRE responde completamente en español."
        )
        user = (
            f"Pregunta: {question}\n"
            f"Respuesta de referencia: {reference}\n"
            f"Transcripción hablada: {transcript}\n"
            "Explica brevemente si la respuesta del usuario fue correcta o no. Si es correcta, simplemente di que es correcta."
        )
        default_response = "Correcto."
    else:
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
        default_response = "Correct."

    text = await _call_ollama_chat(system=system, user=user)
    return text or default_response


async def answer_followup(question_text: str, reference_text: str, user_question: str, language: str = "en-US") -> str:
    """
    Returns a brief textual explanation that uses the card's front/back as context.
    
    Args:
        language: Language code (e.g., "en-US", "es-ES"). Determines prompt and response language.
    """
    is_spanish = language.startswith("es")
    
    if is_spanish:
        system = (
            "Respondes preguntas de seguimiento sobre tarjetas de estudio. "
            "Sé breve y directo. Usa el contexto de la tarjeta proporcionado. "
            "SIEMPRE responde completamente en español."
        )
        user = (
            f"Frente de la tarjeta: {question_text}\n"
            f"Reverso de la tarjeta (referencia): {reference_text}\n"
            f"Pregunta del usuario: {user_question}\n"
            "Proporciona una respuesta breve (1-3 oraciones)."
        )
        default_response = "No tengo una respuesta."
    else:
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
        default_response = "I don't have an answer."

    text = await _call_ollama_chat(system=system, user=user)
    return text or default_response


async def get_example_in_spanish(question_text: str, reference_text: str, language: str = "es-ES") -> str:
    """
    Returns an example usage based on the flashcard content.
    The language parameter determines the response language.
    
    Args:
        language: Language code (e.g., "en-US", "es-ES"). Determines response language.
    """
    is_spanish = language.startswith("es")
    
    if is_spanish:
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
        default_response = "No puedo proporcionar un ejemplo en este momento."
    else:
        system = (
            "You are an assistant that provides example usage of words based on study cards. "
            "Always respond completely in English. "
            "Provide a practical and clear example of how to use the word from the card. "
            "Your response must be ONE sentence. No more."
        )
        user = (
            f"Card front: {question_text}\n"
            f"Card back (reference answer): {reference_text}\n"
            "Provide a practical usage example in English that demonstrates this concept."
        )
        default_response = "I cannot provide an example at this time."

    text = await _call_ollama_chat(system=system, user=user)
    return text or default_response
