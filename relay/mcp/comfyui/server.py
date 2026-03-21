#!/usr/bin/env python3
"""Parallax's ComfyUI MCP Server.

A thin MCP wrapper around ComfyUI's HTTP API, carrying forward all the
workflow-building logic from generate.py. Designed for NanoClaw containers.

Transport: stdio (default) or SSE via --sse flag.
Expects ComfyUI at COMFYUI_URL env var (default http://localhost:8188).

Usage:
  # stdio (for MCP clients like Claude Code)
  python comfyui_mcp.py

  # SSE (for networked MCP clients)  
  python comfyui_mcp.py --sse --port 9100
"""

import os
import sys
import json
import time
import random
import shutil
import urllib.request
import urllib.error
from typing import Optional

from mcp.server import Server
from mcp.types import Tool, TextContent

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

COMFYUI_URL = os.environ.get("COMFYUI_URL", "http://localhost:8188")
OUTPUT_DIR = os.environ.get("COMFYUI_OUTPUT_DIR", "/home/hopper/comfy/ComfyUI/output")
WORKFLOW_TEMPLATE = os.environ.get(
    "COMFYUI_WORKFLOW_TEMPLATE",
    "/home/hopper/comfyui/workflows/flux2_klein_4b_api.json",
)
POLL_TIMEOUT = int(os.environ.get("COMFYUI_POLL_TIMEOUT", "120"))

# Aspect ratio presets → (width, height) at ~1 megapixel
ASPECTS = {
    "1:1": (1024, 1024),
    "3:2": (1248, 832),
    "2:3": (832, 1248),
    "4:3": (1184, 888),
    "3:4": (888, 1184),
    "16:9": (1360, 768),
    "9:16": (768, 1360),
    "21:9": (1536, 656),
    "9:21": (656, 1536),
    "2:1": (1440, 720),
    "1:2": (720, 1440),
    "5:4": (1136, 912),
    "4:5": (912, 1136),
}

LORA_SHORTCUTS = {
    "ghibli": "Dark_Ghibli_Fairytales_Klein4B.safetensors",
    "pencil": "Hyperdetailed_Colored_Pencil_Klein4B.safetensors",
    "80s": "80s_Fantasy_Movie_Klein4B.safetensors",
}

# ---------------------------------------------------------------------------
# Helpers (lifted from generate.py)
# ---------------------------------------------------------------------------


def round8(n: int) -> int:
    return int(round(n / 8) * 8)


def resolve_dimensions(aspect: str = "1:1", width: int = 0, height: int = 0) -> tuple[int, int]:
    """Resolve width/height from explicit values or aspect ratio string."""
    if width and height:
        return round8(width), round8(height)
    if aspect in ASPECTS:
        return ASPECTS[aspect]
    try:
        a, b = aspect.split(":")
        ratio = float(a) / float(b)
        pixels = 1024 * 1024
        h = int((pixels / ratio) ** 0.5)
        w = int(h * ratio)
        return round8(w), round8(h)
    except Exception:
        return 1024, 1024


def resolve_lora(name: str) -> str:
    """Resolve LoRA shortcut names to full filenames."""
    return LORA_SHORTCUTS.get(name.lower(), name)


def inject_lora(w: dict, lora_name: str, strength: float = 1.0) -> dict:
    """Inject a LoRA loader node between UNET/CLIP loaders and sampler/encoder."""
    w["9"] = {
        "class_type": "LoraLoader",
        "inputs": {
            "model": ["1", 0],
            "clip": ["2", 0],
            "lora_name": lora_name,
            "strength_model": strength,
            "strength_clip": strength,
        },
    }
    w["6"]["inputs"]["model"] = ["9", 0]
    w["4"]["inputs"]["clip"] = ["9", 1]
    return w


