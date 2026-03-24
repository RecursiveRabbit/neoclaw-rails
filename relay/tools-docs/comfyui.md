## ComfyUI (Image Generation)

FLUX.2 Klein 4B image generation via `mcp__comfyui` tools.

**Tools:**
| Tool | Params | What it does |
|------|--------|-------------|
| `generate_image` | prompt + options below | Generate an image, returns file path. |
| `run_workflow` | workflow (JSON object), copy_to? | Execute a raw ComfyUI workflow. |
| `queue_status` | — | Pending/running prompt count. |
| `get_history` | prompt_id | Status and output of a queued prompt. |
| `list_outputs` | prefix?, limit? (default 20) | Recent output images. |

**generate_image options:**
| Param | Type | Default | Notes |
|-------|------|---------|-------|
| prompt | string | *required* | Text prompt. Semicolon-separated for regional prompting. |
| prefix | string | "parallax" | Output filename prefix. |
| aspect | string | "1:1" | Ratio: 1:1, 3:2, 2:3, 4:3, 16:9, 9:16, 21:9, 2:1, 5:4 and inverses. |
| width, height | int | from aspect | Override dimensions (rounded to multiple of 8). |
| steps | int | 4 | Inference steps. More = more detail, slower. Max 50. |
| seed | int | random | For reproducibility. |
| lora | string | — | LoRA model. Shortcuts: `ghibli`, `pencil`, `80s`. Or full filename. |
| lora_strength | float | 1.0 | 0.0–2.0. |
| regions | string | — | Layout: "left;right", "top;bottom", or x,y,w,h percentages. |
| batch | int | 1 | Generate multiple images with different seeds. Max 20. |
| copy_to | string | — | Copy output to this path. |
