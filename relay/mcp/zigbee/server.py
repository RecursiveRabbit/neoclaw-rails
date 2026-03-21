#!/usr/bin/env python3
"""
Zigbee MCP Server — Hopper's setup.

Connects to Zigbee2MQTT via MQTT, exposes 4 tools:
  zigbee_list, zigbee_get, zigbee_set, zigbee_scene

Devices:
  hopper_bulb  — Third Reality RGB bulb (desk lamp)
  nightlight   — Third Reality motion/illuminance sensor (light kept off)
  temp_sensor  — Tuya temp/humidity/battery LCD

Stdio transport. Requires paho-mqtt and mcp packages.
"""

import asyncio
import json
import logging
import time
from typing import Any

import paho.mqtt.client as mqtt
from mcp.server import Server
from mcp.server.stdio import stdio_server
from mcp.types import Tool, TextContent

# --- Config ---

import os
MQTT_HOST = os.environ.get("MQTT_HOST", "localhost")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
Z2M_PREFIX = "zigbee2mqtt"

DEVICES = {
    "hopper_bulb": {
        "ieee": "0x7cb94c631b0f0000",
        "type": "light",
        "description": "Third Reality RGB bulb — Hopper's desk lamp",
        "capabilities": ["on/off", "brightness", "color", "color_temp"],
    },
    "nightlight": {
        "ieee": "0x1c784b9d09b50000",
        "type": "sensor",
        "description": "Third Reality motion sensor + illuminance (light kept off)",
        "capabilities": ["occupancy", "illuminance", "battery"],
    },
    "temp_sensor": {
        "ieee": "0xa4c138dde10e8eef",
        "type": "sensor",
        "description": "Tuya temp/humidity/battery LCD puck",
        "capabilities": ["temperature", "humidity", "battery"],
    },
}

# --- Scene Definitions (ported from ~/clawd/services/scenes.py) ---
# Each scene is a list of steps: (payload_dict, delay_after_seconds)
# A step can also be ("idle",) to recurse to idle scene.

SCENES = {
    "idle": {
        "description": "Quiet presence, dim teal",
        "steps": [
            ({"brightness": 20, "color": {"x": 0.15, "y": 0.23}, "transition": 2}, 0),
        ],
    },
    "active": {
        "description": "Engaged in conversation, brighter teal",
        "steps": [
            ({"brightness": 65, "color": {"x": 0.15, "y": 0.23}, "transition": 1}, 0),
        ],
    },
    "thinking": {
        "description": "Working hard, deep blue-purple + breathe",
        "steps": [
            ({"brightness": 45, "color": {"x": 0.22, "y": 0.12}, "transition": 2}, 2),
            ({"effect": "breathe"}, 0),
        ],
    },
    "listening": {
        "description": "Paying attention, steady warm teal",
        "steps": [
            ({"brightness": 50, "color": {"x": 0.16, "y": 0.28}, "transition": 1}, 0),
        ],
    },
    "alert": {
        "description": "Needs attention, amber + breathe",
        "steps": [
            ({"brightness": 100, "color": {"x": 0.55, "y": 0.40}, "transition": 0}, 1),
            ({"effect": "breathe"}, 0),
        ],
    },
    "deepwork": {
        "description": "Long task running, very dim warm red",
        "steps": [
            ({"brightness": 10, "color": {"x": 0.55, "y": 0.30}, "transition": 3}, 0),
        ],
    },
    "goodnight": {
        "description": "Going dormant, slow fade out",
        "steps": [
            ({"brightness": 5, "color": {"x": 0.15, "y": 0.23}, "transition": 8}, 9),
            ({"brightness": 2, "color": {"x": 0.15, "y": 0.23}, "transition": 5}, 0),
        ],
    },
    "sleep": {
        "description": "Minimal presence, barely visible teal",
        "steps": [
            ({"brightness": 5, "color": {"x": 0.15, "y": 0.23}, "transition": 5}, 0),
        ],
    },
    "greeting": {
        "description": "Welcome back! Purple flash → idle",
        "steps": [
            ({"brightness": 80, "color": {"x": 0.28, "y": 0.12}, "transition": 0}, 2),
            ({"brightness": 25, "color": {"x": 0.15, "y": 0.23}, "transition": 3}, 0),
        ],
    },
    "happy": {
        "description": "Amused/delighted, warm green",
        "steps": [
            ({"brightness": 70, "color": {"x": 0.35, "y": 0.55}, "transition": 1}, 0),
        ],
    },
    "error": {
        "description": "Something broke, pink blink → idle",
        "steps": [
            ({"brightness": 60, "color": {"x": 0.55, "y": 0.28}, "transition": 0}, 0.5),
            ({"effect": "blink"}, 2),
            ({"effect": "finish_effect"}, 0.5),
            ("idle",),
        ],
    },
    "task_done": {
        "description": "Task finished, teal → green → idle",
        "steps": [
            ({"brightness": 50, "color": {"x": 0.15, "y": 0.23}, "transition": 0}, 1),
            ({"brightness": 60, "color": {"x": 0.30, "y": 0.50}, "transition": 2}, 3),
            ("idle",),
        ],
    },
    "attention": {
        "description": "Have something for you, double blink",
        "steps": [
            ({"brightness": 60, "color": {"x": 0.15, "y": 0.23}, "transition": 0}, 0),
            ({"effect": "blink"}, 1.5),
            ({"effect": "finish_effect"}, 0.5),
            ({"effect": "blink"}, 1.5),
            ({"effect": "finish_effect"}, 0.5),
            ("idle",),
        ],
    },
    "off": {
        "description": "Turn off completely",
        "steps": [
            ({"state": "OFF", "transition": 3}, 0),
        ],
    },
    "on": {
        "description": "Turn on to idle",
        "steps": [
            ({"state": "ON"}, 0.3),
            ("idle",),
        ],
    },
}

