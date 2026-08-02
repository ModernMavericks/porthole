"""Minimal synchronous Chrome DevTools Protocol client over one WebSocket."""
import json
import itertools
import websocket  # from websocket-client


class CDP:
    def __init__(self, ws_url, timeout=10):
        self._ws = websocket.create_connection(ws_url, timeout=timeout)
        self._ids = itertools.count(1)
        self._events = []  # (method, params) seen while awaiting replies

    def send(self, method, params=None):
        """Send a command, block for its reply, return the 'result' dict.
        Events that arrive before the reply are buffered for drain_events()."""
        mid = next(self._ids)
        self._ws.send(json.dumps({"id": mid, "method": method,
                                  "params": params or {}}))
        while True:
            msg = json.loads(self._ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg.get("result", {})
            if "method" in msg:
                self._events.append((msg["method"], msg.get("params", {})))

    def pump(self, seconds):
        """Passively collect events for a fixed window (used to let paints settle)."""
        self._ws.settimeout(seconds)
        try:
            while True:
                msg = json.loads(self._ws.recv())
                if "method" in msg:
                    self._events.append((msg["method"], msg.get("params", {})))
        except Exception:
            pass  # timeout ends the window
        finally:
            self._ws.settimeout(None)

    def drain_events(self, method=None):
        """Return buffered events (optionally filtered by method) and clear them."""
        if method is None:
            out = list(self._events)
            self._events.clear()
            return out
        out = [(m, p) for (m, p) in self._events if m == method]
        self._events = [(m, p) for (m, p) in self._events if m != method]
        return out

    def close(self):
        try:
            self._ws.close()
        except Exception:
            pass
