#!/usr/bin/env python3
"""
input-server.py
Receives mouse/keyboard events from the browser (WebSocket) and injects them into
Weston's Xwayland display using XTEST. It never touches your host desktop, because
it only talks to the X display that belongs to Weston.

It also serves remote.html at http://<host>:8090/

Deps:  Arch:   sudo pacman -S python-xlib python-aiohttp
       Debian: sudo apt install python3-xlib python3-aiohttp

Usage: ./input-server.py --display :1 [--host 0.0.0.0] [--port 8090] [--token SECRET]
       (if --display is omitted it is read from /tmp/weston-xdisplay)
"""
import argparse
import json
import os
import sys
from pathlib import Path

from aiohttp import web, WSMsgType
from Xlib import X, XK, display as xdisplay
from Xlib.ext import xtest

HERE = Path(__file__).resolve().parent

# JS KeyboardEvent.key  ->  X keysym name
SPECIAL_KEYS = {
    "Enter": "Return", "Backspace": "BackSpace", "Tab": "Tab", "Escape": "Escape",
    "Delete": "Delete", "Insert": "Insert", "Home": "Home", "End": "End",
    "PageUp": "Prior", "PageDown": "Next",
    "ArrowLeft": "Left", "ArrowRight": "Right", "ArrowUp": "Up", "ArrowDown": "Down",
    "Shift": "Shift_L", "Control": "Control_L", "Alt": "Alt_L", "AltGraph": "ISO_Level3_Shift",
    "Meta": "Super_L", "CapsLock": "Caps_Lock", "ContextMenu": "Menu",
    " ": "space",
}
for i in range(1, 13):
    SPECIAL_KEYS[f"F{i}"] = f"F{i}"

JS_BUTTON_TO_X = {0: 1, 1: 2, 2: 3}  # left, middle, right


class Injector:
    def __init__(self, display_name):
        self.name = display_name
        self.d = None
        self.root = None
        self.w = self.h = 0
        self.down_keys = set()
        self.down_buttons = set()

    def connect(self):
        self.d = xdisplay.Display(self.name)
        screen = self.d.screen()
        self.root = screen.root
        self.w, self.h = screen.width_in_pixels, screen.height_in_pixels
        if not self.d.has_extension("XTEST"):
            raise RuntimeError("X server has no XTEST extension")
        print(f"[input] connected to {self.name} ({self.w}x{self.h})", flush=True)

    def _fake(self, ev, detail=0, x=0, y=0):
        xtest.fake_input(self.d, ev, detail=detail, root=self.root, x=x, y=y)

    def move(self, nx, ny):
        x = int(min(max(nx, 0.0), 1.0) * (self.w - 1))
        y = int(min(max(ny, 0.0), 1.0) * (self.h - 1))
        self._fake(X.MotionNotify, 0, x, y)

    def button(self, js_button, pressed):
        b = JS_BUTTON_TO_X.get(js_button)
        if not b:
            return
        self._fake(X.ButtonPress if pressed else X.ButtonRelease, b)
        (self.down_buttons.add if pressed else self.down_buttons.discard)(b)

    def wheel(self, dx, dy):
        def clicks(delta):
            return max(1, min(5, round(abs(delta) / 100)))
        if dy:
            b = 5 if dy > 0 else 4
            for _ in range(clicks(dy)):
                self._fake(X.ButtonPress, b); self._fake(X.ButtonRelease, b)
        if dx:
            b = 7 if dx > 0 else 6
            for _ in range(clicks(dx)):
                self._fake(X.ButtonPress, b); self._fake(X.ButtonRelease, b)

    def _keycode(self, key):
        if key in SPECIAL_KEYS:
            keysym = XK.string_to_keysym(SPECIAL_KEYS[key])
        elif len(key) == 1:
            cp = ord(key)
            keysym = cp if cp < 0x100 else 0x01000000 + cp
        else:
            return 0
        return self.d.keysym_to_keycode(keysym) if keysym else 0

    def key(self, key, pressed):
        kc = self._keycode(key)
        if not kc:
            return
        self._fake(X.KeyPress if pressed else X.KeyRelease, kc)
        (self.down_keys.add if pressed else self.down_keys.discard)(kc)

    def release_all(self):
        """Avoid stuck keys/buttons if the browser disconnects."""
        try:
            for kc in list(self.down_keys):
                self._fake(X.KeyRelease, kc)
            for b in list(self.down_buttons):
                self._fake(X.ButtonRelease, b)
            self.down_keys.clear(); self.down_buttons.clear()
            self.d.flush()
        except Exception:
            pass

    def _winname(self, win):
        """Best-effort readable name of an X window (class or title)."""
        if not hasattr(win, "get_wm_class"):
            return {0: "None", 1: "PointerRoot"}.get(win, str(win))
        try:
            c = win.get_wm_class()
            if c:
                return "/".join(c)
            n = win.get_wm_name()
            return str(n) if n else f"id={win.id}"
        except Exception:
            return f"id={getattr(win, 'id', '?')}"

    def info(self):
        """What the X server thinks right now: pointer position, window under it, keyboard focus."""
        qp = self.root.query_pointer()
        return {
            "t": "dbg",
            "pointer": [qp.root_x, qp.root_y],
            "screen": [self.w, self.h],
            "under_pointer": self._winname(qp.child) if qp.child else None,
            "keyboard_focus": self._winname(self.d.get_input_focus().focus),
        }

    def handle(self, msg):
        t = msg.get("t")
        if t == "m":
            self.move(msg["x"], msg["y"])
        elif t == "d":
            self.move(msg["x"], msg["y"]); self.button(msg["b"], True)
        elif t == "u":
            self.move(msg["x"], msg["y"]); self.button(msg["b"], False)
        elif t == "w":
            self.wheel(msg.get("dx", 0), msg.get("dy", 0))
        elif t == "kd":
            self.key(msg["k"], True)
        elif t == "ku":
            self.key(msg["k"], False)
        self.d.flush()


