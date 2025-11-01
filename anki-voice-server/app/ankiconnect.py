# app/ankiconnect.py
import httpx

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
