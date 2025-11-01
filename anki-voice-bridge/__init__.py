from aqt import mw, gui_hooks
import json, os, traceback, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from socketserver import ThreadingMixIn
from datetime import datetime

ADDON_DIR = mw.addonManager.addonsFolder(__name__)
LOG_PATH = os.path.join(ADDON_DIR, "anki_voice_bridge.log")

def log(msg: str):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"{datetime.now().isoformat(timespec='seconds')} | {msg}\n")
    except Exception:
        pass

def run_on_main_and_wait(fn, *args, **kwargs):
    done = threading.Event()
    out = {"res": None, "err": None}
    def _runner():
        try:
            out["res"] = fn(*args, **kwargs)
        except Exception as e:
            out["err"] = e
        finally:
            done.set()
    mw.taskman.run_on_main(_runner)
    done.wait()
    if out["err"]:
        raise out["err"]
    return out["res"]

def _read_current_card_on_ui():
    r = mw.reviewer
    c = getattr(r, "card", None)
    if not c:
        return {"status": "idle"}
    front_html = r._mungeQA(c.q())
    back_html  = r._mungeQA(c.a())
    return {
        "status": "ok",
        "cardId": c.id,
        "noteId": c.nid,
        "deckId": c.did,
        "front_html": front_html,
        "back_html": back_html,
    }

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a, **k):  # silence default stdout logging
        pass
    def _json(self, payload, code=200):
        data = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        try:
            if self.path == "/ping":
                self._json({"ok": True})
                return
            if self.path == "/current":
                payload = run_on_main_and_wait(_read_current_card_on_ui)
                self._json(payload)
                return
            self._json({"error": "not found"}, 404)
        except Exception as e:
            log(f"handler error: {e}\n{traceback.format_exc()}")
            try:
                self._json({"error":"internal"}, 500)
            except Exception:
                pass

class ThreadingHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

_srv = None
_srv_thread = None

def _start_server():
    global _srv, _srv_thread
    if _srv:
        return
    try:
        _srv = ThreadingHTTPServer(("127.0.0.1", 8770), Handler)
    except OSError:
        _srv = ThreadingHTTPServer(("127.0.0.1", 8771), Handler)
        log("8770 busy, using 8771")
    def _serve():
        addr, port = _srv.server_address
        log(f"Serving on http://{addr}:{port}")
        _srv.serve_forever(poll_interval=0.5)
    _srv_thread = threading.Thread(target=_serve, name="anki_voice_http", daemon=True)
    _srv_thread.start()
    log("HTTP server started")

def _stop_server():
    global _srv, _srv_thread
    if _srv:
        try:
            _srv.shutdown()
            _srv.server_close()
        except Exception as e:
            log(f"shutdown error: {e}")
    _srv = None
    _srv_thread = None
    log("HTTP server stopped")

def _on_profile_open():
    log("profile_did_open -> starting server")
    _start_server()

def _on_profile_will_close():
    log("profile_will_close -> stopping server")
    _stop_server()

gui_hooks.profile_did_open.append(_on_profile_open)
gui_hooks.profile_will_close.append(_on_profile_will_close)