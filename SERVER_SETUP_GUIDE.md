# Anki Voice Server Setup Guide

## Quick Start

### Option A: Manual Start (Development)
```bash
cd anki-voice-server
make dev  # or: uvicorn app.main:app --host 0.0.0.0 --port 8000 --reload
```

### Option B: Login Item (Simple Auto-Start)
1. Make script executable (already done):
   ```bash
   chmod +x anki-voice-server/start-anki-voice.sh
   ```
2. Add to System Settings → General → Login Items
   - Drag `anki-voice-server/start-anki-voice.sh` into Login Items
   - Or use the `+` button and navigate to the script

### Option C: launchd Service (Auto-Restart on Crash)
```bash
# Copy plist to LaunchAgents
cp anki-voice-server/dev.jeet.ankivoice.plist ~/Library/LaunchAgents/

# Load and start the service
launchctl load ~/Library/LaunchAgents/dev.jeet.ankivoice.plist
launchctl start dev.jeet.ankivoice

# Check status
launchctl list | grep ankivoice

# View logs
tail -f /tmp/ankivoice.out /tmp/ankivoice.err

# To stop
launchctl unload ~/Library/LaunchAgents/dev.jeet.ankivoice.plist
```

**Note:** Edit the plist to use your actual Python/uvicorn paths:
- Run `which uvicorn` to find the path
- Update `<string>/usr/local/bin/uvicorn</string>` accordingly
- If using venv, set `WorkingDirectory` and ensure `PATH` includes venv/bin

## Verification Checklist

### 1. Server is Listening
```bash
# Check if something is listening on port 8000
lsof -nP -iTCP:8000 -sTCP:LISTEN

# Alternative check
netstat -an | grep '\.8000 .*LISTEN'
```

### 2. Server Bound to All Interfaces
```bash
# Should show 0.0.0.0:8000 or *:8000 (not just 127.0.0.1:8000)
lsof -nP -iTCP:8000 -sTCP:LISTEN | grep 0.0.0.0
```

### 3. Reachable via Tailscale IP
```bash
# From the Mac itself:
curl -sS http://100.101.120.23:8000/health

# Via MagicDNS:
curl -sS http://grants-macbook-air.tail73fcb8.ts.net:8000/health
```

### 4. Tailscale Connectivity
```bash
# Check Tailscale status
tailscale status | grep -i grants-macbook-air

# Confirm Tailscale IP
tailscale ip -4

# Test connectivity
tailscale ping 100.101.120.23
```

### 5. macOS Firewall
- **System Settings → Network → Firewall**
- Either temporarily disable for testing
- Or ensure Python/uvicorn is allowed:
  ```bash
  /usr/libexec/ApplicationFirewall/socketfilterfw --listapps
  ```
- When starting server, if macOS asks "Allow incoming connections?", choose **Allow**

## Troubleshooting

### Connection Refused (-1004)
- **Cause:** Server process not running
- **Fix:** Start the server using one of the methods above

### Port Already in Use
```bash
# Find what's using port 8000
lsof -nP -i:8000

# Kill if needed (replace PID)
kill <PID>
```

### Firewall Blocking
- Check System Settings → Network → Firewall
- Ensure Python/uvicorn is in allowed apps
- Try temporarily disabling firewall for test

### Tailscale DNS Not Resolving
```bash
# Verify DNS resolution
dig +short grants-macbook-air.tail73fcb8.ts.net

# Should return: 100.101.120.23
```

### Binding Issue
- If server only listens on 127.0.0.1, explicitly bind to Tailscale IP:
  ```bash
  uvicorn app.main:app --host 100.101.120.23 --port 8000
  ```
- Then verify with `lsof` it's listening on that IP

## Smoke Test Sequence

1. **Start server** (Option A, B, or C above)
2. **Verify on Mac:**
   ```bash
   curl http://100.101.120.23:8000/health
   # Should return: {"server":"ok",...}
   ```
3. **Verify DNS:**
   ```bash
   dig +short grants-macbook-air.tail73fcb8.ts.net
   # Should return: 100.101.120.23
   ```
4. **Test on iPhone:**
   - Open app
   - Health status should show "Connected"
   - Tap "Start Review" - should work

## Common Failure Modes

| Symptom | Diagnosis | Fix |
|---------|-----------|-----|
| curl to TS IP fails | Server not bound or firewall | Check binding, firewall settings |
| curl works, DNS fails | MagicDNS mismatch | Verify device name in Tailscale |
| Both work on Mac, iPhone fails | Tailscale session stale | Toggle Tailscale off/on |
| Intermittent failures | Mac went to sleep | Use launchd KeepAlive or restart server |

