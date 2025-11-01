#!/bin/bash

# Anki Voice System Setup Script for macOS
# This script helps set up the complete Anki Voice system on macOS

echo "🍎 Anki Voice System Setup (macOS)"
echo "=================================="

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
echo "🐍 Python version: $python_version"
if [[ $(echo "$python_version >= 3.9" | bc -l) -eq 0 ]]; then
    echo "❌ Python 3.9+ required, found $python_version"
    echo "   Please install a newer Python version"
    exit 1
fi

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
pip3 install fastapi "uvicorn[standard]" httpx python-dotenv beautifulsoup4 pydantic

echo "✅ Server setup complete"

# Check Anki installation
echo ""
echo "🔍 Checking Anki installation..."
anki_path="$HOME/Library/Application Support/Anki2/addons21"

if [ ! -d "$anki_path" ]; then
    echo "❌ Anki add-ons directory not found at: $anki_path"
    echo "   Please install Anki first from https://apps.ankiweb.net/"
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
echo "Testing server imports..."
if python3 -c "from app.main import app; print('✅ Server imports successfully')" 2>/dev/null; then
    echo "✅ Server test successful"
else
    echo "❌ Server test failed - check dependencies"
    exit 1
fi

echo ""
echo "🎉 Setup Complete!"
echo ""
echo "Next steps:"
echo "1. Install AnkiConnect add-on in Anki:"
echo "   - Open Anki → Tools → Add-ons → Get Add-ons"
echo "   - Enter code: 2055492159"
echo "   - Restart Anki"
echo ""
echo "2. Configure OpenAI API:"
echo "   - Edit anki-voice-server/.env with your OpenAI API key"
echo ""
echo "3. Start the server:"
echo "   cd anki-voice-server"
echo "   python3 -m uvicorn app.main:app --host 0.0.0.0 --port 8000"
echo ""
echo "4. Build iOS app:"
echo "   - Open anki-voice-ios/ in Xcode"
echo "   - Add 'Speech Recognition' capability"
echo "   - Build and run on device (not simulator)"
echo ""
echo "Test the system:"
echo "- Start Anki and open a deck for review"
echo "- Visit http://127.0.0.1:8770/current (should show current card)"
echo "- Visit http://127.0.0.1:8000/current (should proxy card data)"
echo ""
echo "For help, see the README files in each directory."

