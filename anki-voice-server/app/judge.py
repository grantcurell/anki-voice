# app/judge.py
from .normalize import normalize_text

SNASSI_REQ = {
    "enhanced mobile broadband": {"embb", "enhanced mobile broadband"},
    "ultra reliable low latency": {"urllc", "ultra reliable low latency", "ultra-reliable low-latency"},
    "massive machine type": {"mmtc", "massive machine type", "massive machine-type communications", "massive m2m"},
}

def list_set_match(transcript:str, canonical:dict):
    txt = normalize_text(transcript)
    hits = set()
    for canon, aliases in canonical.items():
        for a in aliases | {canon}:
            if a in txt:
                hits.add(canon)
                break
    count = len(hits)
    if count == len(canonical):
        return "correct", hits, []
    elif count >= max(1, len(canonical) - 1):
        missing = set(canonical.keys()) - hits
        return "partial", hits, list(missing)
    else:
        missing = set(canonical.keys()) - hits
        return "wrong", hits, list(missing)

def ease_from_verdict(verdict:str, confidence:float=1.0):
    if verdict == "correct" and confidence > 0.85:
        return 4  # Easy
    if verdict == "correct":
        return 3  # Good
    if verdict == "partial":
        return 2  # Hard
    return 1      # Again