def parse_regions(regions_str: str, width: int, height: int) -> list[dict]:
    """Parse region specs like 'left;right' or 'top;bottom'."""
    parts = [r.strip().lower() for r in regions_str.split(";")]
    n = len(parts)

    if all(p in ("left", "right", "center") for p in parts):
        seg_w = width // n
        return [{"x": i * seg_w, "y": 0, "w": seg_w, "h": height} for i in range(n)]
    elif all(p in ("top", "bottom", "middle") for p in parts):
        seg_h = height // n
        return [{"x": 0, "y": i * seg_h, "w": width, "h": seg_h} for i in range(n)]
    else:
        # Try x,y,w,h percentages
        specs = []
        for p in parts:
            try:
                vals = [float(v) for v in p.split(",")]
                if len(vals) == 4:
                    specs.append({
                        "x": round8(int(vals[0] / 100 * width)),
                        "y": round8(int(vals[1] / 100 * height)),
                        "w": round8(int(vals[2] / 100 * width)),
                        "h": round8(int(vals[3] / 100 * height)),
                    })
                else:
                    raise ValueError
            except Exception:
                seg_w = width // n
                return [{"x": i * seg_w, "y": 0, "w": seg_w, "h": height} for i in range(n)]
        return specs


def build_workflow(
    prompt_text: str,
    prefix: str = "parallax",
    seed: int = 42,
    width: int = 1024,
    height: int = 1024,
    steps: int = 4,
    lora: Optional[str] = None,
    lora_strength: float = 1.0,
) -> dict:
    """Build a standard single-prompt workflow from the template."""
    with open(WORKFLOW_TEMPLATE) as f:
        w = json.load(f)
    w["4"]["inputs"]["text"] = prompt_text
    w["5"]["inputs"]["width"] = width
    w["5"]["inputs"]["height"] = height
    w["6"]["inputs"]["seed"] = seed
    w["6"]["inputs"]["steps"] = steps
    w["8"]["inputs"]["filename_prefix"] = prefix
    if lora:
        inject_lora(w, resolve_lora(lora), lora_strength)
    return w


def build_regional_workflow(
    prompts: list[str],
    regions: str,
    prefix: str = "parallax",
    seed: int = 42,
    width: int = 1024,
    height: int = 1024,
    steps: int = 4,
    lora: Optional[str] = None,
    lora_strength: float = 1.0,
) -> dict:
    """Build a workflow with regional prompting via ConditioningSetArea + ConditioningCombine."""
    with open(WORKFLOW_TEMPLATE) as f:
        base = json.load(f)

    w = {}
    w["1"] = base["1"]  # UNETLoader
    w["2"] = base["2"]  # CLIPLoader
    w["3"] = base["3"]  # VAELoader
    w["5"] = base["5"]  # EmptyLatentImage
    w["5"]["inputs"]["width"] = width
    w["5"]["inputs"]["height"] = height

    region_specs = parse_regions(regions, width, height)
    # Pad prompts to match regions
    while len(prompts) < len(region_specs):
        prompts.append(prompts[-1])

    node_id = 10
    cond_nodes = []

    for i, (prompt, spec) in enumerate(zip(prompts, region_specs)):
        encode_id = str(node_id)
        w[encode_id] = {
            "class_type": "CLIPTextEncode",
            "inputs": {"text": prompt.strip(), "clip": ["2", 0]},
        }
        node_id += 1

        area_id = str(node_id)
        w[area_id] = {
            "class_type": "ConditioningSetArea",
            "inputs": {
                "conditioning": [encode_id, 0],
                "x": spec["x"],
                "y": spec["y"],
                "width": spec["w"],
                "height": spec["h"],
                "strength": spec.get("strength", 1.0),
            },
        }
        cond_nodes.append(area_id)
        node_id += 1

    # Chain ConditioningCombine
    if len(cond_nodes) == 1:
        final_cond = cond_nodes[0]
    else:
        prev = cond_nodes[0]
        for cn in cond_nodes[1:]:
            combine_id = str(node_id)
            w[combine_id] = {
                "class_type": "ConditioningCombine",
                "inputs": {
                    "conditioning_1": [prev, 0],
                    "conditioning_2": [cn, 0],
                },
            }
            prev = combine_id
            node_id += 1
        final_cond = prev

    w["6"] = dict(base["6"])
    w["6"]["inputs"] = dict(base["6"]["inputs"])
    w["6"]["inputs"]["positive"] = [final_cond, 0]
    w["6"]["inputs"]["negative"] = [final_cond, 0]
    w["6"]["inputs"]["seed"] = seed
    w["6"]["inputs"]["steps"] = steps
    w["6"]["inputs"]["latent_image"] = ["5", 0]
    w["6"]["inputs"]["model"] = ["1", 0]

    w["7"] = base["7"]  # VAEDecode
    w["8"] = dict(base["8"])
    w["8"]["inputs"] = dict(base["8"]["inputs"])
    w["8"]["inputs"]["filename_prefix"] = prefix

    if lora:
        inject_lora(w, resolve_lora(lora), lora_strength)

    return w


