#!/usr/bin/env python3
"""
Vikunja Token Service — generates API tokens for Vikunja users.

Tiny HTTP server on the host WG IP. Only the Manager can reach it.

The flow: set a temp password on the user → login to get a JWT →
create an API token via the JWT → restore the user's password.

POST /token/<username>  → generate token, return {"token": "...", "project_id": N}
DELETE /token/<username> → delete all tokens for user, return {"ok": true}
GET /health             → {"status": "ok"}

Usage:
    ./vikunja-token-service.py
    # Listens on 10.0.0.2:8890
"""

import json
import os
import secrets
import sqlite3
import sys
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler

import bcrypt

VIKUNJA_DB = os.environ.get("VIKUNJA_DB", "/opt/vikunja/db/vikunja.db")
VIKUNJA_API = os.environ.get("VIKUNJA_API", "http://127.0.0.1:3456/api/v1")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "10.0.0.2")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8890"))

# Provisioning password — used temporarily, never exposed
PROVISION_PASSWORD = "neoclaw-provision-" + secrets.token_hex(8)


def vikunja_api(method, path, body=None, token=None):
    """Make a request to the Vikunja API."""
    url = f"{VIKUNJA_API}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        raise Exception(f"Vikunja API {method} {path}: {e.code} {body}")


class TokenHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        username = self._parse_username()
        if not username:
            return

        db = sqlite3.connect(VIKUNJA_DB)
        try:
            # Find the user
            row = db.execute("SELECT id, password FROM users WHERE username=?", (username,)).fetchone()
            if not row:
                self._json(404, {"error": f"no Vikunja user '{username}'"})
                return

            user_id, original_hash = row

            # Set a temporary password so we can login via the API
            temp_hash = bcrypt.hashpw(PROVISION_PASSWORD.encode(), bcrypt.gensalt()).decode()
            db.execute("UPDATE users SET password=? WHERE id=?", (temp_hash, user_id))
            db.commit()

            try:
                # Login to get a JWT
                jwt_resp = vikunja_api("POST", "/login", {
                    "username": username,
                    "password": PROVISION_PASSWORD
                })
                jwt = jwt_resp.get("token")
                if not jwt:
                    raise Exception(f"no token in login response: {jwt_resp}")

                # Create an API token
                token_resp = vikunja_api("PUT", "/tokens", {
                    "title": f"neoclaw-{username}-{secrets.token_hex(4)}",
                    "permissions": {"tasks": ["read", "create", "update"]},
                    "expires_at": (datetime.utcnow() + timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ")
                }, token=jwt)

                api_token = token_resp.get("token", "")

                # Get the user's default project
                projects = vikunja_api("GET", "/projects", token=jwt)
                project_id = projects[0]["id"] if projects else 1

                self._json(200, {
                    "token": api_token,
                    "username": username,
                    "project_id": project_id
                })
                self.log_message("token generated for %s (project %s)", username, project_id)

            finally:
                # Always restore the original password
                db.execute("UPDATE users SET password=? WHERE id=?", (original_hash, user_id))
                db.commit()

        finally:
            db.close()

    def do_DELETE(self):
        username = self._parse_username()
        if not username:
            return

        db = sqlite3.connect(VIKUNJA_DB)
        try:
            row = db.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
            if not row:
                self._json(404, {"error": f"no Vikunja user '{username}'"})
                return

            user_id = row[0]
            # Delete all API tokens for this user that start with "neoclaw-"
            db.execute("DELETE FROM api_tokens WHERE owner_id=? AND title LIKE 'neoclaw-%'", (user_id,))
            db.commit()

            self._json(200, {"ok": True, "username": username})
            self.log_message("tokens revoked for %s", username)
        finally:
            db.close()

    def do_GET(self):
        if self.path == "/health":
            try:
                db = sqlite3.connect(VIKUNJA_DB)
                count = db.execute("SELECT COUNT(*) FROM users").fetchone()[0]
                db.close()
                self._json(200, {"status": "ok", "users": count})
            except Exception as e:
                self._json(500, {"status": "error", "error": str(e)})
        else:
            self._json(404, {"error": "GET /health"})

    def _parse_username(self):
        if self.path.startswith("/token/"):
            return self.path.strip("/").split("/")[-1]
        self._json(400, {"error": "use /token/<username>"})
        return None

    def _json(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def log_message(self, format, *args):
        sys.stderr.write(f"[vikunja-tokens] {format % args}\n")


if __name__ == "__main__":
    server = HTTPServer((LISTEN_HOST, LISTEN_PORT), TokenHandler)
    sys.stderr.write(f"[vikunja-tokens] listening on {LISTEN_HOST}:{LISTEN_PORT}\n")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
