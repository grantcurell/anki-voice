# app/normalize.py
import re, html
from bs4 import BeautifulSoup

def html_to_text(s):
    # Strip HTML into plain text for TTS or grading context
    return BeautifulSoup(s or "", "html.parser").get_text(" ", strip=True)

def normalize_text(s):
    s = html.unescape(s or "")
    s = s.lower()
    s = re.sub(r"[^a-z0-9\s/-]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s

def token_set(s):
    return set(normalize_text(s).split())

