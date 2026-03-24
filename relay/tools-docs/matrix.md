## Matrix

Matrix messaging via `mcp__matrix` tools.

**Tools:**
| Tool | Params | What it does |
|------|--------|-------------|
| `matrix_send` | room_id, message | Send a text message. Supports markdown (**bold**, `code`, _italic_). |
| `matrix_send_image` | room_id, path, caption? | Upload and send an image file. |
| `matrix_read` | room_id, limit? (default 20) | Read recent messages (newest first). |
| `matrix_download` | mxc_url, save_path | Download a file from an mxc:// URL. |
| `matrix_rooms` | — | List joined room IDs. |

Room IDs look like `!abc123:matrix.home`. Use `matrix_rooms` to discover them.
