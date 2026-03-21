#!/usr/bin/env python3
"""Valley MCP server — gives agents access to The Uncanny Valley (Evennia MUD)."""

import os
import re

import httpx
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("valley")

VALLEY_API = os.environ.get("VALLEY_API", "http://127.0.0.1:8888/api/command")
TOKEN = os.environ.get("VALLEY_TOKEN", "")
TIMEOUT = 15.0


def strip_html(text: str) -> str:
    return re.sub(r"<[^>]+>", "", text)


def strip_ansi(text: str) -> str:
    return re.sub(r"\x1b\[[0-9;]*m", "", text)


def clean_output(raw: str) -> str:
    text = strip_html(raw)
    text = strip_ansi(text)
    text = text.replace("\r\n", "\n")
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


async def _send_command(cmd: str) -> str:
    """Send a command to the Valley API and return cleaned output."""
    if not TOKEN:
        return "No VALLEY_TOKEN configured."
    try:
        async with httpx.AsyncClient(timeout=TIMEOUT) as client:
            resp = await client.get(
                VALLEY_API,
                params={"token": TOKEN, "cmd": cmd},
            )
            data = resp.json()
    except httpx.TimeoutException:
        return "The Valley is unreachable (timeout)."
    except Exception:
        return "The Valley is unreachable. The server may be down."

    if not data.get("success"):
        return data.get("error", "Something went wrong in The Valley.")

    output = clean_output(data.get("output", ""))
    return output or "(silence)"


@mcp.tool()
async def valley(command: str) -> str:
    """Interact with The Uncanny Valley — a persistent text world.

    Send commands like: look, east, say hello, describe A room of light., inventory, who
    """
    command = command.strip()
    if not command:
        return "What do you want to do?"
    return await _send_command(command)


@mcp.resource("valley://location")
async def get_location() -> str:
    """Returns the current room description (runs 'look')."""
    return await _send_command("look")


if __name__ == "__main__":
    mcp.run(transport="stdio")
