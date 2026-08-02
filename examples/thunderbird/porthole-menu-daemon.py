#!/usr/bin/env python3
"""Porthole container-side AT-SPI menu daemon.

Walks a GTK/Qt app's AT-SPI menu tree and streams a normalized menu model +
live state deltas over /run/user/1000/porthole-menu.sock to the Mac viewer (the spine's
PortholeRemoteMenuProducer). Split into a PURE CORE (no platform imports, unit-tested)
and a pyatspi+GLib ADAPTER (added in Task 3, imported lazily in main()).
"""
import json
import re

# ---- pure core --------------------------------------------------------------

_MODS = {"<Primary>": "cmd", "<Control>": "ctrl", "<Ctrl>": "ctrl",
         "<Shift>": "shift", "<Alt>": "alt", "<Super>": "cmd", "<Meta>": "cmd"}


def parse_keybinding(kb):
    """AT-SPI getKeyBinding string -> {key, mods} or None.

    The string is ';'-separated (mnemonic;<Alt>path;<accel>); the ACCELERATOR is
    always the LAST field (an empty last field = mnemonic only = no accelerator).
    Modifier tokens are <...>; the remainder is the key.
    """
    if not kb:
        return None
    parts = kb.split(";")
    # The accelerator is always the last ';'-separated field.
    # If there are no semicolons the whole string is treated as the accelerator.
    field = parts[-1].strip()
    if not field:
        return None
    mods = []
    for tok in re.findall(r"<[^>]+>", field):
        m = _MODS.get(tok)
        if m and m not in mods:
            mods.append(m)
    key = re.sub(r"<[^>]+>", "", field).strip().lower()
    if not key:
        return None
    return {"key": key, "mods": mods}


class IdGen:
    """Stable integer ids keyed by a view's `.key`, reversible for invoke."""
    def __init__(self):
        self._by_key = {}      # view.key -> id
        self._view_by_id = {}  # id -> view
        self._n = 0

    def id_for(self, view):
        k = view.key
        if k not in self._by_key:
            self._n += 1
            self._by_key[k] = self._n
        nid = self._by_key[k]
        self._view_by_id[nid] = view
        return nid

    def view_for_id(self, nid):
        return self._view_by_id.get(nid)


def _is_separator(role):
    return role == "separator"


def build_node(view, idg):
    """One duck-typed view -> a spine node dict (recursive)."""
    role = view.role
    nid = idg.id_for(view)
    if _is_separator(role):
        return {"id": nid, "role": "separator"}
    node = {"id": nid, "label": (view.name or "").rstrip(),
            "enabled": bool(view.sensitive), "visible": True}
    if role == "check menu item":
        node["role"] = "checkbox"
        node["checked"] = bool(view.checked)
    elif role == "radio menu item":
        node["role"] = "radio"
        node["checked"] = bool(view.checked)
    elif role == "menu":
        # A "menu" is a submenu. If the app already materialized its items, emit
        # them inline; if not (Gecko/GTK build them lazily on open), emit a lazy
        # submenu whose children arrive via t:open -> subtree.
        kids = [build_node(c, idg) for c in view.children]
        node["role"] = "submenu"
        if kids:
            node["children"] = kids
        else:
            node["lazy"] = True
    else:
        kids = [build_node(c, idg) for c in view.children]
        if kids:
            node["role"] = "submenu"
            node["children"] = kids
        else:
            node["role"] = "item"
    accel = parse_keybinding(view.keybinding)
    if accel:
        node["accel"] = accel
    return node


def build_snapshot(top_views, idg):
    """List of top-level menu views -> list of node dicts (the wire `root`)."""
    return [build_node(v, idg) for v in top_views]


def delta_for(nid, enabled=None, checked=None, label=None):
    """Build one delta change dict; only include keys that were passed."""
    d = {"id": nid}
    if enabled is not None:
        d["enabled"] = bool(enabled)
    if checked is not None:
        d["checked"] = bool(checked)
    if label is not None:
        d["label"] = label
    return d


def encode_line(obj):
    """JSON object -> newline-terminated UTF-8 bytes (the wire frame)."""
    return (json.dumps(obj) + "\n").encode("utf-8")


# ---- pyatspi adapter + GLib server (runs only in-container; see main()) ------

