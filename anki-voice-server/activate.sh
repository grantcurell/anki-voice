#!/bin/bash
# Activate virtual environment for anki-voice-server

echo "🐍 Activating Python 3.12 virtual environment for anki-voice-server"
echo "=================================================================="

if [ ! -f "venv/bin/activate" ]; then
    echo "❌ Virtual environment not found. Run setup first."
    exit 1
fi

source venv/bin/activate
echo "✅ Virtual environment activated"
echo "Python version: $(python --version)"
echo ""
echo "To start the server:"
echo "  uvicorn app.main:app --host 0.0.0.0 --port 8000"
echo ""
echo "To deactivate: deactivate"

