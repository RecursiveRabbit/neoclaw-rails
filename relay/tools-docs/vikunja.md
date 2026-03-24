## Vikunja (Tickets)

Task tracking via `mcp__vikunja` tools. All ticket numbers are project-scoped index numbers, not internal IDs.

**Tools:**
| Tool | Params | What it does |
|------|--------|-------------|
| `ticket_list` | status: "open" (default), "done", or "all" | List tickets. |
| `ticket_view` | index (int) | Full ticket detail with comments. |
| `ticket_create` | title, description?, priority?, assignee? | Create a ticket. |
| `ticket_comment` | index (int), comment (string) | Add a comment. |
| `ticket_update` | index (int), title?, description?, priority? | Update fields. |
| `ticket_done` | index (int) | Mark as done. |

**Priority values:** unset, low, medium, high, urgent, critical.

**Assignee:** Vikunja username (same as your identity name, capitalized).
