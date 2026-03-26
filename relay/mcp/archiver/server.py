#!/usr/bin/env python3
"""Archiver MCP server for semantic archive retrieval."""

import os
import httpx
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("archiver")
BASE = os.environ.get("ARCHIVER_URL", "http://10.0.0.2:4010").rstrip("/")
API_KEY = os.environ.get("ARCHIVER_API_KEY", "")


def _headers():
    h = {}
    if API_KEY:
        h["x-api-key"] = API_KEY
    return h


@mcp.tool()
async def archiver_search(query: str, k: int = 5, path_prefix: str = "") -> str:
    """Semantic search across archived sessions/docs.

    Args:
      query: search text
      k: number of matches (1-25)
      path_prefix: optional path filter (e.g. '/var/lib/neoclaw/workspaces/ellis-')
    """
    k = max(1, min(int(k), 25))
    params = {"q": query, "k": k}
    if path_prefix:
        params["path_prefix"] = path_prefix
    async with httpx.AsyncClient(timeout=20) as c:
        r = await c.get(f"{BASE}/search", params=params, headers=_headers())
    if r.status_code != 200:
        return f"error: {r.status_code} {r.text[:300]}"
    data = r.json()
    lines = []
    for i, it in enumerate(data.get("results", []), start=1):
        lines.append(f"{i}. score={it.get('score',0):.3f} path={it.get('path')} chunk={it.get('chunk')}\n{it.get('text','')[:500]}")
    return "\n\n".join(lines) if lines else "No results."


@mcp.tool()
async def archiver_reindex(limit_files: int = 0) -> str:
    """Trigger reindex. limit_files=0 means full."""
    body = {"limit_files": max(0, int(limit_files))}
    async with httpx.AsyncClient(timeout=120) as c:
        r = await c.post(f"{BASE}/reindex", json=body, headers=_headers())
    if r.status_code != 200:
        return f"error: {r.status_code} {r.text[:300]}"
    return str(r.json())


if __name__ == "__main__":
    mcp.run()
