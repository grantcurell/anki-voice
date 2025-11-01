#!/bin/bash

# Anki Voice System Setup Script for macOS with Virtual Environments
# This script sets up the complete Anki Voice system using Python 3.12 virtual environments

echo "🍎 Anki Voice System Setup (macOS + Python 3.12)"
echo "================================================"

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

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    echo "❌ Homebrew not found. Please install Homebrew first:"
    echo "   /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
    exit 1
fi

# Install Python 3.12 if not already installed
if ! /opt/homebrew/bin/python3.12 --version &> /dev/null; then
    echo "📦 Installing Python 3.12..."
    brew install python@3.12
else
    echo "✅ Python 3.12 already installed"
fi

echo "🐍 Python version: $(/opt/homebrew/bin/python3.12 --version)"

# Setup server virtual environment
echo ""
echo "📦 Setting up server virtual environment..."
cd anki-voice-server

if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    /opt/homebrew/bin/python3.12 -m venv venv
fi

echo "Activating virtual environment and installing dependencies..."
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt

echo "✅ Server virtual environment setup complete"

# Create .env file if it doesn't exist
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

# Test server imports
echo "🧪 Testing server setup..."
if python -c "from app.main import app; print('✅ Server imports successfully')" 2>/dev/null; then
    echo "✅ Server test successful"
else
    echo "❌ Server test failed"
    exit 1
fi

# Setup bridge virtual environment (for consistency)
echo ""
echo "📦 Setting up bridge virtual environment..."
cd ../anki-voice-bridge

if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    /opt/homebrew/bin/python3.12 -m venv venv
fi

echo "✅ Bridge virtual environment setup complete"

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
cp __init__.py "$addon_dest/"

echo "✅ Add-on installed to: $addon_dest"

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
echo "   source venv/bin/activate"
echo "   uvicorn app.main:app --host 0.0.0.0 --port 8000"
echo ""
echo "4. Build iOS app:"
echo "   - Open anki-voice-ios/ in Xcode"
echo "   - Add 'Speech Recognition' capability"
echo "   - Build and run on device (not simulator)"
echo ""
echo "Quick start commands:"
echo "  cd anki-voice-server && ./activate.sh"
echo ""
echo "Test the system:"
echo "- Start Anki and open a deck for review"
echo "- Visit http://127.0.0.1:8770/current (should show current card)"
echo "- Visit http://127.0.0.1:8000/current (should proxy card data)"
echo ""
echo "For help, see the README files in each directory."

