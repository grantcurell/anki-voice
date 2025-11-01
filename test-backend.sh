#!/bin/bash

# Backend Testing Script for Anki Voice
# This script tests all backend components

echo "🧪 Anki Voice Backend Testing"
echo "============================="

# Test 1: FastAPI Server Health Check
echo ""
echo "1️⃣ Testing FastAPI Server..."
if curl -s http://127.0.0.1:8000/docs > /dev/null; then
    echo "✅ FastAPI server is running and responding"
else
    echo "❌ FastAPI server is not responding"
    echo "   Make sure to start it with: cd anki-voice-server && source venv/bin/activate && uvicorn app.main:app --host 0.0.0.0 --port 8000"
    exit 1
fi

# Test 2: Comprehensive Health Check
echo ""
echo "2️⃣ Running comprehensive health check..."
health_response=$(curl -s http://127.0.0.1:8000/health)
echo "Health Status:"
echo "$health_response" | python3 -m json.tool 2>/dev/null || echo "$health_response"

# Extract status from health check
server_status=$(echo "$health_response" | grep -o '"server": "[^"]*"' | cut -d'"' -f4)
anki_status=$(echo "$health_response" | grep -o '"anki_running": "[^"]*"' | cut -d'"' -f4)
addon_status=$(echo "$health_response" | grep -o '"anki_addon": "[^"]*"' | cut -d'"' -f4)
ankiconnect_status=$(echo "$health_response" | grep -o '"ankiconnect": "[^"]*"' | cut -d'"' -f4)

echo ""
echo "📊 Component Status Summary:"
echo "  Server: $server_status"
echo "  Anki Running: $anki_status"
echo "  Anki Add-on: $addon_status"
echo "  AnkiConnect: $ankiconnect_status"

# Test 3: Detailed Component Tests
echo ""
echo "3️⃣ Detailed component tests..."

if [ "$anki_status" = "ok" ]; then
    echo "✅ Anki is running"
else
    echo "❌ Anki is not running"
    echo "   ACTION REQUIRED: Start Anki desktop application"
fi

if [ "$ankiconnect_status" = "ok" ]; then
    echo "✅ AnkiConnect is working"
else
    echo "❌ AnkiConnect is not working"
    echo "   ACTION REQUIRED: Install AnkiConnect add-on (ID: 2055492159) in Anki"
fi

if [ "$addon_status" = "ok" ]; then
    echo "✅ Anki add-on bridge is working"
else
    echo "❌ Anki add-on bridge is not working"
    echo "   ACTION REQUIRED: Make sure Anki is open with a card ready for review"
fi

# Test 4: API Endpoints (only if components are working)
echo ""
echo "4️⃣ Testing API endpoints..."

if [ "$addon_status" = "ok" ]; then
    echo "Testing /current endpoint..."
    current_response=$(curl -s http://127.0.0.1:8000/current)
    if echo "$current_response" | grep -q "status"; then
        echo "✅ /current endpoint working"
        echo "Response: $current_response"
    else
        echo "❌ /current endpoint failed"
    fi
else
    echo "⚠️ Skipping /current test - add-on not working"
fi

# Test 5: Grading System
echo ""
echo "5️⃣ Testing Grading System..."
grading_response=$(curl -s -X POST http://127.0.0.1:8000/grade \
  -H "Content-Type: application/json" \
  -d '{
    "cardId": 123,
    "transcript": "there are three: embb, urllc, and mmtc",
    "question_text": "How many SNASSI settings are there?",
    "reference_text": "Three: enhanced mobile broadband, ultra reliable low latency, massive machine type"
  }' 2>/dev/null)

if echo "$grading_response" | grep -q "verdict"; then
    echo "✅ Grading system is working"
    echo "Response: $grading_response"
else
    echo "❌ Grading system failed"
    echo "Response: $grading_response"
fi

echo ""
echo "🎉 Backend testing complete!"
echo ""
echo "📋 Next Steps:"
if [ "$anki_status" != "ok" ]; then
    echo "1. Start Anki desktop application"
fi
if [ "$ankiconnect_status" != "ok" ]; then
    echo "2. Install AnkiConnect add-on (Tools → Add-ons → Get Add-ons → Code: 2055492159)"
fi
if [ "$addon_status" != "ok" ]; then
    echo "3. Open a deck in Anki and get to a card ready for review"
fi
echo "4. Run this test again: ./test-backend.sh"
echo "5. Once all components are green, you can test with the iOS app"