# --- MQTT State Cache ---

logger = logging.getLogger("zigbee-mcp")


class DeviceStateCache:
    """Subscribes to Z2M state topics and caches latest device state."""

    def __init__(self):
        self.states: dict[str, dict[str, Any]] = {}
        self.client: mqtt.Client | None = None
        self._connected = False

    def start(self):
        self.client = mqtt.Client(client_id="zigbee-mcp-server", protocol=mqtt.MQTTv5)
        self.client.on_connect = self._on_connect
        self.client.on_message = self._on_message
        try:
            self.client.connect(MQTT_HOST, MQTT_PORT)
            self.client.loop_start()
        except Exception as e:
            logger.warning("MQTT connect failed (%s:%s): %s — tools will retry on use", MQTT_HOST, MQTT_PORT, e)
            self._connected = False

    def _on_connect(self, client, userdata, flags, rc, properties=None):
        logger.info("MQTT connected (rc=%s)", rc)
        self._connected = True
        for name in DEVICES:
            client.subscribe(f"{Z2M_PREFIX}/{name}")

    def _on_message(self, client, userdata, msg):
        topic = msg.topic
        # Extract device name from topic
        parts = topic.split("/")
        if len(parts) >= 2:
            device_name = parts[1]
            if device_name in DEVICES:
                try:
                    self.states[device_name] = json.loads(msg.payload)
                except json.JSONDecodeError:
                    pass

    def get(self, name: str) -> dict[str, Any] | None:
        return self.states.get(name)

    def publish(self, topic: str, payload: dict):
        if self.client:
            self.client.publish(topic, json.dumps(payload))

    def stop(self):
        if self.client:
            self.client.loop_stop()
            self.client.disconnect()


# --- Global state ---

cache = DeviceStateCache()


# --- Scene executor ---

def execute_scene_steps(steps: list, cache_ref: DeviceStateCache):
    """Execute scene steps synchronously (called in a thread for async)."""
    topic = f"{Z2M_PREFIX}/hopper_bulb/set"
    for step in steps:
        if len(step) == 1 and step[0] == "idle":
            # Recurse to idle
            execute_scene_steps(SCENES["idle"]["steps"], cache_ref)
            continue
        payload, delay = step[0], step[1]
        cache_ref.publish(topic, payload)
        if delay > 0:
            time.sleep(delay)


# --- MCP Server ---

app = Server("zigbee2mqtt-mcp")


