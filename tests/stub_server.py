#!/usr/bin/env python3
"""
A stand-in for the ClimWeb product-sync API, used by the tests.

It mirrors the real endpoints closely enough to exercise the wizard end to end
without needing a Django installation: the same status codes, the same env-style
response body, and the same destination path derivation.
"""

import argparse
import cgi
import http.server
import json
import os
import sys

VALID_CODE = "K7FA-2C9D-TX43"
USED_CODES = set()
TOKEN = "test-token-abcdefghijklmnop"

STATE = {"uploads": [], "watch_root": "/tmp/stub-watch"}


def env_body(data):
    lines = []
    for key, value in data.items():
        text = "" if value is None else str(value)
        lines.append("%s='%s'" % (key.upper(), text.replace("'", "'\\''")))
    return ("\n".join(lines) + "\n").encode()


def normalise(raw):
    alphabet = "ACDEFGHJKMNPQRTUVWXYZ2346789"
    cleaned = "".join(c for c in raw.upper() if c in alphabet)
    if len(cleaned) != 12:
        return ""
    return "-".join(cleaned[i:i + 4] for i in range(0, 12, 4))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status, body=b"", ctype="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _json(self, status, payload):
        self._send(status, json.dumps(payload).encode())

    def _form(self):
        ctype = self.headers.get("Content-Type", "")
        length = int(self.headers.get("Content-Length", 0) or 0)
        if ctype.startswith("multipart/form-data"):
            return cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={"REQUEST_METHOD": "POST", "CONTENT_TYPE": ctype},
            )
        from urllib.parse import parse_qs
        raw = self.rfile.read(length).decode()
        return {k: v[0] for k, v in parse_qs(raw).items()}

    def _authed(self):
        return self.headers.get("Authorization", "") == "Bearer " + TOKEN

    def do_GET(self):
        if self.path.startswith("/api/product-sync/ping/"):
            if not self._authed():
                return self._json(401, {"error": "invalid_token"})
            payload = {
                "status": "ok",
                "product_name": "Weekly Rainfall",
                "variable_name": "weekly_rainfall",
                "formats": "pdf",
                "ingestion_enabled": "true",
            }
            if "format=env" in self.path:
                return self._send(200, env_body(payload), "text/plain")
            return self._json(200, payload)
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        if self.path.startswith("/api/product-sync/setup/exchange/"):
            return self._exchange()
        if self.path.startswith("/api/product-sync/upload/"):
            return self._upload()
        self._json(404, {"error": "not_found"})

    def _exchange(self):
        form = self._form()
        code = normalise(form.get("code", ""))
        if code != VALID_CODE or code in USED_CODES:
            return self._json(403, {"error": "invalid_code", "detail": "nope"})
        USED_CODES.add(code)
        payload = {
            "product_name": "Weekly Rainfall",
            "variable_name": "weekly_rainfall",
            "formats": "pdf",
            "format": "pdf",
            "ingestion_enabled": "true",
            "watch_root": STATE["watch_root"],
            "base_url": "http://%s:%d" % self.server.server_address,
            "token": TOKEN,
            "credential_id": 1,
        }
        if form.get("format") == "env":
            return self._send(200, env_body(payload), "text/plain")
        return self._json(200, payload)

    def _upload(self):
        if not self._authed():
            return self._json(401, {"error": "invalid_token"})
        form = self._form()
        variable_name = form.getvalue("variable_name")
        fmt = form.getvalue("format")
        rel = form.getvalue("relative_path")
        fileitem = form["file"] if "file" in form else None

        if variable_name != "weekly_rainfall":
            return self._json(400, {"error": "wrong_product"})
        if fmt != "pdf":
            return self._json(400, {"error": "bad_format"})

        # Same containment rule as the real endpoint.
        parts = [p for p in rel.replace("\\", "/").split("/") if p not in ("", ".")]
        if rel.startswith("/") or any(p == ".." or p.startswith(".") for p in parts):
            return self._json(400, {"error": "bad_path"})

        base = os.path.join(STATE["watch_root"], variable_name, fmt)
        dest = os.path.join(base, *parts)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as handle:
            handle.write(fileitem.file.read() if fileitem else b"")
        STATE["uploads"].append(rel)
        return self._json(201, {"status": "stored", "path": rel})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--watch-root", default="/tmp/stub-watch")
    parser.add_argument("--port-file", default="")
    args = parser.parse_args()

    STATE["watch_root"] = args.watch_root
    server = http.server.HTTPServer(("127.0.0.1", args.port), Handler)
    if args.port_file:
        with open(args.port_file, "w") as handle:
            handle.write(str(server.server_address[1]))
    sys.stderr.write("stub listening on %d\n" % server.server_address[1])
    sys.stderr.flush()
    server.serve_forever()


if __name__ == "__main__":
    main()
