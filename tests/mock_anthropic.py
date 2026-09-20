#!/usr/bin/env python3
"""Localhost stand-in for an Anthropic-compatible endpoint.

Records, per request, WHICH KIND of credential arrived and which model id was
asked for. Credential values are never written anywhere: they are only classified.
Every request is rejected with a non-retryable 400, so no inference happens.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[1]
PORT = int(sys.argv[2])


def classify(value):
    if not value:
        return "absent"
    if "dummy-zai-key" in value:
        return "DUMMY_ZAI_KEY"
    if "ai-team-glm-worker" in value:
        return "GUARD_PLACEHOLDER"
    return "OTHER_REAL_CREDENTIAL(len=%d)" % len(value)


class Handler(BaseHTTPRequestHandler):
    def _record(self, body):
        model = ""
        try:
            model = json.loads(body or b"{}").get("model", "")
        except ValueError:
            model = "(unparsable body)"
        entry = {
            "method": self.command,
            "path": self.path.split("?")[0],
            "authorization": classify(self.headers.get("Authorization", "")),
            "x_api_key": classify(self.headers.get("x-api-key", "")),
            "model": model,
        }
        with open(LOG, "a") as handle:
            handle.write(json.dumps(entry) + "\n")

    def _reject(self):
        payload = json.dumps(
            {"type": "error", "error": {"type": "invalid_request_error", "message": "mock endpoint: rejected on purpose"}}
        ).encode()
        self.send_response(400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        length = int(self.headers.get("content-length", "0") or 0)
        self._record(self.rfile.read(length))
        self._reject()

    def do_GET(self):
        self._record(b"")
        self._reject()

    def log_message(self, *args):
        return


HTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
