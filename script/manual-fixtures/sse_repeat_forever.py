#!/usr/bin/env python3
"""Responses SSE repetition, then a completed reply to the continuation.

    python3 script/manual-fixtures/sse_repeat_forever.py [port=8799]
"""
import http.server
import json
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8799


class RepeatForever(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        continuing = b"Continue from here; do not repeat what was written or done." in body
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        started, deltas = time.monotonic(), 0
        try:
            if continuing:
                self.event({"type": "response.output_text.delta", "delta": "The reply continued and finished."})
                self.event({"type": "response.completed", "response": {"status": "completed", "output": []}})
                print(f"{self.path}: continuation completed", flush=True)
                return
            while True:
                self.event({"type": "response.output_text.delta", "delta": "This line keeps repeating.\n"})
                deltas += 1
                time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError):
            print(f"{self.path}: hang-up noticed {time.monotonic() - started:.0f} s in, {deltas} deltas sent", flush=True)

    def event(self, value):
        # The README endpoint is /v1/chat/completions: the app's chat-completions
        # decoder reads choices[0].delta.content and ends on [DONE].
        frames = []
        if value.get("type") == "response.output_text.delta":
            frames.append({"choices": [{"index": 0, "delta": {"content": value["delta"]}}]})
        elif value.get("type") == "response.completed":
            frames.append({"choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            frames.append("[DONE]")
        else:
            frames.append(value)
        for frame in frames:
            data = frame if isinstance(frame, str) else json.dumps(frame)
            self.wfile.write(("data: " + data + "\n\n").encode())
        self.wfile.flush()

    def log_message(self, *args):
        pass


print(f"repeat forever on http://127.0.0.1:{PORT}", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), RepeatForever).serve_forever()