# ---------------------------------------------------------------------------
# ComfyUI HTTP API
# ---------------------------------------------------------------------------


def comfy_request(path: str, data: Optional[bytes] = None) -> dict:
    """Make a request to ComfyUI API. Returns parsed JSON."""
    url = f"{COMFYUI_URL}{path}"
    if data is not None:
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    else:
        req = urllib.request.Request(url)
    resp = urllib.request.urlopen(req)
    return json.loads(resp.read())


def queue_prompt(workflow: dict) -> str:
    """Queue a workflow, return prompt_id."""
    data = json.dumps({"prompt": workflow}).encode()
    resp = comfy_request("/prompt", data)
    return resp["prompt_id"]


def poll_until_done(prompt_id: str, timeout: int = POLL_TIMEOUT) -> Optional[str]:
    """Poll /history until the prompt completes. Returns output image path or None."""
    for _ in range(timeout):
        time.sleep(1)
        try:
            hist = comfy_request(f"/history/{prompt_id}")
        except urllib.error.URLError:
            continue
        if prompt_id in hist:
            outputs = hist[prompt_id].get("outputs", {})
            for node_out in outputs.values():
                if "images" in node_out:
                    img = node_out["images"][0]
                    return os.path.join(OUTPUT_DIR, img["filename"])
    return None


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------

app = Server("comfyui")


