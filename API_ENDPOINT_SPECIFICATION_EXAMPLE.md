# API Endpoint Specification: /example

## Overview
This endpoint provides example usage sentences in Spanish based on flashcard content. The AI generates examples entirely in Spanish, regardless of the card's language.

## Endpoint Details

### Production Endpoint (Authenticated)
- **Path**: `/anki/example`
- **Method**: `POST`
- **Authentication**: Required (JWT Bearer token in Authorization header)
- **Content-Type**: `application/json`

### Local Dev Endpoint (Unauthenticated)
- **Path**: `/example`
- **Method**: `POST`
- **Authentication**: None required
- **Content-Type**: `application/json`

## Request Format

### Request Body Schema
```json
{
  "cardId": 1234567890,
  "question_text": "Card front text (optional but recommended)",
  "reference_text": "Card back text (optional but recommended)"
}
```

### Request Body Fields
- `cardId` (integer, required): The Anki card ID
- `question_text` (string, optional but recommended): The card's front text (plain text, HTML stripped)
- `reference_text` (string, optional but recommended): The card's back text (plain text, HTML stripped)

### Example Request
```bash
curl -X POST https://api.grantcurell.com/anki/example \
  -H "Authorization: Bearer <JWT_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 1766692784878,
    "question_text": "vaticinios",
    "reference_text": "Predictions, prophecies, or forecasts about the future"
  }'
```

## Response Format

### Success Response (200 OK)
```json
{
  "example": "Los vaticinios del oráculo predijeron la caída del imperio."
}
```

### Response Fields
- `example` (string, required): A single sentence in Spanish demonstrating usage of the word/concept from the flashcard. Must be exactly ONE sentence, no more.

### Error Responses

#### 400 Bad Request - Missing Required Fields
```json
{
  "detail": "example requires question_text and reference_text"
}
```
**When to return**: If `question_text` or `reference_text` is missing or empty.

#### 401 Unauthorized
```json
{
  "detail": "Invalid or expired token"
}
```
**When to return**: If JWT token is missing, invalid, or expired (production endpoint only).

#### 502 Bad Gateway - LLM Backend Failed
```json
{
  "detail": "LLM backend failed: <error message>"
}
```
**When to return**: If the LLM API call fails (timeout, network error, API error, etc.)

#### 503 Service Unavailable - API Key Not Set
```json
{
  "detail": "OPENAI_API_KEY is not set on the server"
}
```
**When to return**: If the `OPENAI_API_KEY` environment variable is not configured.

#### 500 Internal Server Error
```json
{
  "detail": "Server response formatting error"
}
```
**When to return**: If the LLM response cannot be parsed or formatted correctly.

## Implementation Requirements

### 1. LLM Integration

You must call the `get_example_in_spanish()` function from `app/openai_client.py`. This function:

- Takes two parameters: `question_text` (string) and `reference_text` (string)
- Returns a string containing the example in Spanish
- Uses the Ollama LLM API (configured via `OLLAMA_API_BASE` and `OLLAMA_MODEL` environment variables)
- Has a 45-second timeout
- The system prompt instructs the AI to:
  - Provide examples of word usage in Spanish
  - Always respond completely in Spanish
  - Provide a practical and clear example of how to use the word from the card
  - Return EXACTLY ONE sentence, no more

### 2. Request Validation

Before calling the LLM:
1. Check that `question_text` is provided and not empty
2. Check that `reference_text` is provided and not empty
3. If either is missing, return 400 Bad Request with message: `"example requires question_text and reference_text"`

### 3. Environment Variable Check

Before calling the LLM:
1. Check that `OPENAI_API_KEY` environment variable is set
2. If not set, return 503 Service Unavailable with message: `"OPENAI_API_KEY is not set on the server"`

### 4. Error Handling

- **LLM API failures**: Catch all exceptions from `get_example_in_spanish()`, log the error with full traceback, and return 502 Bad Gateway with detail message
- **JSON parsing errors**: If the LLM response cannot be parsed, return 500 Internal Server Error
- **Timeout**: The LLM function has a 45-second timeout built-in; if it times out, it will raise an exception that should be caught and returned as 502

### 5. Response Formatting

- The response must be a JSON object with a single field: `example` (string)
- The `example` field contains the Spanish sentence returned by the LLM
- Do NOT wrap the response in additional fields like `status`, `result`, etc. - just return `{"example": "..."}`

### 6. Authentication (Production Only)

For the `/anki/example` endpoint:
- Extract JWT token from `Authorization: Bearer <token>` header
- Validate the token using your existing JWT validation logic
- If invalid or missing, return 401 Unauthorized
- The token validation should match the same logic used for other `/anki/*` endpoints

### 7. Routing

- **Production**: Route `/anki/example` to the handler (authenticated)
- **Local Dev**: Route `/example` to the same handler (no authentication required)
- Both endpoints should use the same handler function, just with different authentication middleware

