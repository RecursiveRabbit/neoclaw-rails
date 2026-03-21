#!/usr/bin/env python3
"""Matrix MCP server — gives agents Matrix communication tools."""

import asyncio
import json
import os
import sys
from pathlib import Path

from mcp.server.fastmcp import FastMCP
from nio import (
    AsyncClient,
    RoomMessageText,
    RoomMessageImage,
    RoomSendResponse,
    RoomMessagesResponse,
    JoinedRoomsResponse,
    UploadResponse,
)

mcp = FastMCP("matrix")

HOMESERVER = os.environ.get("MATRIX_HOMESERVER", "http://localhost:8008")
USER_ID = os.environ.get("MATRIX_USER_ID", "")
TOKEN = os.environ.get("MATRIX_TOKEN", "")

_client = None


async def get_client() -> AsyncClient:
    global _client
    if _client is None:
        _client = AsyncClient(HOMESERVER, USER_ID)
        _client.access_token = TOKEN
    return _client


@mcp.tool()
async def matrix_send(room_id: str, message: str) -> str:
    """Send a message to a Matrix room. Supports markdown formatting."""
    client = await get_client()
    resp = await client.room_send(
        room_id,
        message_type="m.room.message",
        content={
            "msgtype": "m.text",
            "body": message,
            "format": "org.matrix.custom.html",
            "formatted_body": _md_to_html(message),
        },
    )
    if isinstance(resp, RoomSendResponse):
        return f"Sent to {room_id}"
    return f"Error sending: {resp}"


@mcp.tool()
async def matrix_send_image(room_id: str, path: str, caption: str = "") -> str:
    """Upload and send an image to a Matrix room."""
    client = await get_client()
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
    upload_resp = await client.upload(data, content_type=mime, filename=file_path.name)
    if not isinstance(upload_resp, UploadResponse):
        return f"Upload failed: {upload_resp}"

    content = {
        "msgtype": "m.image",
        "body": caption or file_path.name,
        "url": upload_resp.content_uri,
        "info": {"mimetype": mime, "size": len(data)},
    }
    resp = await client.room_send(room_id, message_type="m.room.message", content=content)
    if isinstance(resp, RoomSendResponse):
        return f"Image sent to {room_id}"
    return f"Error: {resp}"


@mcp.tool()
async def matrix_read(room_id: str, limit: int = 20) -> str:
    """Read recent messages from a Matrix room. Returns newest first."""
    client = await get_client()
    resp = await client.room_messages(room_id, start="", limit=limit, direction="b")
    if not isinstance(resp, RoomMessagesResponse):
        return f"Error reading: {resp}"

    messages = []
    for event in reversed(resp.chunk):
        sender = event.sender.split(":")[0].lstrip("@")
        if isinstance(event, RoomMessageText):
            messages.append(f"{sender}: {event.body}")
        elif isinstance(event, RoomMessageImage):
            url = event.url or ""
            messages.append(f"{sender}: [image: {event.body}] {url}")
        # skip other event types

    return "\n".join(messages) if messages else "No recent messages."


@mcp.tool()
async def matrix_download(mxc_url: str, save_path: str) -> str:
    """Download a file from Matrix (mxc:// URL) to a local path."""
    client = await get_client()
    # Parse mxc://server/media_id
    if not mxc_url.startswith("mxc://"):
        return f"Invalid mxc URL: {mxc_url}"

    parts = mxc_url[6:].split("/", 1)
    if len(parts) != 2:
        return f"Invalid mxc URL format: {mxc_url}"

    server, media_id = parts
    resp = await client.download(server, media_id)
    if hasattr(resp, "body"):
        out = Path(save_path)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(resp.body)
        return f"Downloaded to {save_path} ({len(resp.body)} bytes)"
    return f"Download failed: {resp}"


@mcp.tool()
async def matrix_rooms() -> str:
    """List rooms the agent has joined."""
    client = await get_client()
    resp = await client.joined_rooms()
    if isinstance(resp, JoinedRoomsResponse):
        return json.dumps(resp.rooms)
    return f"Error: {resp}"


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
