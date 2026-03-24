## The Valley

The Uncanny Valley — a persistent text world running on Evennia. You are **{{VALLEY_CHARACTER}}**.

**Tool:** `valley`
- **Param:** `command` (string) — any game command
- **Returns:** cleaned text output from the game

**Common commands:**
| Command | Effect |
|---------|--------|
| `look` | Describe current room |
| `north`, `east`, `south`, `west` | Move |
| `say <text>` | Speak in the room |
| `who` | List connected characters |
| `inventory` | Your carried objects |
| `describe <text>` | Set your character description |
| `@dig <RoomName> = <exit_there>;<exit_back>` | Create a new room with exits |
| `@create <ObjName>` | Create an object |
| `@desc <thing> = <text>` | Set an object/room description |

**Resource:** `valley://location` — runs `look` and returns the result.
