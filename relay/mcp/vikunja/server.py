#!/usr/bin/env python3
"""Vikunja ticket MCP server for NeoClaw.

Exposes six tools: ticket_list, ticket_view, ticket_create,
ticket_comment, ticket_update, ticket_done.

All tools accept human-friendly project-scoped index numbers and
resolve them to Vikunja internal IDs via the API.
"""

import os
import json
from typing import Any

import httpx
from mcp.server.fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

API_BASE = os.environ.get("VIKUNJA_API_URL", "http://127.0.0.1:3456/api/v1")
TOKEN = os.environ.get("VIKUNJA_TOKEN", "")
PROJECT_ID = int(os.environ.get("VIKUNJA_PROJECT_ID", "1"))

mcp = FastMCP("vikunja-tickets")

# ---------------------------------------------------------------------------
# HTTP helpers
# ---------------------------------------------------------------------------

def _headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"}


def _get(path: str, params: dict | None = None) -> Any:
    r = httpx.get(f"{API_BASE}{path}", headers=_headers(), params=params, timeout=15)
    r.raise_for_status()
    return r.json()


def _put(path: str, body: dict) -> Any:
    r = httpx.put(f"{API_BASE}{path}", headers=_headers(), json=body, timeout=15)
    r.raise_for_status()
    return r.json()


def _post(path: str, body: dict) -> Any:
    r = httpx.post(f"{API_BASE}{path}", headers=_headers(), json=body, timeout=15)
    r.raise_for_status()
    return r.json()


# ---------------------------------------------------------------------------
# Index → internal ID resolution
# ---------------------------------------------------------------------------

def _resolve_task(index: int) -> dict:
    """Resolve a project-scoped index number to a full task dict."""
    tasks = _get(f"/projects/{PROJECT_ID}/tasks", params={
        "filter_by": "index",
        "filter_value": str(index),
        "filter_comparator": "equals",
        "per_page": "1",
    })
    if not tasks:
        raise ValueError(f"No task found with index {index} in project {PROJECT_ID}")
    return tasks[0]


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

PRIORITY_MAP = {0: "unset", 1: "low", 2: "medium", 3: "high", 4: "urgent", 5: "critical"}


def _priority_label(p: int) -> str:
    return PRIORITY_MAP.get(p, str(p))


def _priority_value(label: str) -> int:
    rev = {v: k for k, v in PRIORITY_MAP.items()}
    if label in rev:
        return rev[label]
    try:
        return int(label)
    except ValueError:
        raise ValueError(f"Unknown priority: {label}. Use: {', '.join(rev.keys())}")


def _assignee_names(task: dict) -> list[str]:
    assignees = task.get("assignees") or []
    return [a.get("username", a.get("name", "?")) for a in assignees]


def _fmt_task_line(t: dict) -> str:
    done = "✓" if t.get("done") else " "
    pri = _priority_label(t.get("priority", 0))
    assignees = ", ".join(_assignee_names(t)) or "—"
    return f"[{done}] #{t['index']}  {t['title']}  (priority: {pri}, assignees: {assignees})"


# ---------------------------------------------------------------------------
# Tools
# ---------------------------------------------------------------------------

@mcp.tool()
def ticket_list(status: str = "open") -> str:
    """List tickets. Status: open (default), done, or all."""
    params: dict[str, str] = {"per_page": "200"}

    if status == "open":
        params["filter_by"] = "done"
        params["filter_value"] = "false"
        params["filter_comparator"] = "equals"
    elif status == "done":
        params["filter_by"] = "done"
        params["filter_value"] = "true"
        params["filter_comparator"] = "equals"
    # 'all' → no filter

    tasks = _get(f"/projects/{PROJECT_ID}/tasks", params=params)
    if not tasks:
        return f"No {status} tickets found."
    tasks.sort(key=lambda t: t.get("index", 0))
    lines = [_fmt_task_line(t) for t in tasks]
    return f"{len(tasks)} {status} ticket(s):\n" + "\n".join(lines)


@mcp.tool()
def ticket_view(index: int) -> str:
    """View a ticket by its index number. Shows title, description, priority, assignees, and comments."""
    task = _resolve_task(index)
    tid = task["id"]

    # Fetch comments
    try:
        comments = _get(f"/tasks/{tid}/comments")
    except httpx.HTTPStatusError:
        comments = []

    parts = [
        f"# #{task['index']}: {task['title']}",
        f"**Status:** {'done' if task.get('done') else 'open'}",
        f"**Priority:** {_priority_label(task.get('priority', 0))}",
        f"**Assignees:** {', '.join(_assignee_names(task)) or '—'}",
    ]
    desc = task.get("description", "").strip()
    if desc:
        parts.append(f"\n## Description\n{desc}")

    if comments:
        parts.append(f"\n## Comments ({len(comments)})")
        for c in comments:
            author = c.get("author", {}).get("username", "?")
            text = c.get("comment", "")
            parts.append(f"- **{author}:** {text}")

    return "\n".join(parts)


@mcp.tool()
def ticket_create(
    title: str,
    description: str = "",
    priority: str = "unset",
    assignee: str = "",
) -> str:
    """Create a new ticket. Priority: unset/low/medium/high/urgent/critical. Assignee: username."""
    body: dict[str, Any] = {
        "title": title,
        "description": description,
        "priority": _priority_value(priority),
        "project_id": PROJECT_ID,
    }
    task = _put(f"/projects/{PROJECT_ID}/tasks", body)

    # Assign if requested
    if assignee:
        _assign_user(task["id"], assignee)

    return f"Created ticket #{task['index']}: {task['title']}"


@mcp.tool()
def ticket_comment(index: int, comment: str) -> str:
    """Add a comment to a ticket by index number."""
    task = _resolve_task(index)
    tid = task["id"]
    result = _put(f"/tasks/{tid}/comments", {"comment": comment})
    return f"Comment added to #{index}."


@mcp.tool()
def ticket_update(
    index: int,
    title: str = "",
    description: str = "",
    priority: str = "",
) -> str:
    """Update a ticket's title, description, and/or priority."""
    task = _resolve_task(index)
    tid = task["id"]

    body: dict[str, Any] = {}
    if title:
        body["title"] = title
    if description:
        body["description"] = description
    if priority:
        body["priority"] = _priority_value(priority)

    if not body:
        return "Nothing to update — provide at least one field."

    _post(f"/tasks/{tid}", body)
    return f"Updated ticket #{index}."


@mcp.tool()
def ticket_done(index: int) -> str:
    """Mark a ticket as done."""
    task = _resolve_task(index)
    tid = task["id"]
    _post(f"/tasks/{tid}", {"done": True})
    return f"Ticket #{index} marked done."


# ---------------------------------------------------------------------------
# User resolution for assignment
# ---------------------------------------------------------------------------

def _assign_user(task_id: int, username: str) -> None:
    """Resolve username to user ID and assign to task."""
    users = _get("/users", params={"s": username})
    if not users:
        raise ValueError(f"User '{username}' not found")
    uid = users[0]["id"]
    _put(f"/tasks/{task_id}/assignees", {"user_id": uid})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    mcp.run()