def resolve_display(arg):
    if arg:
        return arg
    p = Path("/tmp/weston-xdisplay")
    if p.exists():
        return p.read_text().strip()
    sys.exit("No X display given (--display) and /tmp/weston-xdisplay does not exist")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--display", help="Weston's Xwayland display, e.g. :1")
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8090)
    ap.add_argument("--token", default=os.environ.get("INPUT_TOKEN", ""),
                    help="optional shared secret; the page must be opened with ?token=SECRET")
    ap.add_argument("--debug", action="store_true",
                    default=os.environ.get("INPUT_DEBUG") == "1",
                    help="log every event and send X-side diagnostics back to the page")
    ap.add_argument("--selftest", action="store_true",
                    help="inject a mouse move + click without any browser, then exit")
    args = ap.parse_args()

    inj = Injector(resolve_display(args.display))
    inj.connect()

    if args.selftest:
        print("[selftest] before:", inj.info(), flush=True)
        inj.handle({"t": "m", "x": 0.5, "y": 0.5})
        print("[selftest] after move to center:", inj.info(), flush=True)
        inj.handle({"t": "d", "x": 0.5, "y": 0.5, "b": 0})
        inj.handle({"t": "u", "x": 0.5, "y": 0.5, "b": 0})
        print("[selftest] clicked at center. Did the app react?", flush=True)
        return

    async def index(_):
        return web.FileResponse(HERE / "remote.html")

    async def ws_handler(request):
        if args.token and request.query.get("token") != args.token:
            return web.Response(status=403, text="bad token")
        ws = web.WebSocketResponse(heartbeat=15)
        await ws.prepare(request)
        print(f"[input] client connected: {request.remote}", flush=True)
        moves = 0
        try:
            async for m in ws:
                if m.type == WSMsgType.TEXT:
                    try:
                        msg = json.loads(m.data)
                        if args.debug:
                            if msg.get("t") == "m":
                                moves += 1
                                if moves % 50 == 1:
                                    print(f"[debug] move #{moves}: {m.data}", flush=True)
                            else:
                                print(f"[debug] {m.data}", flush=True)
                        inj.handle(msg)
                        if args.debug and msg.get("t") in ("d", "kd"):
                            await ws.send_str(json.dumps(inj.info()))
                    except (KeyError, ValueError) as e:
                        if args.debug:
                            print(f"[debug] bad message {m.data!r}: {e!r}", flush=True)
                    except Exception as e:  # X connection lost etc.
                        print(f"[input] error: {e}; reconnecting", flush=True)
                        try:
                            inj.connect()
                        except Exception as e2:
                            print(f"[input] reconnect failed: {e2}", flush=True)
        finally:
            inj.release_all()
            print(f"[input] client disconnected: {request.remote}", flush=True)
        return ws

    app = web.Application()
    app.add_routes([web.get("/", index), web.get("/ws", ws_handler)])
    print(f"[input] UI + input on http://{args.host}:{args.port}/", flush=True)
    if not args.token and args.host != "127.0.0.1":
        print("[input] WARNING: anyone who can reach this port can control the app. "
              "Use --token or --host 127.0.0.1", flush=True)
    web.run_app(app, host=args.host, port=args.port, print=None)


if __name__ == "__main__":
    main()