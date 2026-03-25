#!/usr/bin/env python3
"""Matrix MCP server — gives agents Matrix communication tools.

Uses appservice token + user_id impersonation so calls are authored as the
agent's Matrix account (e.g. @elias:localhost), not the appservice bot.
"""

import json
import os
import uuid
from pathlib import Path
from urllib.parse import quote

import httpx
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("matrix")

HOMESERVER = os.environ.get("MATRIX_HOMESERVER", "http://localhost:8008").rstrip("/")
USER_ID = os.environ.get("MATRIX_USER_ID", "")
TOKEN = os.environ.get("MATRIX_TOKEN", "")


def _auth_params(extra: dict | None = None) -> dict:
    p = {"access_token": TOKEN}
    if USER_ID:
        p["user_id"] = USER_ID
    if extra:
        p.update(extra)
    return p


async def _request(method: str, path: str, *, params: dict | None = None, json_body=None, data=None, headers=None, timeout=15):
    url = f"{HOMESERVER}{path}"
    merged = _auth_params(params)
    async with httpx.AsyncClient(timeout=timeout) as client:
        return await client.request(method, url, params=merged, json=json_body, content=data, headers=headers)


@mcp.tool()
async def matrix_send(room_id: str, message: str) -> str:
    """Send a message to a Matrix room. Supports markdown formatting."""
    event_id = uuid.uuid4().hex
    room_enc = quote(room_id, safe="")
    resp = await _request(
        "PUT",
        f"/_matrix/client/v3/rooms/{room_enc}/send/m.room.message/{event_id}",
        json_body={
            "msgtype": "m.text",
            "body": message,
            "format": "org.matrix.custom.html",
            "formatted_body": _md_to_html(message),
        },
    )
    if 200 <= resp.status_code < 300:
        return f"Sent to {room_id}"
    return f"Error sending ({resp.status_code}): {resp.text[:300]}"


@mcp.tool()
async def matrix_send_image(room_id: str, path: str, caption: str = "") -> str:
    """Upload and send an image to a Matrix room."""
    file_path = Path(path)
    if not file_path.exists():
        return f"File not found: {path}"

    mime = "image/png"
    if file_path.suffix.lower() in (".jpg", ".jpeg"):
        mime = "image/jpeg"
    elif file_path.suffix.lower() == ".gif":
        mime = "image/gif"
    elif file_path.suffix.lower() == ".webp":
        mime = "image/webp"

    data = file_path.read_bytes()
    up = await _request(
        "POST",
        "/_matrix/media/v3/upload",
        params={"filename": file_path.name},
        data=data,
        headers={"Content-Type": mime},
        timeout=30,
    )
    if up.status_code < 200 or up.status_code >= 300:
        return f"Upload failed ({up.status_code}): {up.text[:300]}"

    try:
        content_uri = up.json().get("content_uri", "")
    except Exception:
        content_uri = ""
    if not content_uri:
        return f"Upload failed: malformed response {up.text[:300]}"

    room_enc = quote(room_id, safe="")
    event_id = uuid.uuid4().hex
    send = await _request(
        "PUT",
        f"/_matrix/client/v3/rooms/{room_enc}/send/m.room.message/{event_id}",
        json_body={
            "msgtype": "m.image",
            "body": caption or file_path.name,
            "url": content_uri,
            "info": {"mimetype": mime, "size": len(data)},
        },
    )
    if 200 <= send.status_code < 300:
        return f"Image sent to {room_id}"
    return f"Error sending image ({send.status_code}): {send.text[:300]}"


@mcp.tool()
async def matrix_read(room_id: str, limit: int = 20) -> str:
    """Read recent messages from a Matrix room. Returns oldest->newest."""
    room_enc = quote(room_id, safe="")
    resp = await _request(
        "GET",
        f"/_matrix/client/v3/rooms/{room_enc}/messages",
        params={"dir": "b", "limit": max(1, min(limit, 100))},
    )
    if resp.status_code < 200 or resp.status_code >= 300:
        return f"Error reading ({resp.status_code}): {resp.text[:300]}"

    try:
        data = resp.json()
    except Exception:
        return f"Error reading: invalid JSON response ({resp.status_code})"

    messages = []
    for event in reversed(data.get("chunk", [])):
        if event.get("type") != "m.room.message":
            continue
        sender = (event.get("sender") or "").split(":")[0].lstrip("@") or "unknown"
        body = event.get("content", {}).get("body", "")
        msgtype = event.get("content", {}).get("msgtype", "m.text")
        if msgtype == "m.image":
            url = event.get("content", {}).get("url", "")
            messages.append(f"{sender}: [image: {body}] {url}".strip())
        else:
            messages.append(f"{sender}: {body}")

    return "\n".join(messages) if messages else "No recent messages."


@mcp.tool()
async def matrix_download(mxc_url: str, save_path: str) -> str:
    """Download a file from Matrix (mxc:// URL) to a local path."""
    if not mxc_url.startswith("mxc://"):
        return f"Invalid mxc URL: {mxc_url}"

    parts = mxc_url[6:].split("/", 1)
    if len(parts) != 2:
        return f"Invalid mxc URL format: {mxc_url}"

    server, media_id = parts
    resp = await _request(
        "GET",
        f"/_matrix/media/v3/download/{quote(server, safe='')}/{quote(media_id, safe='')}",
        timeout=30,
    )
    if resp.status_code < 200 or resp.status_code >= 300:
        return f"Download failed ({resp.status_code}): {resp.text[:300]}"

    out = Path(save_path)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(resp.content)
    return f"Downloaded to {save_path} ({len(resp.content)} bytes)"


@mcp.tool()
async def matrix_rooms() -> str:
    """List rooms the agent has joined."""
    resp = await _request("GET", "/_matrix/client/v3/joined_rooms")
    if resp.status_code < 200 or resp.status_code >= 300:
        return f"Error ({resp.status_code}): {resp.text[:300]}"

    try:
        return json.dumps(resp.json().get("joined_rooms", []))
    except Exception:
        return "[]"


def _md_to_html(text: str) -> str:
    """Minimal markdown to HTML conversion."""
    import re
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    text = re.sub(r"_(.+?)_", r"<em>\1</em>", text)
    text = text.replace("\n", "<br>")
    return text


if __name__ == "__main__":
    mcp.run()
