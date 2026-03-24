# Chat Control Plane v1 (neoclaw-rails)

This document defines operator control from chat, prioritizing cron/schedule management and direct runtime control.

## Scope in this PR

- Slash/legacy command parsing in Hub (`/cmd` and `!cmd`)
- Mention-prefix tolerant parsing (`<@...> /cmd`, `<@&...> /cmd`, `@neoclaw-rails /cmd`)
- `/stop` command: interrupt active Claude run for current identity+room instance
- `/restart` command: execute operator-defined restart command via env var
- Keep existing operator gate (`Config.operators`)

## Commands (Implemented)

- `/help` → list available commands
- `/status` → hub/manager status
- `/agents` → running instances
- `/freeze <nick>` → freeze specific instance
- `/rescue <nick>` → rescue/unwind stuck instance
- `/stop` → stop current room instance (`<identity>-<slug>`)
- `/restart` → execute `NEOCLAW_OPERATOR_RESTART_CMD`

Legacy `!` prefix remains supported.

## Cron / Scheduler (Top Priority, next PR)

Manager already has CRUD UI routes for `CronMessage` (`/crons`).
Next PR should add chat-facing cron control:

- `/cron list`
- `/cron add <schedule> <channel> <message>`
- `/cron edit <id> ...`
- `/cron pause <id>` / `/cron resume <id>`
- `/cron run <id>`
- `/cron history [id]`

### Suggested implementation

1. Add Hub command handlers that call Manager API endpoints for cron CRUD.
2. Return concise in-channel responses with job id + next run.
3. Validate cron expression server-side and report errors clearly.
4. Keep timezone explicit (default from env, overridable per job).

## Environment variables

- `NEOCLAW_OPERATOR_RESTART_CMD` (optional, required for `/restart`)
  - Example: `sudo systemctl restart neoclaw-rails-hub neoclaw-rails-manager`

If unset, `/restart` returns a clear config message and does nothing.

## Notes

- This is intentionally operator-focused and fast-moving (“WWW baby”).
- Safety hardening (RBAC granularity, cooldowns, confirmations) can be layered later.