## Code Structure Reference

### FastAPI Endpoint Handler (Python)

```python
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional
from .openai_client import get_example_in_spanish
import os
import traceback
import logging

log = logging.getLogger("uvicorn.error")

class ExampleIn(BaseModel):
    cardId: int
    question_text: Optional[str] = None
    reference_text: Optional[str] = None

@app.post("/example")  # Local dev endpoint
@app.post("/anki/example")  # Production endpoint (with auth middleware)
async def get_example(inp: ExampleIn):
    """Get an example usage in Spanish based on the flashcard content"""
    
    # 1. Validate required fields
    if not inp.question_text or not inp.reference_text:
        raise HTTPException(
            status_code=400, 
            detail="example requires question_text and reference_text"
        )
    
    # 2. Check for API key
    if not os.getenv("OPENAI_API_KEY"):
        raise HTTPException(
            status_code=503, 
            detail="OPENAI_API_KEY is not set on the server"
        )
    
    # 3. Call LLM
    try:
        example = await get_example_in_spanish(
            question_text=inp.question_text,
            reference_text=inp.reference_text
        )
        return {"example": example}
    except Exception as e:
        log.error("LLM call failed for example: %s\n%s", e, traceback.format_exc())
        raise HTTPException(
            status_code=502, 
            detail=f"LLM backend failed: {e}"
        )
```

### Function to Import

The `get_example_in_spanish()` function is already implemented in `app/openai_client.py`. You just need to import and call it:

```python
from .openai_client import get_example_in_spanish
```

## Testing Checklist

Before deploying, verify:

- [ ] Endpoint accepts POST requests to `/example` (local) and `/anki/example` (production)
- [ ] Request validation: Returns 400 if `question_text` or `reference_text` is missing
- [ ] Authentication: Returns 401 if JWT token is invalid/missing (production only)
- [ ] API key check: Returns 503 if `OPENAI_API_KEY` is not set
- [ ] LLM integration: Successfully calls `get_example_in_spanish()` and returns Spanish example
- [ ] Response format: Returns `{"example": "..."}` with exactly one Spanish sentence
- [ ] Error handling: Returns 502 with error message if LLM call fails
- [ ] Timeout: Handles 45-second timeout gracefully
- [ ] Logging: Logs errors with full traceback for debugging

## Example Test Cases

### Test Case 1: Valid Request
**Request**:
```json
POST /anki/example
Authorization: Bearer <valid_token>
{
  "cardId": 123,
  "question_text": "vaticinios",
  "reference_text": "Predictions, prophecies, or forecasts"
}
```

**Expected Response** (200 OK):
```json
{
  "example": "Los vaticinios del oráculo predijeron la caída del imperio."
}
```

### Test Case 2: Missing Fields
**Request**:
```json
POST /anki/example
{
  "cardId": 123
}
```

**Expected Response** (400 Bad Request):
```json
{
  "detail": "example requires question_text and reference_text"
}
```

### Test Case 3: Invalid Token
**Request**:
```json
POST /anki/example
Authorization: Bearer invalid_token
{
  "cardId": 123,
  "question_text": "test",
  "reference_text": "test"
}
```

**Expected Response** (401 Unauthorized):
```json
{
  "detail": "Invalid or expired token"
}
```

### Test Case 4: LLM Failure
**Request**: Valid request but LLM API is down

**Expected Response** (502 Bad Gateway):
```json
{
  "detail": "LLM backend failed: <error message>"
}
```

## Important Notes

1. **Response must be ONE sentence**: The LLM is instructed to return exactly one sentence. The endpoint should return whatever the LLM provides, but the LLM prompt enforces this constraint.

2. **Always in Spanish**: The AI is instructed to always respond in Spanish, regardless of the card's language. The endpoint should not modify the response language.

3. **No additional formatting**: Do NOT add prefixes like "Example:" or "Ejemplo:" to the response. Return the LLM's response as-is.

4. **Error messages**: Use the exact error messages specified above for consistency with the iOS app's error handling.

5. **Logging**: Log all errors with full traceback for debugging purposes, but do not expose sensitive information in error responses to clients.

## Integration with Existing Codebase

- The `get_example_in_spanish()` function is already implemented in `anki-voice-server/app/openai_client.py`
- Follow the same pattern as the `/ask` endpoint in `anki-voice-server/app/main.py`
- Use the same authentication middleware as other `/anki/*` endpoints
- Use the same error handling pattern as `/grade-with-explanation` endpoint

## Deployment Notes

- Deploy to production API at `https://api.grantcurell.com`
- Ensure `OPENAI_API_KEY` environment variable is set
- Ensure `OLLAMA_API_BASE` and `OLLAMA_MODEL` environment variables are configured
- Test with a real flashcard before marking as complete
- Verify the endpoint works with both authenticated (production) and unauthenticated (local dev) requests
