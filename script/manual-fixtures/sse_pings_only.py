#!/usr/bin/env python3
"""Loopback SSE stub for the stream guard's first-output proof.

Every POST gets 200 text/event-stream headers, then pings only -- never a
reply -- until the client hangs up; each hang-up is logged with how long it
waited and how many pings it got. Request headers (the key) are never read.

    python3 script/manual-fixtures/sse_pings_only.py [port=8799] [seconds-between-pings=5]
"""
import http.server
import sys
import time

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
EVERY = float(sys.argv[2]) if len(sys.argv) > 2 else 5.0


class PingsOnly(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        started, pings = time.monotonic(), 0
        try:
            while True:
                time.sleep(EVERY)
                self.wfile.write(b'event: ping\ndata: {"type": "ping"}\n\n')
                self.wfile.flush()
                pings += 1
        except (BrokenPipeError, ConnectionResetError):
            # Noticed on a later ping write, so up to two pings after the cut.
            print(f"{self.path}: hang-up noticed {time.monotonic() - started:.0f} s in, {pings} pings sent", flush=True)

    def log_message(self, *args):
        pass


print(f"pings only on http://127.0.0.1:{PORT} every {EVERY:g} s", flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), PingsOnly).serve_forever()
