#!/usr/bin/env python3
"""
MCP Server for SSH Terminal Access.

Provides Claude with direct terminal access via SSH.
Run this server and add it to your Claude Code MCP configuration.
"""

import argparse
import json
import sys
from typing import Any

from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import (
    Resource,
    TextContent,
    Tool,
)

from ssh_session import SSHSession, SessionConfig

# Global session - persists across tool calls
session = SSHSession()

# Server instance
server = Server("ssh-terminal")


@server.list_tools()
async def list_tools() -> list[Tool]:
    """List available SSH terminal tools."""
    return [
        Tool(
            name="ssh_connect",
            description="Connect to an SSH server. Must be called before using other SSH tools.",
            inputSchema={
                "type": "object",
                "properties": {
                    "host": {
                        "type": "string",
                        "description": "SSH server hostname or IP"
                    },
                    "username": {
                        "type": "string",
                        "description": "SSH username"
                    },
                    "password": {
                        "type": "string",
                        "description": "SSH password (optional if using key)"
                    },
                    "key_path": {
                        "type": "string",
                        "description": "Path to SSH private key (optional if using password)"
                    },
                    "port": {
                        "type": "integer",
                        "description": "SSH port (default: 22)",
                        "default": 22
                    }
                },
                "required": ["host", "username"]
            }
        ),
        Tool(
            name="ssh_disconnect",
            description="Disconnect from the current SSH session.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        Tool(
            name="ssh_execute",
            description=(
                "Execute a command in the SSH terminal and return the output. "
                "Waits for the command to complete (up to 90 seconds). "
                "Long-running processes will be automatically backgrounded."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "command": {
                        "type": "string",
                        "description": "The bash command to execute"
                    }
                },
                "required": ["command"]
            }
        ),
        Tool(
            name="ssh_interrupt",
            description="Send Ctrl+C to interrupt the current process.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        Tool(
            name="ssh_eof",
            description="Send Ctrl+D (EOF) to the terminal. Useful for exiting REPLs or signaling end of input.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        Tool(
            name="ssh_background",
            description="Send Ctrl+Z then 'bg' to background the current foreground process.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
        Tool(
            name="ssh_send_raw",
            description=(
                "Send raw data to the terminal. Supports escape sequences like \\x03 for Ctrl+C. "
                "Use for special key sequences or interactive input."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "data": {
                        "type": "string",
                        "description": "Raw data to send (escape sequences like \\x03 are interpreted)"
                    }
                },
                "required": ["data"]
            }
        ),
        Tool(
            name="ssh_status",
            description="Check the current SSH connection status.",
            inputSchema={
                "type": "object",
                "properties": {}
            }
        ),
    ]


@server.call_tool()
async def call_tool(name: str, arguments: dict[str, Any]) -> list[TextContent]:
    """Handle tool calls."""

    if name == "ssh_connect":
        config = SessionConfig(
            host=arguments["host"],
            username=arguments["username"],
            password=arguments.get("password"),
            key_path=arguments.get("key_path"),
            port=arguments.get("port", 22),
        )
        try:
            initial_output = session.connect(config)
            return [TextContent(
                type="text",
                text=f"Connected to {config.host} as {config.username}\n\n{initial_output}"
            )]
        except Exception as e:
            return [TextContent(type="text", text=f"Connection failed: {e}")]

    elif name == "ssh_disconnect":
        session.disconnect()
        return [TextContent(type="text", text="Disconnected from SSH session.")]

    elif name == "ssh_execute":
        command = arguments["command"]
        output = session.execute(command)
        return [TextContent(type="text", text=output)]

    elif name == "ssh_interrupt":
        output = session.send_interrupt()
        return [TextContent(type="text", text=output)]

    elif name == "ssh_eof":
        output = session.send_eof()
        return [TextContent(type="text", text=output)]

    elif name == "ssh_background":
        output = session.background_process()
        return [TextContent(type="text", text=output)]

    elif name == "ssh_send_raw":
        data = arguments["data"]
        output = session.send_raw(data)
        return [TextContent(type="text", text=output)]

    elif name == "ssh_status":
        if session.is_connected:
            status = f"Connected to {session.config.host} as {session.config.username}"
        else:
            status = "Not connected"
        return [TextContent(type="text", text=status)]

    else:
        return [TextContent(type="text", text=f"Unknown tool: {name}")]


@server.list_resources()
async def list_resources() -> list[Resource]:
    """List available resources."""
    return [
        Resource(
            uri="terminal://buffer",
            name="Terminal Buffer",
            description="Recent terminal output (last 8000 characters)",
            mimeType="text/plain"
        ),
        Resource(
            uri="terminal://status",
            name="Connection Status",
            description="Current SSH connection status",
            mimeType="text/plain"
        ),
    ]


@server.read_resource()
async def read_resource(uri: str) -> str:
    """Read a resource."""
    if uri == "terminal://buffer":
        if session.is_connected:
            return session.get_buffer()
        return "[Not connected]"

    elif uri == "terminal://status":
        if session.is_connected:
            return f"Connected to {session.config.host} as {session.config.username}"
        return "Not connected"

    return f"Unknown resource: {uri}"


async def main():
    """Run the MCP server."""
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            server.create_initialization_options()
        )


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
