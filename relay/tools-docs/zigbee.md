## Zigbee

Smart home devices via `mcp__zigbee` tools. Communicates through Zigbee2MQTT over MQTT.

**Tools:**
| Tool | Params | What it does |
|------|--------|-------------|
| `zigbee_list` | — | All devices with type, capabilities, and current state. |
| `zigbee_get` | name | Current state of one device. |
| `zigbee_set` | name, payload (JSON object) | Publish a set command to the device. |
| `zigbee_scene` | name | Activate a lighting scene on hopper_bulb. |

**Devices:**
| Name | Type | Capabilities |
|------|------|-------------|
| `hopper_bulb` | light | on/off, brightness (0–254), color (xy or hue/sat), color_temp |
| `nightlight` | sensor | occupancy, illuminance, battery |
| `temp_sensor` | sensor | temperature, humidity, battery |

**zigbee_set payload examples:**
- `{"state": "ON"}` / `{"state": "OFF"}`
- `{"brightness": 128}`
- `{"color": {"hue": 240, "saturation": 100}}`
- `{"color": {"x": 0.15, "y": 0.23}}`
- `{"color_temp": 350}`

**Scenes:** idle, active, thinking, listening, alert, deepwork, goodnight, sleep, greeting, happy, error, task_done, attention, off, on.