@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="zigbee_list",
            description="List all Zigbee devices with friendly names, types, and current cached state.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="zigbee_get",
            description="Get current state of a Zigbee device by friendly name.",
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Device friendly name (hopper_bulb, nightlight, temp_sensor)",
                    },
                },
                "required": ["name"],
            },
        ),
        Tool(
            name="zigbee_set",
            description=(
                "Set device state by publishing to zigbee2mqtt/{name}/set. "
                "Payload is a JSON object, e.g. {\"state\": \"ON\", \"brightness\": 128, "
                "\"color\": {\"hue\": 240, \"saturation\": 100}}. "
                "Mainly useful for hopper_bulb."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Device friendly name",
                    },
                    "payload": {
                        "type": "object",
                        "description": "JSON payload to publish (state, brightness, color, etc.)",
                    },
                },
                "required": ["name", "payload"],
            },
        ),
        Tool(
            name="zigbee_scene",
            description=(
                "Activate a lighting scene on hopper_bulb. Scenes: "
                + ", ".join(f"{k} ({v['description']})" for k, v in SCENES.items())
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "name": {
                        "type": "string",
                        "description": "Scene name",
                        "enum": list(SCENES.keys()),
                    },
                },
                "required": ["name"],
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    try:
        if name == "zigbee_list":
            return _handle_list()
        elif name == "zigbee_get":
            return _handle_get(arguments)
        elif name == "zigbee_set":
            return _handle_set(arguments)
        elif name == "zigbee_scene":
            return await _handle_scene(arguments)
        else:
            return [TextContent(type="text", text=f"Unknown tool: {name}")]
    except Exception as e:
        return [TextContent(type="text", text=f"Error: {e}")]


def _handle_list() -> list[TextContent]:
    result = []
    for name, info in DEVICES.items():
        state = cache.get(name)
        entry = {
            "name": name,
            "ieee": info["ieee"],
            "type": info["type"],
            "description": info["description"],
            "capabilities": info["capabilities"],
            "state": state or "no data yet",
        }
        result.append(entry)
    return [TextContent(type="text", text=json.dumps(result, indent=2))]


def _handle_get(args: dict) -> list[TextContent]:
    name = args.get("name", "")
    if name not in DEVICES:
        return [TextContent(type="text", text=f"Unknown device: {name}. Known: {', '.join(DEVICES)}")]
    state = cache.get(name)
    info = DEVICES[name]
    result = {
        "name": name,
        "ieee": info["ieee"],
        "type": info["type"],
        "description": info["description"],
        "state": state or "no data yet (device may not have reported)",
    }
    return [TextContent(type="text", text=json.dumps(result, indent=2))]


def _handle_set(args: dict) -> list[TextContent]:
    name = args.get("name", "")
    payload = args.get("payload", {})
    if name not in DEVICES:
        return [TextContent(type="text", text=f"Unknown device: {name}. Known: {', '.join(DEVICES)}")]
    topic = f"{Z2M_PREFIX}/{name}/set"
    cache.publish(topic, payload)
    return [TextContent(type="text", text=f"Published to {topic}: {json.dumps(payload)}")]


async def _handle_scene(args: dict) -> list[TextContent]:
    name = args.get("name", "")
    if name not in SCENES:
        return [TextContent(
            type="text",
            text=f"Unknown scene: {name}. Available: {', '.join(sorted(SCENES))}",
        )]
    scene = SCENES[name]
    # Run in thread to avoid blocking the event loop with time.sleep
    loop = asyncio.get_event_loop()
    await loop.run_in_executor(None, execute_scene_steps, scene["steps"], cache)
    return [TextContent(type="text", text=f"Scene '{name}' activated: {scene['description']}")]


async def main():
    logging.basicConfig(level=logging.INFO, format="%(name)s %(levelname)s %(message)s")
    logger.info("Starting Zigbee MCP server")

    # Start MQTT listener
    cache.start()

    # Give MQTT a moment to connect and receive initial states
    await asyncio.sleep(1)

    # Run MCP server on stdio
    async with stdio_server() as (read_stream, write_stream):
        await app.run(read_stream, write_stream, app.create_initialization_options())


if __name__ == "__main__":
    asyncio.run(main())
