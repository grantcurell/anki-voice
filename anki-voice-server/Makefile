# Anki Voice Server - Convenience Makefile

.PHONY: run dev install test

# Start server (production mode)
run:
	uvicorn app.main:app --host 0.0.0.0 --port 8000 --log-level info

# Start server with auto-reload (development mode)
dev:
	uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload

# Install dependencies
install:
	pip install -r requirements.txt

# Test server health endpoint
test:
	curl -sS http://localhost:8000/health | python -m json.tool || echo "Server not running"

