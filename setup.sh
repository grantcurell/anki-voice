#!/bin/bash

# Anki Voice System Setup Script
# This script helps set up the complete Anki Voice system

echo "🎯 Anki Voice System Setup"
echo "=========================="

# Check if we're in the right directory
if [ ! -d "anki-voice-bridge" ] || [ ! -d "anki-voice-server" ] || [ ! -d "anki-voice-ios" ]; then
    echo "❌ Please run this script from the Anki Voice root directory"
    echo "   Expected structure:"
    echo "   - anki-voice-bridge/"
    echo "   - anki-voice-server/"
    echo "   - anki-voice-ios/"
    exit 1
fi

echo "✅ Found all three repositories"

# Check Python version
python_version=$(python3 --version 2>&1 | grep -oE '[0-9]+\.[0-9]+')
if [[ $(echo "$python_version >= 3.11" | bc -l) -eq 0 ]]; then
    echo "❌ Python 3.11+ required, found $python_version"
    exit 1
fi
echo "✅ Python version: $python_version"

# Setup server dependencies
echo ""
echo "📦 Setting up server dependencies..."
cd anki-voice-server

if [ ! -f ".env" ]; then
    echo "⚠️  Creating .env file template..."
    cat > .env << EOF
OPENAI_API_KEY=sk-your-key-here
OPENAI_API_BASE=https://api.openai.com/v1
OPENAI_MODEL=gpt-5-chat-latest
USE_GPT5=1
EOF
    echo "📝 Please edit .env file with your OpenAI API key"
fi

echo "Installing Python dependencies..."
pip install fastapi uvicorn[standard] httpx python-dotenv beautifulsoup4 pydantic

echo "✅ Server setup complete"

# Check Anki installation
echo ""
echo "🔍 Checking Anki installation..."
anki_path=""
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    anki_path="$HOME/Library/Application Support/Anki2/addons21"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Linux
    anki_path="$HOME/.local/share/Anki2/addons21"
elif [[ "$OSTYPE" == "msys" ]] || [[ "$OSTYPE" == "win32" ]]; then
    # Windows
    anki_path="$APPDATA/Anki2/addons21"
fi

if [ ! -d "$anki_path" ]; then
    echo "❌ Anki add-ons directory not found at: $anki_path"
    echo "   Please install Anki first"
    exit 1
fi

echo "✅ Anki add-ons directory found: $anki_path"

# Install Anki add-on
echo ""
echo "📱 Installing Anki Voice Bridge add-on..."
addon_dest="$anki_path/anki_voice_bridge"
mkdir -p "$addon_dest"
cp ../anki-voice-bridge/__init__.py "$addon_dest/"

echo "✅ Add-on installed to: $addon_dest"

# Test server
echo ""
echo "🧪 Testing server setup..."
cd ..
cd anki-voice-server

echo "Starting server test (will timeout after 5 seconds)..."
timeout 5s uvicorn app.main:app --host 127.0.0.1 --port 8000 &
server_pid=$!
sleep 2

# Test if server is responding
if curl -s http://127.0.0.1:8000/docs > /dev/null; then
    echo "✅ Server test successful"
else
    echo "⚠️  Server test failed - this is normal if dependencies aren't fully installed"
fi

# Clean up test server
kill $server_pid 2>/dev/null || true

echo ""
echo "🎉 Setup Complete!"
echo ""
echo "Next steps:"
echo "1. Install AnkiConnect add-on in Anki (ID: 2055492159)"
echo "2. Edit anki-voice-server/.env with your OpenAI API key"
echo "3. Start Anki and open a deck for review"
echo "4. Run: cd anki-voice-server && uvicorn app.main:app --host 0.0.0.0 --port 8000"
echo "5. Open anki-voice-ios in Xcode and build for device"
echo ""
echo "Test the system:"
echo "- Visit http://127.0.0.1:8770/current (should show current card)"
echo "- Visit http://127.0.0.1:8000/current (should proxy card data)"
echo ""
echo "For help, see the README files in each directory."