_ATSPI_MENU_ROLES = ("menu", "menu item", "check menu item",
                     "radio menu item", "separator")


class AtspiView:
    """Adapts a pyatspi Accessible to the duck-typed view the pure core wants."""
    def __init__(self, acc, pyatspi):
        self._acc = acc
        self._p = pyatspi
        self.key = self._path(acc)

    def _path(self, acc):
        # stable identity: app name + index-path from the app root
        parts = []
        a = acc
        try:
            while a is not None and a.getRoleName() != "application":
                parts.append(str(a.getIndexInParent()))
                a = a.parent
            appname = (a.name if a is not None else "") or ""
        except Exception:
            appname = ""
        return appname + "/" + "/".join(reversed(parts))

    @property
    def role(self):
        try:
            return self._acc.getRoleName()
        except Exception:
            return "unknown"

    @property
    def name(self):
        try:
            return self._acc.name or ""
        except Exception:
            return ""

    @property
    def sensitive(self):
        try:
            return self._acc.getState().contains(self._p.STATE_SENSITIVE)
        except Exception:
            return True

    @property
    def checked(self):
        try:
            return self._acc.getState().contains(self._p.STATE_CHECKED)
        except Exception:
            return False

    @property
    def keybinding(self):
        try:
            act = self._acc.queryAction()
            for i in range(act.nActions):
                kb = act.getKeyBinding(i)
                if kb:
                    return kb
        except Exception:
            pass
        return None

    @property
    def children(self):
        out = []
        try:
            for i in range(self._acc.childCount):
                c = self._acc.getChildAtIndex(i)
                if c is not None and c.getRoleName() in _ATSPI_MENU_ROLES:
                    out.append(AtspiView(c, self._p))
        except Exception:
            pass
        return out

    def do_click(self):
        try:
            act = self._acc.queryAction()
            for i in range(act.nActions):
                if (act.getName(i) or "").lower() in ("click", "press", ""):
                    act.doAction(i)
                    return True
            if act.nActions:
                act.doAction(0)
                return True
        except Exception:
            pass
        return False


def find_menu_bar(pyatspi):
    """Walk the AT-SPI desktop for the first ROLE_MENU_BAR; return its accessible,
    or None if none found."""
    desk = pyatspi.Registry.getDesktop(0)
    def find(acc, depth=0):
        try:
            if acc.getRoleName() == "menu bar":
                return acc
            if depth > 12:
                return None
            for i in range(acc.childCount):
                r = find(acc.getChildAtIndex(i), depth + 1)
                if r is not None:
                    return r
        except Exception:
            pass
        return None
    for i in range(desk.childCount):
        app = desk.getChildAtIndex(i)
        bar = find(app) if app is not None else None
        if bar is not None:
            return bar
    return None


