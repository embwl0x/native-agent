#!/usr/bin/env python3
"""Loopback Slack proof server; POST /control {drop_next: true, bot: "B1"}."""
import argparse
import json
import socket
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--port", type=int, default=8782)
parser.add_argument("--state", type=Path, required=True)
args = parser.parse_args()
state = json.loads(args.state.read_text()) if args.state.exists() else {"posts": [], "bot": "B1"}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.handle_api({key: value[0] for key, value in parse_qs(urlsplit(self.path).query).items()})

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        self.handle_api(json.loads(body) if body else {})

    def handle_api(self, payload):
        method = urlsplit(self.path).path.rsplit("/", 1)[-1]
        if method == "control":
            state.update(payload)
            response = {"ok": True}
        elif method == "chat.postMessage":
            message = dict(payload, ts=f"{time.time():.6f}", user=state["bot"])
            state["posts"].append(message)
            response = {"ok": True, "ts": message["ts"], "channel": payload["channel"], "message": message}
        elif method in ("conversations.history", "conversations.replies"):
            messages = [row for row in state["posts"] if row["channel"] == payload.get("channel")
                        and (method != "conversations.replies" or row.get("thread_ts") == payload.get("ts"))]
            response = {"ok": True, "messages": messages, "has_more": False}
        else:
            response = {"ok": False, "error": "unsupported_fixture_method"}
        drop = method == "chat.postMessage" and state.pop("drop_next", False)
        pending = args.state.with_suffix(".tmp")
        pending.write_text(json.dumps(state, indent=2))
        pending.replace(args.state)
        if drop:
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        body = json.dumps(response).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()
