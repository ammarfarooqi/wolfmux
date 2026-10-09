#!/usr/bin/env python3
"""Localhost stand-in for a provider endpoint, for the `teamctl doctor --probe` checks.

Usage: mock_probe.py <log-file> <port-file>
It binds a free port on 127.0.0.1, writes the port number to <port-file>, then answers.

Per request it appends one JSON line to <log-file>: the method, the path, which of the two
credential headers arrived, whether they carried the same value, and the body. The
credential value itself is never written anywhere: only whether it contained "good".

The answer mimics what the six real endpoints do (measured with a fake key, 2026-09-23):
authentication comes first, the body is validated after. A credential that contains "good"
gets past authentication and the empty body is refused with 400; any other gets 401.
A path that starts with /redirect answers 302 to /second instead, to show that a client
which does not follow redirects sends exactly one request (the log then has one line).
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[1]
PORT_FILE = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def _answer(self, body):
        api_key = self.headers.get("x-api-key", "")
        authorization = self.headers.get("Authorization", "")
        bearer = authorization[len("Bearer "):] if authorization.startswith("Bearer ") else ""
        entry = {
            "method": self.command,
            "path": self.path.split("?")[0],
            "x_api_key": bool(api_key),
            "bearer": bool(bearer),
            "same_value": bool(api_key) and api_key == bearer,
            "content_type": self.headers.get("content-type", ""),
            "anthropic_version": self.headers.get("anthropic-version", ""),
            "body": body.decode("utf-8", "replace"),
        }
        with open(LOG, "a") as handle:
            handle.write(json.dumps(entry) + "\n")
        if entry["path"].startswith("/redirect"):
            self.send_response(302)
            self.send_header("location", "/second")
            self.send_header("content-length", "0")
            self.end_headers()
            return
        accepted = "good" in api_key and api_key == bearer
        status = 400 if accepted else 401
        message = "messages: model is required" if accepted else "invalid api key"
        payload = json.dumps({"type": "error", "error": {"type": "invalid_request_error", "message": message}}).encode()
        self.send_response(status)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0") or 0)
        self._answer(self.rfile.read(length))

    def do_GET(self):
        self._answer(b"")

    def log_message(self, *args):
        return


server = HTTPServer(("127.0.0.1", 0), Handler)
with open(PORT_FILE, "w") as handle:
    handle.write(str(server.server_address[1]))
server.serve_forever()
