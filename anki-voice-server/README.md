# Anki Voice Server

FastAPI server that bridges between the Anki add-on and iOS app, providing semantic grading and concept Q&A using LLM (Ollama with GPU acceleration).

## Setup

1. Install dependencies:
```bash
pip install fastapi uvicorn[standard] httpx python-dotenv beautifulsoup4 pydantic
```

2. Create `.env` file with Ollama configuration:
```
OLLAMA_BASE_URL=http://ollama.ollama.svc.cluster.local:11434
OLLAMA_MODEL=llama2:latest
USE_LLM=1
```

3. Run the server:
```bash
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## API Endpoints

### GET /current
Fetches the current card from the Anki add-on and returns it with plain text versions.

### POST /show-answer
Shows the answer on the desktop Anki interface.

### POST /answer/{ease}
Sends the review result to Anki (ease: 1=Again, 2=Hard, 3=Good, 4=Easy).

### POST /grade
Grades a spoken transcript against the card content using:
1. Rule-based matching for structured cards (e.g., SNASSI)
2. LLM (Ollama) semantic analysis for complex answers

Request body:
```json
{
  "cardId": 123,
  "transcript": "user's spoken answer",
  "question_text": "card front text",
  "reference_text": "card back text"
}
```

## Requirements

- Python 3.11+
- Anki with AnkiConnect add-on running
- Anki Voice Bridge add-on running
- Ollama LLM backend configured (GPU-accelerated)

## Testing

Test the endpoints with curl:

```bash
# Get current card
curl http://127.0.0.1:8000/current

# Grade an answer
curl -X POST http://127.0.0.1:8000/grade \
  -H "Content-Type: application/json" \
  -d '{"cardId": 123, "transcript": "there are three: embb, urllc, and mmtc", "question_text": "How many SNASSI settings...?", "reference_text": "Three: enhanced mobile broadband, ultra reliable low latency, massive machine type"}'

# Send answer
curl -X POST http://127.0.0.1:8000/answer/3
```

