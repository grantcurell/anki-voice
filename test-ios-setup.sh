#!/bin/bash

# Quick setup and test script for iOS app testing

echo "🚀 Anki Voice iOS Testing Setup"
echo "=================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Get Mac IP address
MAC_IP=$(ifconfig | grep "inet " | grep -v 127.0.0.1 | awk '{print $2}' | head -1)

echo "📱 Step 1: Checking Prerequisites"
echo "-----------------------------------"

# Check if Anki is running
if pgrep -x "anki" > /dev/null; then
    echo -e "${GREEN}✓${NC} Anki is running"
else
    echo -e "${YELLOW}⚠${NC}  Anki is not running. Please start Anki Desktop."
fi

# Check if server directory exists
if [ -d "anki-voice-server" ]; then
    echo -e "${GREEN}✓${NC} Server directory exists"
else
    echo -e "${RED}✗${NC} Server directory not found"
    exit 1
fi

# Check if venv exists
if [ -d "anki-voice-server/venv" ]; then
    echo -e "${GREEN}✓${NC} Virtual environment exists"
else
    echo -e "${YELLOW}⚠${NC}  Virtual environment not found. Run ./setup-venv.sh first"
fi

# Check for .env file
if [ -f "anki-voice-server/.env" ]; then
    echo -e "${GREEN}✓${NC} .env file exists"
else
    echo -e "${YELLOW}⚠${NC}  .env file missing"
    if [ -f "secrets" ]; then
        echo "   Copying secrets to .env..."
        cp secrets anki-voice-server/.env
        echo -e "${GREEN}✓${NC} Created .env from secrets"
    else
        echo -e "${RED}✗${NC} No secrets file found. Please create anki-voice-server/.env with OPENAI_API_KEY"
    fi
fi

echo ""
echo "🌐 Step 2: Network Information"
echo "-----------------------------------"
echo "Your Mac's IP address: ${GREEN}${MAC_IP}${NC}"
echo ""
echo "Update the server URL in the iOS app to: ${GREEN}http://${MAC_IP}:8000${NC}"
echo ""

echo "🔧 Step 3: Starting Services"
echo "-----------------------------------"

# Check if server is already running
if lsof -Pi :8000 -sTCP:LISTEN -t >/dev/null ; then
    echo -e "${YELLOW}⚠${NC}  Port 8000 is already in use. Server might already be running."
    echo "   To restart, kill the process first: lsof -ti:8000 | xargs kill"
else
    echo "Starting FastAPI server..."
    echo ""
    echo "Run this command in a separate terminal:"
    echo ""
    echo "  cd anki-voice-server"
    echo "  source venv/bin/activate"
    echo "  uvicorn app.main:app --host 0.0.0.0 --port 8000"
    echo ""
fi

echo "🧪 Step 4: Testing Services"
echo "-----------------------------------"

# Test Anki add-on
echo -n "Testing Anki add-on (port 8770)... "
if curl -s http://127.0.0.1:8770/ping > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Add-on is responding"
else
    echo -e "${RED}✗${NC} Add-on not responding"
    echo "   Make sure Anki is open with a card ready for review"
fi

# Test FastAPI server
echo -n "Testing FastAPI server (port 8000)... "
if curl -s http://127.0.0.1:8000/health > /dev/null 2>&1; then
    echo -e "${GREEN}✓${NC} Server is responding"
    
    # Show health status
    echo ""
    echo "Server health status:"
    curl -s http://127.0.0.1:8000/health | python3 -m json.tool 2>/dev/null || curl -s http://127.0.0.1:8000/health
    echo ""
else
    echo -e "${RED}✗${NC} Server not responding"
    echo "   Start the server using the command shown above"
fi

echo "📋 Step 5: Testing from iPhone's Perspective"
echo "-----------------------------------"
if [ -n "$MAC_IP" ]; then
    echo -n "Testing server from network (${MAC_IP})... "
    if curl -s http://${MAC_IP}:8000/health > /dev/null 2>&1; then
        echo -e "${GREEN}✓${NC} Server accessible from network"
    else
        echo -e "${YELLOW}⚠${NC}  Server not accessible from network"
        echo "   This might be normal if server isn't running yet"
        echo "   Or check Mac firewall settings"
    fi
fi

echo ""
echo "✅ Setup Complete!"
echo "=================================="
echo ""
echo "Next steps:"
echo "1. Open Xcode and create/open the iOS project"
echo "2. Build and run on your iPhone"
echo "3. In the app, set server URL to: ${GREEN}http://${MAC_IP}:8000${NC}"
echo "4. Tap 'Authorize STT' and grant permissions"
echo "5. Make sure Anki has a card ready for review"
echo "6. Tap 'Start Review'"
echo ""
echo "For detailed instructions, see: anki-voice-ios/TESTING.md"
echo ""

