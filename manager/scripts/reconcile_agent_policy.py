#!/usr/bin/env python3
"""Reconcile NeoClaw agent service policy + Forgejo identity repo bootstrap.

Deterministic one-command setup:
  python3 manager/scripts/reconcile_agent_policy.py

Optional env overrides:
  POLICY_JSON='{"rook":[...],"elias":[...]}'
  MANAGER_DB=/var/lib/neoclaw/manager-db/manager_production.sqlite3
  FORGEJO_URL=http://127.0.0.1:3000
  FORGEJO_ADMIN_TOKEN=...
"""

import base64
import json
import os
import sqlite3
import urllib.request

DEFAULT_POLICY = {
    "rook": ["forgejo", "ssh", "valley", "vikunja", "matrix"],
    "elias": ["forgejo", "ssh", "valley", "vikunja", "matrix"],
    "ellis": ["forgejo", "valley", "vikunja", "matrix"],
    "iris": ["forgejo", "valley", "vikunja", "matrix"],
    "morgan": ["forgejo", "valley", "matrix"],
}

DB = os.environ.get("MANAGER_DB", "/var/lib/neoclaw/manager-db/manager_production.sqlite3")
FORGEJO_URL = os.environ.get("FORGEJO_URL", "http://127.0.0.1:3000").rstrip("/")
TOKEN = os.environ.get("FORGEJO_ADMIN_TOKEN", "")
POLICY = json.loads(os.environ.get("POLICY_JSON", json.dumps(DEFAULT_POLICY)))


def api(method, path, body=None):
    if not TOKEN:
        raise RuntimeError("FORGEJO_ADMIN_TOKEN required")
    req = urllib.request.Request(
        f"{FORGEJO_URL}{path}",
        method=method,
        headers={"Authorization": f"token {TOKEN}", "Content-Type": "application/json"},
        data=(json.dumps(body).encode() if body is not None else None),
    )
    return urllib.request.urlopen(req, timeout=20)


def exists(path):
    try:
        api("GET", path).read()
        return True
    except Exception:
        return False


def ensure_forgejo_workspace(identity):
    if not exists(f"/api/v1/users/{identity}"):
        api(
            "POST",
            "/api/v1/admin/users",
            {
                "username": identity,
                "email": f"{identity}@local",
                "password": base64.urlsafe_b64encode(os.urandom(24)).decode(),
                "must_change_password": False,
                "visibility": "private",
            },
        ).read()

    if not exists(f"/api/v1/repos/{identity}/workspace"):
        api(
            "POST",
            f"/api/v1/admin/users/{identity}/repos",
            {"name": "workspace", "private": True, "auto_init": True, "default_branch": "main"},
        ).read()

    if not exists(f"/api/v1/repos/{identity}/workspace/contents/identity.json?ref=main"):
        content = {
            "id": identity,
            "name": identity,
            "role": "resident-agent",
            "instructions": "Read this identity file first on boot, then respond in your own voice.",
        }
        api(
            "POST",
            f"/api/v1/repos/{identity}/workspace/contents/identity.json",
            {
                "message": "bootstrap identity.json",
                "content": base64.b64encode((json.dumps(content, indent=2) + "\n").encode()).decode(),
                "branch": "main",
            },
        ).read()


def main():
    con = sqlite3.connect(DB)
    cur = con.cursor()

    # Ensure matrix service provision mode is correct.
    cur.execute("update service_types set provision_type='matrix' where name='matrix'")

    for identity, services in POLICY.items():
        cur.execute(
            "update agent_configs set base_services=? where identity=?",
            (json.dumps(services, separators=(",", ":")), identity),
        )
        print(f"policy: {identity} -> {services}")

    con.commit()
    con.close()

    # Bootstrap Forgejo identity repos.
    for identity in POLICY:
        ensure_forgejo_workspace(identity)
        print(f"forgejo: {identity}/workspace ready")

    print("done")


if __name__ == "__main__":
    main()
