# app/normalize.py
import re, html
from bs4 import BeautifulSoup

def html_to_text(s):
    # Strip HTML into plain text for TTS or grading context
    return BeautifulSoup(s or "", "html.parser").get_text(" ", strip=True)

def html_to_text_readme_only(s, exclude_from_front=True):
    """
    Extract text only from <div> element that has "README" in its class list.
    Also extracts the lang attribute if present.
    If no README div exists, falls back to full content.
    
    Args:
        s: HTML string to parse
        exclude_from_front: If True, exclude README divs inside .from-front containers
                           (useful for back cards that include FrontSide)
    
    Returns tuple: (text, language_code)
    """
    if not s:
        return ("", None)
    
    soup = BeautifulSoup(s, "html.parser")
    
    # Look for div that has "README" in its class list (handles multiple classes like "english README")
    # When exclude_from_front is True, we skip any README divs that are descendants of .from-front
    # This handles cases where the back template includes {{FrontSide}} which might have README divs
    readme_div = None
    for div in soup.find_all("div"):
        classes = div.get("class", [])
        has_readme = False
        if isinstance(classes, list) and "README" in classes:
            has_readme = True
        elif isinstance(classes, str) and "README" in classes:
            has_readme = True
        
        if not has_readme:
            continue
        
        # Skip divs inside .from-front if exclude_from_front is True
        # This ensures we don't pick up front content that's included in the back via {{FrontSide}}
        if exclude_from_front:
            # Check if this div is inside a .from-front container (any ancestor)
            parent = div.find_parent("div", class_="from-front")
            if parent is not None:
                # This README div is inside .from-front, skip it and continue searching
                continue
        
        # Found a valid README div (not excluded)
        readme_div = div
        break
    
    if readme_div:
        # Extract text from README div only
        text = readme_div.get_text(" ", strip=True)
        
        # Find the innermost element with a lang attribute within the README div
        # This makes the most specific/nested lang attribute authoritative
        # Example: <div lang="es-ES" class="README"><span lang="en-US">text</span></div>
        # Should use "en-US" because it's more deeply nested
        lang = None
        innermost_with_lang = None
        max_depth = -1
        
        # Search all descendants of the README div (including the div itself)
        for elem in [readme_div] + readme_div.find_all(True):
            if elem.get("lang"):
                # Calculate nesting depth: how many levels deep is this element within readme_div?
                # readme_div itself = depth 0, its direct children = depth 1, etc.
                depth = 0
                current = elem
                while current != readme_div and current.parent:
                    depth += 1
                    current = current.parent
                    # Safety check: if we somehow got outside readme_div, break
                    if current is None or (hasattr(current, 'name') and current.name is None):
                        break
                
                # If this element is deeper (more nested) than previous, use it
                if depth > max_depth:
                    max_depth = depth
                    innermost_with_lang = elem
        
        # Use the innermost lang attribute, or fall back to the README div's lang
        if innermost_with_lang:
            lang = innermost_with_lang.get("lang")
        else:
            lang = readme_div.get("lang")
        
        return (text, lang)
    else:
        # Fallback: return all text if no README div found
        text = soup.get_text(" ", strip=True)
        return (text, None)

def normalize_text(s):
    s = html.unescape(s or "")
    s = s.lower()
    s = re.sub(r"[^a-z0-9\s/-]", " ", s)
    s = re.sub(r"\s+", " ", s).strip()
    return s

