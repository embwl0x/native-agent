#!/usr/bin/env python3
"""Loopback Telegram proof server; POST /control {drop_next: true, updates: []}."""
import argparse
import json
import socket
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=8781)
parser.add_argument("--state", type=Path, required=True)
args = parser.parse_args()
state = json.loads(args.state.read_text()) if args.state.exists() else {"posts": [], "updates": []}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.handle_api({})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.handle_api(json.loads(body) if body else {})

    def handle_api(self, payload):
        method = self.path.split("?")[0].rsplit("/", 1)[-1]
        if method == "control":
            state.update(payload)
            result = True
        elif method == "getMe":
            result = {"id": 1, "is_bot": True, "first_name": "Fixture", "username": "fixture_bot"}
        elif method == "getUpdates":
            result = state.get("updates", [])
            state["updates"] = []
        elif method in ("sendMessage", "sendPhoto", "sendRichMessage"):
            result = {"message_id": len(state["posts"]) + 1, "chat": {"id": payload.get("chat_id", 1)}, "date": 1}
            state["posts"].append({"method": method, "payload": payload, "result": result})
        else:
            result = True
        drop = method in ("sendMessage", "sendPhoto", "sendRichMessage") and state.pop("drop_next", False)
        pending = args.state.with_suffix(".tmp")
        pending.write_text(json.dumps(state, indent=2))
        pending.replace(args.state)
        if drop:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        body = json.dumps({"ok": True, "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