@app.list_tools()
async def list_tools() -> list[Tool]:
    return [
        Tool(
            name="generate_image",
            description=(
                "Generate an image using FLUX.2 Klein 4B via ComfyUI. "
                "Returns the output file path. Supports aspect ratios, LoRA models, "
                "regional prompting, and custom seeds."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "prompt": {
                        "type": "string",
                        "description": "Text prompt for image generation. For regional prompting, use semicolon-separated prompts.",
                    },
                    "prefix": {
                        "type": "string",
                        "description": "Output filename prefix. Default: parallax",
                        "default": "parallax",
                    },
                    "aspect": {
                        "type": "string",
                        "description": "Aspect ratio: 1:1, 3:2, 2:3, 4:3, 16:9, 9:16, etc. Default: 1:1",
                        "default": "1:1",
                    },
                    "width": {
                        "type": "integer",
                        "description": "Override width in pixels (rounded to multiple of 8). Overrides aspect.",
                    },
                    "height": {
                        "type": "integer",
                        "description": "Override height in pixels (rounded to multiple of 8). Overrides aspect.",
                    },
                    "steps": {
                        "type": "integer",
                        "description": "Inference steps. Default: 4. More = more detail.",
                        "default": 4,
                        "minimum": 1,
                        "maximum": 50,
                    },
                    "seed": {
                        "type": "integer",
                        "description": "Random seed for reproducibility. Random if omitted.",
                    },
                    "lora": {
                        "type": "string",
                        "description": "LoRA model. Shortcuts: ghibli, pencil, 80s. Or full .safetensors filename.",
                    },
                    "lora_strength": {
                        "type": "number",
                        "description": "LoRA strength 0.0-2.0. Default: 1.0",
                        "default": 1.0,
                    },
                    "regions": {
                        "type": "string",
                        "description": "Regional prompting layout, semicolon-separated: 'left;right', 'top;bottom', etc. Prompt must also be semicolon-separated.",
                    },
                    "batch": {
                        "type": "integer",
                        "description": "Number of images to generate with different seeds. Default: 1",
                        "default": 1,
                        "minimum": 1,
                        "maximum": 20,
                    },
                    "copy_to": {
                        "type": "string",
                        "description": "Copy output image(s) to this path.",
                    },
                },
                "required": ["prompt"],
            },
        ),
        Tool(
            name="run_workflow",
            description=(
                "Execute a raw ComfyUI workflow JSON. For when you need full control "
                "over the node graph. Returns the output image path."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "workflow": {
                        "type": "object",
                        "description": "Complete ComfyUI API-format workflow JSON (node id → node spec).",
                    },
                    "copy_to": {
                        "type": "string",
                        "description": "Copy output image to this path.",
                    },
                },
                "required": ["workflow"],
            },
        ),
        Tool(
            name="queue_status",
            description="Check ComfyUI queue status — how many prompts are pending/running.",
            inputSchema={"type": "object", "properties": {}},
        ),
        Tool(
            name="get_history",
            description="Get the status/output of a previously queued prompt by its ID.",
            inputSchema={
                "type": "object",
                "properties": {
                    "prompt_id": {
                        "type": "string",
                        "description": "The prompt_id returned from a generation call.",
                    },
                },
                "required": ["prompt_id"],
            },
        ),
        Tool(
            name="list_outputs",
            description="List recent output images from ComfyUI's output directory.",
            inputSchema={
                "type": "object",
                "properties": {
                    "prefix": {
                        "type": "string",
                        "description": "Filter by filename prefix.",
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Max files to return. Default: 20",
                        "default": 20,
                    },
                },
            },
        ),
    ]


@app.call_tool()
async def call_tool(name: str, arguments: dict) -> list[TextContent]:
    try:
        if name == "generate_image":
            return await _generate_image(arguments)
        elif name == "run_workflow":
            return await _run_workflow(arguments)
        elif name == "queue_status":
            return await _queue_status()
        elif name == "get_history":
            return await _get_history(arguments)
        elif name == "list_outputs":
            return await _list_outputs(arguments)
        else:
            return [TextContent(type="text", text=f"Unknown tool: {name}")]
    except Exception as e:
        return [TextContent(type="text", text=f"Error: {e}")]


async def _generate_image(args: dict) -> list[TextContent]:
    prompt = args["prompt"]
    prefix = args.get("prefix", "parallax")
    aspect = args.get("aspect", "1:1")
    width = args.get("width", 0)
    height = args.get("height", 0)
    steps = args.get("steps", 4)
    seed = args.get("seed")
    lora = args.get("lora")
    lora_strength = args.get("lora_strength", 1.0)
    regions = args.get("regions")
    batch = args.get("batch", 1)
    copy_to = args.get("copy_to")

    w, h = resolve_dimensions(aspect, width, height)

    results = []
    for i in range(batch):
        s = seed if (seed and batch == 1) else (seed + i if seed else random.randint(1, 999999999))

        if regions:
            prompts = prompt.split(";")
            workflow = build_regional_workflow(prompts, regions, prefix, s, w, h, steps, lora, lora_strength)
        else:
            workflow = build_workflow(prompt, prefix, s, w, h, steps, lora, lora_strength)

        prompt_id = queue_prompt(workflow)
        output_path = poll_until_done(prompt_id)

        if output_path:
            result = {"path": output_path, "seed": s, "prompt_id": prompt_id}
            if copy_to:
                if batch == 1:
                    dest = copy_to
                else:
                    base, ext = os.path.splitext(copy_to)
                    dest = f"{base}_{i+1}{ext}"
                shutil.copy2(output_path, dest)
                result["copied_to"] = dest
            results.append(result)
        else:
            results.append({"error": "Timed out or failed", "seed": s, "prompt_id": prompt_id})

    return [TextContent(type="text", text=json.dumps(results, indent=2))]


