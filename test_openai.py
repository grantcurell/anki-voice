#!/usr/bin/env python3
import os
import httpx
import json
import re

# Load environment variables
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
OPENAI_API_BASE = os.getenv("OPENAI_API_BASE", "https://api.openai.com/v1")
OPENAI_MODEL = os.getenv("OPENAI_MODEL", "gpt-5")

print(f"API Key: {'SET' if OPENAI_API_KEY else 'NOT SET'}")
print(f"API Base: {OPENAI_API_BASE}")
print(f"Model: {OPENAI_MODEL}")

if not OPENAI_API_KEY:
    print("ERROR: No API key found!")
    exit(1)

HEADERS = {"Authorization": f"Bearer {OPENAI_API_KEY}", "Content-Type": "application/json"}

async def test_gpt5():
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
        "input": [
            {"role": "system", "content": system},
            {"role": "user",   "content": user}
        ]
    }
    
    print("Sending request to OpenAI...")
    try:
        async with httpx.AsyncClient(base_url=OPENAI_API_BASE, headers=HEADERS, timeout=30) as x:
            r = await x.post("/responses", json=payload)
            print(f"Status: {r.status_code}")
            r.raise_for_status()
            data = r.json()
            print(f"Response: {json.dumps(data, indent=2)}")
            
            text = data.get("output_text") or ""
            print(f"Output text: {text}")
            
            m = re.search(r"\{.*\}", text, re.S)
            if m:
                result = json.loads(m.group(0))
                print(f"Parsed result: {json.dumps(result, indent=2)}")
            else:
                print("No JSON found in response")
                
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    import asyncio
    asyncio.run(test_gpt5())

