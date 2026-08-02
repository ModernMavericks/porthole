#!/usr/bin/env python3
# Stand-in menu daemon for spine verification: listen on a Unix socket, send a
# snapshot on hello, then a delta 2s later. Prints any invoke/open it receives.
import socket, os, sys, json, threading, time

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mock-menu.sock"
try: os.unlink(path)
except FileNotFoundError: pass
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path); srv.listen(1)
print(f"mock producer listening on {path}", flush=True)
conn, _ = srv.accept()
f = conn.makefile("rwb", buffering=0)

def send(obj): f.write((json.dumps(obj) + "\n").encode())

hello = f.readline()
print("got:", hello.decode().strip(), flush=True)
send({"t": "menu", "root": [{"id": 1, "role": "submenu", "label": "MockMenu",
      "children": [{"id": 2, "role": "item", "label": "Alive", "enabled": True},
                   {"id": 3, "role": "item", "label": "Grayed", "enabled": False}]}]})

def reader():
    for line in f:
        print("client->", line.decode().strip(), flush=True)
threading.Thread(target=reader, daemon=True).start()

time.sleep(2)
send({"t": "delta", "changes": [{"id": 3, "enabled": True, "label": "Now Enabled"}]})
time.sleep(60)