async def _run_workflow(args: dict) -> list[TextContent]:
    workflow = args["workflow"]
    copy_to = args.get("copy_to")

    prompt_id = queue_prompt(workflow)
    output_path = poll_until_done(prompt_id)

    if output_path:
        result = {"path": output_path, "prompt_id": prompt_id}
        if copy_to:
            shutil.copy2(output_path, copy_to)
            result["copied_to"] = copy_to
        return [TextContent(type="text", text=json.dumps(result, indent=2))]
    else:
        return [TextContent(type="text", text=json.dumps({"error": "Timed out", "prompt_id": prompt_id}))]


async def _queue_status() -> list[TextContent]:
    result = comfy_request("/queue")
    pending = len(result.get("queue_pending", []))
    running = len(result.get("queue_running", []))
    return [TextContent(type="text", text=json.dumps({"pending": pending, "running": running}))]


async def _get_history(args: dict) -> list[TextContent]:
    prompt_id = args["prompt_id"]
    hist = comfy_request(f"/history/{prompt_id}")
    if prompt_id in hist:
        entry = hist[prompt_id]
        outputs = {}
        for node_id, node_out in entry.get("outputs", {}).items():
            if "images" in node_out:
                outputs[node_id] = [
                    {"filename": img["filename"], "path": os.path.join(OUTPUT_DIR, img["filename"])}
                    for img in node_out["images"]
                ]
        status = entry.get("status", {})
        return [TextContent(type="text", text=json.dumps({"status": status, "outputs": outputs}, indent=2))]
    else:
        return [TextContent(type="text", text=json.dumps({"status": "not_found"}))]


async def _list_outputs(args: dict) -> list[TextContent]:
    prefix = args.get("prefix", "")
    limit = args.get("limit", 20)

    try:
        files = os.listdir(OUTPUT_DIR)
    except OSError as e:
        return [TextContent(type="text", text=f"Cannot read output dir: {e}")]

    if prefix:
        files = [f for f in files if f.startswith(prefix)]

    # Sort by modification time, newest first
    files_with_mtime = []
    for f in files:
        fp = os.path.join(OUTPUT_DIR, f)
        try:
            files_with_mtime.append((f, os.path.getmtime(fp)))
        except OSError:
            continue
    files_with_mtime.sort(key=lambda x: x[1], reverse=True)

    result = [
        {"filename": f, "path": os.path.join(OUTPUT_DIR, f)}
        for f, _ in files_with_mtime[:limit]
    ]
    return [TextContent(type="text", text=json.dumps(result, indent=2))]


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import asyncio

    if "--sse" in sys.argv:
        # SSE transport for networked clients
        # Requires: pip install mcp[sse]
        from mcp.server.sse import SseServerTransport
        from starlette.applications import Starlette
        from starlette.routing import Route
        import uvicorn

        port = 9100
        for i, arg in enumerate(sys.argv):
            if arg == "--port" and i + 1 < len(sys.argv):
                port = int(sys.argv[i + 1])

        sse = SseServerTransport("/messages")

        async def handle_sse(request):
            async with sse.connect_sse(request.scope, request.receive, request._send) as streams:
                await app.run(streams[0], streams[1], app.create_initialization_options())

        starlette_app = Starlette(routes=[
            Route("/sse", endpoint=handle_sse),
            Route("/messages", endpoint=sse.handle_post_message, methods=["POST"]),
        ])

        print(f"ComfyUI MCP Server (SSE) on port {port}", file=sys.stderr)
        uvicorn.run(starlette_app, host="0.0.0.0", port=port)
    else:
        # stdio transport (default)
        from mcp.server.stdio import stdio_server

        async def main():
            async with stdio_server() as (read_stream, write_stream):
                print("ComfyUI MCP Server (stdio) starting...", file=sys.stderr)
                await app.run(read_stream, write_stream, app.create_initialization_options())

        asyncio.run(main())
