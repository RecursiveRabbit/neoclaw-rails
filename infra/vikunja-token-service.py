#!/usr/bin/env python3
"""
Vikunja Token Service — generates ephemeral API tokens for agent sessions.

Tiny HTTP server on the host WG IP. Only the Manager can reach it.

Tokens are created by inserting directly into Vikunja's SQLite DB with
PBKDF2-SHA256 hashes (matching Vikunja's own HashToken function). This
bypasses a bug in Vikunja v2's PUT /tokens endpoint where API-created
tokens fail verification.

Each token is scoped to a single agent session and purged at teardown.

POST /token/<username>  → generate token, return {"token": "...", "project_id": N}
DELETE /token/<username> → delete neoclaw-* tokens for user, return {"ok": true}
GET /health             → {"status": "ok"}

Usage:
    ./vikunja-token-service.py
    # Listens on 10.0.0.2:8890
"""

import hashlib
import binascii
import json
import os
import secrets
import sqlite3
import string
import sys
from datetime import datetime, timedelta
from http.server import HTTPServer, BaseHTTPRequestHandler

VIKUNJA_DB = os.environ.get("VIKUNJA_DB", "/opt/vikunja/db/vikunja.db")
LISTEN_HOST = os.environ.get("LISTEN_HOST", "10.0.0.2")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8890"))

# Full permissions matching the working tokens — agents need broad access
# to manage their own tasks, comments, labels, and project views.
DEFAULT_PERMISSIONS = json.dumps({
    "tasks": ["create", "read_all", "read_one", "update", "delete", "read"],
    "projects": ["read_all", "read_one"],
    "tasks_comments": ["create", "read_all", "read_one", "update", "delete"],
    "labels": ["create", "read_all", "read_one", "update", "delete"],
    "tasks_labels": ["create", "read_all", "delete"],
})


def hash_token(token: str, salt: str) -> str:
    """Replicate Vikunja's HashToken: PBKDF2-SHA256, 10000 iterations, 50 bytes."""
    dk = hashlib.pbkdf2_hmac("sha256", token.encode(), salt.encode(), 10000, dklen=50)
    return binascii.hexlify(dk).decode()


def generate_salt(length: int = 10) -> str:
    """Generate a random alphanumeric salt (matching Vikunja's salt format)."""
    return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(length))


class TokenHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        username = self._parse_username()
        if not username:
            return

        db = sqlite3.connect(VIKUNJA_DB)
        try:
            # Find the user
            row = db.execute("SELECT id FROM users WHERE username=?", (username,)).fetchone()
            if not row:
                self._json(404, {"error": f"no Vikunja user '{username}'"})
                return

            user_id = row[0]

            # Generate token components
            token_raw = secrets.token_hex(20)  # 40 hex chars
            token = f"tk_{token_raw}"
            salt = generate_salt()
            token_hash = hash_token(token, salt)
            last_eight = token[-8:]
            title = f"neoclaw-{username}-{secrets.token_hex(4)}"
            expires = (datetime.utcnow() + timedelta(days=365)).strftime("%Y-%m-%dT%H:%M:%SZ")

            # Insert directly into the DB
            db.execute(
                """INSERT INTO api_tokens
                   (title, token_salt, token_hash, token_last_eight, permissions, expires_at, created, owner_id)
                   VALUES (?, ?, ?, ?, ?, ?, datetime('now'), ?)""",
                (title, salt, token_hash, last_eight, DEFAULT_PERMISSIONS, expires, user_id),
            )
            db.commit()

            # Get the user's default project
            project_row = db.execute(
                "SELECT id FROM projects WHERE owner_id=? ORDER BY id LIMIT 1", (user_id,)
            ).fetchone()
            project_id = project_row[0] if project_row else 1

            self._json(200, {
                "token": token,
                "username": username,
                "project_id": project_id,
            })
            self.log_message("token generated for %s (project %s)", username, project_id)

        except Exception as e:
            self._json(500, {"error": str(e)})
            self.log_message("ERROR generating token for %s: %s", username, e)
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
            cursor = db.execute(
                "DELETE FROM api_tokens WHERE owner_id=? AND title LIKE 'neoclaw-%'", (user_id,)
            )
            db.commit()

            self._json(200, {"ok": True, "username": username, "deleted": cursor.rowcount})
            self.log_message("tokens revoked for %s (%d deleted)", username, cursor.rowcount)
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
