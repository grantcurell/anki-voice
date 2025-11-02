# Bug Report: Server Connection Refused (-1004 / ECONNREFUSED)

## Problem Summary

The iOS app cannot connect to the FastAPI server despite:
- Server URL correctly configured: `http://grants-macbook-air.tail73fcb8.ts.net:8000`
- Anki Desktop is open and running
- Tailscale VPN is active on both devices
- Server is configured to listen on `0.0.0.0:8000` (all interfaces)

**Error:** Connection refused (ECONNREFUSED, error code 61 / URLError -1004)

## Error Details

### Error Message
```
Error Domain=NSURLErrorDomain Code=-1004 "Could not connect to the server."
_kCFStreamErrorCodeKey=61
```

### Network Logs
```
tcp_input [C1.1.1:2] flags=[R.] seq=0, ack=1630307261, win=0 state=SYN_SENT rcv_nxt=0, snd_una=1630307260
nw_endpoint_flow_failed_with_error [C1.1.1 100.101.120.23:8000 in_progress channel-flow (satisfied (Path is satisfied), viable, interface: utun4[lte], ipv4, ipv6, dns, uses cell)] already failing, returning
Connection 1: failed to connect 1:61, reason -1
Connection 1: encountered error(1:61)
```

**Key observations:**
- The connection is reaching the target IP: `100.101.120.23:8000`
- TCP SYN packet is being sent but immediately receiving RST (reset)
- Path is satisfied (Tailscale routing is working)
- Interface shows `utun4[lte]` (Tailscale VPN interface)
- Error code 61 = ECONNREFUSED (nothing listening on that port)

## Configuration

### Server Configuration (`anki-voice-server/app/main.py`)
```python
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
```

### iOS App Configuration
- **Server URL:** `http://grants-macbook-air.tail73fcb8.ts.net:8000`
- **URL Validation:** Passes (validatedBaseURL returns the URL)
- **ATS Exception:** Configured for `*.tail73fcb8.ts.net` in Debug build

### Network Setup
- **Tailscale MagicDNS:** Enabled
- **Device name:** `grants-macbook-air.tail73fcb8.ts.net`
- **Tailscale IP:** `100.101.120.23`
- **VPN Status:** Active on both iPhone and Mac

## Diagnostic Checks Performed

1. **Server Process Check:**
   ```bash
   lsof -i :8000
   # Result: No process found on port 8000
   ```

2. **Port Listening Check:**
   ```bash
   netstat -an | grep 8000
   # Result: No listeners on port 8000
   ```

3. **Server Startup:**
   - Server can be started manually with `uvicorn app.main:app --host 0.0.0.0 --port 8000`
   - When running, connection succeeds
   - **Issue:** Server is not currently running

## Root Cause Hypothesis

The error logs indicate:
1. **Network routing is working** - iPhone can reach the Mac's Tailscale IP
2. **TCP connection is being attempted** - SYN packets are sent
3. **Connection is immediately refused** - RST packets received
4. **Error code 61** = ECONNREFUSED = nothing is listening on port 8000

**Most likely cause:** The FastAPI server process is not running on the Mac.

## Questions for Expert

1. **Why might the server not be running?**
   - Is there a way to verify if it crashed or was never started?
   - Could there be a port conflict preventing it from binding?
   - Should we check for any background process management (launchd, systemd, etc.)?

2. **Network diagnostics:**
   - The logs show `interface: utun4[lte]` - is this the expected Tailscale interface?
   - Should we verify Tailscale connectivity with `tailscale ping`?
   - Could there be a firewall rule blocking port 8000?

3. **Server binding verification:**
   - When `host="0.0.0.0"` is set, should we verify it's actually binding to all interfaces?
   - Could the server be binding only to `127.0.0.1` despite the configuration?
   - Should we check `ss -tlnp | grep 8000` or equivalent on macOS?

4. **Tailscale-specific considerations:**
   - Are there any Tailscale ACLs or subnet routes that might affect connectivity?
   - Should we test connectivity from the Mac itself: `curl http://100.101.120.23:8000/health`?
   - Could MagicDNS be resolving correctly but the IP not be routable?

5. **Alternative diagnostic steps:**
   - Should we try connecting via direct IP instead of MagicDNS hostname?
   - Should we check if the server binds successfully when started?
   - Should we verify Python environment and dependencies are correct?

## Code Context

### Server Health Check (`checkServerHealth()`)
```swift
private func checkServerHealth() async {
    guard let base = validatedBaseURL(), let url = URL(string: "\(base)/health") else {
        await MainActor.run { self.serverHealthStatus = nil }
        return
    }
    
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 1.0
    config.timeoutIntervalForResource = 1.5
    let session = URLSession(configuration: config)
    
    do {
        let (_, response) = try await session.data(from: url)
        let ok = (response as? HTTPURLResponse)?.statusCode == 200
        await MainActor.run {
            self.serverHealthStatus = ok ? "Connected" : "Server unreachable"
        }
    } catch {
        await MainActor.run {
            self.serverHealthStatus = "Server unreachable"
        }
    }
}
```

### Start Review Error Handling
```swift
} catch {
    // Network error fetching /current
    // Error code -1004 detected but not catching properly
}
```

## Expected Behavior

When the server is running:
1. Health check should succeed and show "Connected"
2. Start Review should fetch `/current` endpoint successfully
3. TCP connection should complete (SYN → SYN-ACK → ACK)

## Actual Behavior

1. Health check fails with -1004 error
2. Start Review fails with -1004 error
3. TCP connection receives immediate RST (connection refused)

## Steps to Reproduce

1. Ensure Tailscale VPN is active on both devices
2. Configure iOS app with server URL: `http://grants-macbook-air.tail73fcb8.ts.net:8000`
3. Open Anki Desktop on Mac
4. Tap "Start Review" in iOS app
5. Observe connection refused error

## Environment

- **iOS Device:** iPhone (cellular/LTE interface active)
- **Mac:** Running macOS (Tailscale IP: 100.101.120.23)
- **Tailscale Network:** tail73fcb8.ts.net
- **Server URL:** http://grants-macbook-air.tail73fcb8.ts.net:8000
- **Python Version:** 3.12.12
- **Server Framework:** FastAPI with uvicorn

## Additional Notes

- The error occurs consistently when the server process is not running
- When the server IS running, connections succeed
- The issue appears to be operational (server not started) rather than code-related
- However, we want to verify:
  - Is the server supposed to auto-start somehow?
  - Are there any firewall/security settings blocking it?
  - Could there be a configuration issue preventing it from binding to 0.0.0.0?

