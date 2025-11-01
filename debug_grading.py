#!/usr/bin/env python3
import os
import httpx
import json
import re

# Load environment variables
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_API_BASE = os.getenv("OPENAI_API_BASE", "https://api.openai.com/v1")
OPENAI_MODEL = "gpt-4"

HEADERS = {"Authorization": f"Bearer {OPENAI_API_KEY}", "Content-Type": "application/json"}

async def test_grading():
    system = (
        "You grade short spoken answers to flashcards. "
        "Return STRICT JSON with keys: correct (bool), missing (array of strings), "
        "extras (array of strings), confidence (0..1), short_reason (string)."
    )
    user = (
        f"Question: Which types of functions inside the 5G Core commonly interact with the Network Exposure Function (NEF)?\n"
        f"Reference answer: The NEF mainly interacts with control-plane and data storage functions in the 5G Core — for example, functions that manage sessions, policies, or subscriber data. The idea is that NEF sits between external applications and these internal functions, so apps don't talk to the core directly.\n"
        f"Spoken transcript: The NEF mainly interacts with control-plane and data storage functions in the 5G Core — for example, functions that manage sessions, policies, or subscriber data. The idea is that NEF sits between external applications and these internal functions, so apps don't talk to the core directly.\n"
        "Judge semantic equivalence; accept paraphrases and standard acronyms."
    )
    payload = {
        "model": OPENAI_MODEL,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user",   "content": user}
        ]
    }
    
    print("Testing GPT-4 grading...")
    try:
        async with httpx.AsyncClient(base_url=OPENAI_API_BASE, headers=HEADERS, timeout=30) as x:
            r = await x.post("/chat/completions", json=payload)
            print(f"Status: {r.status_code}")
            r.raise_for_status()
            data = r.json()
            print(f"Full response keys: {list(data.keys())}")
            
            # Extract text from GPT-4 chat completions format
            text = ""
            if "choices" in data and len(data["choices"]) > 0:
                text = data["choices"][0]["message"]["content"]
                print(f"Extracted text: {text}")
            
            m = re.search(r"\{.*\}", text, re.S)
            if m:
                result = json.loads(m.group(0))
                print(f"Parsed result: {json.dumps(result, indent=2)}")
            else:
                print("No JSON found in response")
                
    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()

if __name__ == "__main__":
    import asyncio
    asyncio.run(test_grading())