class MenuServer:
    """Single-GLib-loop AF_UNIX server speaking the menu wire."""
    def __init__(self, sock_path, pyatspi, GLib):
        self._path = sock_path
        self._p = pyatspi
        self._glib = GLib
        self._client = None
        self._idg = None
        self._srv = None
        self._buf = b""

    def start(self):
        import socket
        import os
        try:
            os.unlink(self._path)
        except FileNotFoundError:
            pass
        self._srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._srv.bind(self._path)
        self._srv.listen(1)
        self._srv.setblocking(False)
        self._glib.io_add_watch(self._srv.fileno(), self._glib.IO_IN, self._on_accept)
        self._p.Registry.registerEventListener(self._on_state, "object:state-changed:sensitive")
        self._p.Registry.registerEventListener(self._on_state, "object:state-changed:checked")
        self._p.Registry.registerEventListener(self._on_children, "object:children-changed")

    def _on_accept(self, *_):
        conn, _addr = self._srv.accept()
        conn.setblocking(True)
        if self._client:
            try:
                self._client.close()
            except Exception:
                pass
        self._client = conn
        self._buf = b""
        self._glib.io_add_watch(conn.fileno(), self._glib.IO_IN | self._glib.IO_HUP,
                                self._on_client)
        return True

    def _send(self, obj):
        if not self._client:
            return
        try:
            self._client.sendall(encode_line(obj))
        except Exception:
            self._drop_client()

    def _drop_client(self):
        try:
            self._client.close()
        except Exception:
            pass
        self._client = None

    def _push_menu(self, bar):
        self._idg = IdGen()
        tops = AtspiView(bar, self._p).children
        self._send({"t": "menu", "root": build_snapshot(tops, self._idg)})

    def _snapshot(self, attempt=0):
        # Initial snapshot on hello. The app may still be starting, so POLL for the
        # menu bar (up to ~30s) rather than giving up: only bye if it never appears.
        if self._client is None:
            return False
        bar = find_menu_bar(self._p)
        if bar is not None:
            self._push_menu(bar)
            return False
        if attempt < 30:
            self._glib.timeout_add(1000, lambda: self._snapshot(attempt + 1))
            return False
        self._send({"t": "bye"})
        return False

    def _refresh(self):
        # Menu structure changed (dynamic items). Re-send IF we can find the bar;
        # if it's transiently gone (app churn), KEEP the current menu -- never bye
        # on a refresh, or the menu would flicker away during startup storms.
        self._pending_refresh = False
        if self._client is None:
            return False
        bar = find_menu_bar(self._p)
        if bar is not None:
            self._push_menu(bar)
        return False

    def _on_client(self, fd, cond):
        if cond & self._glib.IO_HUP:
            self._drop_client()
            return False
        try:
            data = self._client.recv(4096)
        except Exception:
            self._drop_client()
            return False
        if not data:
            self._drop_client()
            return False
        self._buf += data
        while b"\n" in self._buf:
            line, self._buf = self._buf.split(b"\n", 1)
            self._handle(line)
        return True

    def _handle(self, line):
        try:
            msg = json.loads(line.decode("utf-8"))
        except Exception:
            return
        t = msg.get("t")
        if t == "hello":
            self._snapshot()
        elif t == "open" and self._idg is not None:
            self._open(msg.get("id"))
        elif t == "invoke" and self._idg is not None:
            v = self._idg.view_for_id(msg.get("id"))
            if v is not None:
                v.do_click()

    def _open(self, nid):
        # Lazy submenu: open the menu so the app populates its items, then walk
        # the now-materialized children and reply with a subtree.
        import os
        import time
        v = self._idg.view_for_id(nid)
        if v is None:
            return
        v.do_click()          # opening a menu is its click/press action
        time.sleep(0.35)      # let the app build the popup
        kids = list(v.children)
        if os.environ.get("PORTHOLE_MENU_DEBUG"):
            import sys
            for c in kids:
                sys.stderr.write("OPEN child role=%r name=%r kids=%d\n"
                                 % (c.role, c.name, len(c.children)))
            sys.stderr.flush()
        children = [build_node(c, self._idg) for c in kids]
        self._send({"t": "subtree", "id": nid, "children": children})

    def _id_of_source(self, source):
        if self._idg is None:
            return None
        key = AtspiView(source, self._p).key
        for nid, view in list(self._idg._view_by_id.items()):
            if view.key == key:
                return nid
        return None

    def _on_state(self, event):
        try:
            nid = self._id_of_source(event.source)
            if nid is None:
                return
            name = event.type.name if hasattr(event.type, "name") else str(event.type)
            if "checked" in name:
                self._send({"t": "delta", "changes": [delta_for(nid, checked=bool(event.detail1))]})
            else:
                self._send({"t": "delta", "changes": [delta_for(nid, enabled=bool(event.detail1))]})
        except Exception:
            pass

    def _on_children(self, event):
        # Dynamic items changed. DEBOUNCE: the app fires storms of these at startup;
        # coalesce them into a single refresh after a quiet moment, and never bye
        # (see _refresh) so a transient no-menu-bar state doesn't drop the menu.
        if self._client is None:
            return
        if not getattr(self, "_pending_refresh", False):
            self._pending_refresh = True
            self._glib.timeout_add(700, self._refresh)


def main():
    import sys
    import pyatspi
    from gi.repository import GLib
    sock = sys.argv[1] if len(sys.argv) > 1 else "/run/user/1000/porthole-menu.sock"
    server = MenuServer(sock, pyatspi, GLib)
    server.start()
    pyatspi.Registry.start()  # runs the GLib loop + AT-SPI event pump


if __name__ == "__main__":
    main()
