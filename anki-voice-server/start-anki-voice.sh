#!/usr/bin/env bash
# start-anki-voice.sh
# Starts the Anki Voice FastAPI server
# Add to System Settings → General → Login Items for auto-start

cd "$(dirname "$0")" || exit 1

# Activate virtual environment if it exists
if [ -f "venv/bin/activate" ]; then
    source venv/bin/activate
fi

# Start the server
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --log-level info

