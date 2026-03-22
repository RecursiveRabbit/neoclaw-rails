#!/usr/bin/env python3
"""
Valley Token Service — generates and revokes API tokens for Evennia accounts.

Tiny HTTP server on the host WG IP. Only the Manager can reach it.
The Manager calls this during agent provisioning to get Valley tokens.

POST /token/<username>  → generate token, return {"token": "..."}
DELETE /token/<username> → revoke token, return {"ok": true}
GET /health             → {"status": "ok"}

Usage:
    ./valley-token-service.py
    # Listens on 10.0.0.2:8889 (host WG IP, not localhost)

Requires the Evennia virtualenv and DJANGO_SETTINGS_MODULE.
"""

import json
import os
import secrets
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler

# Evennia setup — must happen before any Django imports
VALLEY_DIR = os.environ.get("VALLEY_DIR", "/home/hopper/theuncannyvalley")
sys.path.insert(0, VALLEY_DIR)
os.environ.setdefault("DJANGO_SETTINGS_MODULE", "server.conf.settings")

import django
django.setup()

from evennia.accounts.models import AccountDB

LISTEN_HOST = os.environ.get("LISTEN_HOST", "10.0.0.2")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8889"))


class TokenHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        username = self.path.strip("/").split("/")[-1] if self.path.startswith("/token/") else None
        if not username:
            self._json(400, {"error": "POST /token/<username>"})
            return

        try:
            account = AccountDB.objects.get(username__iexact=username)
        except AccountDB.DoesNotExist:
            self._json(404, {"error": f"no Valley account '{username}'"})
            return

        token = secrets.token_hex(32)
        account.attributes.add("api_token", token)
        # Evennia caches attributes in memory. Reload so the server sees it.
        import subprocess
        evennia_bin = os.environ.get("EVENNIA_BIN", "/home/hopper/evennia-env/bin/evennia")
        subprocess.run(
            [evennia_bin, "reload"],
            cwd=VALLEY_DIR, capture_output=True, timeout=10
        )
        self._json(200, {"token": token, "username": account.username})
        self.log_message("token generated for %s (server reloaded)", account.username)

    def do_DELETE(self):
        username = self.path.strip("/").split("/")[-1] if self.path.startswith("/token/") else None
        if not username:
            self._json(400, {"error": "DELETE /token/<username>"})
            return

        try:
            account = AccountDB.objects.get(username__iexact=username)
        except AccountDB.DoesNotExist:
            self._json(404, {"error": f"no Valley account '{username}'"})
            return

        account.attributes.remove("api_token")
        self._json(200, {"ok": True, "username": account.username})
        self.log_message("token revoked for %s", account.username)

    def do_GET(self):
        if self.path == "/health":
            count = AccountDB.objects.count()
            self._json(200, {"status": "ok", "accounts": count})
        else:
            self._json(404, {"error": "GET /health"})

    def _json(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def log_message(self, format, *args):
        sys.stderr.write(f"[valley-tokens] {format % args}\n")


if __name__ == "__main__":
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), TokenHandler)
    sys.stderr.write(f"[valley-tokens] listening on {LISTEN_HOST}:{LISTEN_PORT}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
