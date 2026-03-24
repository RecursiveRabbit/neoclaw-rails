## SSH

Terminal access to the host via `mcp__ssh` tools. Persistent session — connects once, stays open.

**Connect first:**
```
ssh_connect(host: "{{SSH_HOST}}", username: "{{SSH_USER}}", key_path: "{{SSH_KEY_PATH}}", port: {{SSH_PORT}})
```

**Tools:**
| Tool | Params | What it does |
|------|--------|-------------|
| `ssh_connect` | host, username, key_path or password, port (default 22) | Opens SSH session. Call once. |
| `ssh_execute` | command (string) | Run a command, wait up to 90s, return output. |
| `ssh_disconnect` | — | Close session. |
| `ssh_interrupt` | — | Send Ctrl+C. |
| `ssh_eof` | — | Send Ctrl+D. |
| `ssh_background` | — | Ctrl+Z then `bg`. |
| `ssh_send_raw` | data (string) | Send raw bytes. Escape sequences like `\x03` are interpreted. |
| `ssh_status` | — | Check if connected. |

**Resources:** `terminal://buffer` (last 8000 chars of output), `terminal://status`.
