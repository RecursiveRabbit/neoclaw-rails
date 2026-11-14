# Hub environment — deployment notes

The Hub reads **only** environment variables. There is no config file to edit and no
database to seed. Everything below comes from `app/services/hub/config.rb`, which is
the single place to look and the single place to change.

## `NEOCLAW_OPERATORS` — who may run `!` commands

**There is no default. An unconfigured Hub refuses every `!` command**, and says so
in the room by naming the identity it rejected:

```
@someone:matrix.home is not an operator; !freeze refused
```

That is the intended behaviour, not a fault — a default owner is a stranger admitted
by a bot nobody configured. It does mean a deployment that never sets this variable
produces a bot that ignores everyone, which is why this section exists.

### What the notice says, and what it deliberately does not

- It names the identity that was compared, up to 96 characters, and the verb up to 32.
  An over-long value is clipped and **marked with its true length** — `… (4096 chars)` —
  because a silently clipped identity reads like the real one. Above the cap the whole
  value survives only in the log.
- Control characters, and U+2028/U+2029, are **escaped, not stripped**: a newline reaches
  the room as the four characters `\x0A`, a literal backslash is doubled first so the
  escapes cannot be forged, and nothing arrives as a second line under the bot's name.
- **It speaks once per sender for the life of the process; after that the log carries it
  alone.** A second `!freeze` from the same identity gets no second notice. That is
  deliberate — a per-message post makes the bot a relay for whoever knocks, in its own
  voice, at their chosen rate — but it means silence in the room is not evidence that the
  gate is down. The full refusal, unclipped and inspected, is logged every time.

### The form

Comma-separated **full Matrix IDs**, each `@localpart:server`. One line, no spaces
required (spaces are stripped):

```
NEOCLAW_OPERATORS=@evans:matrix.home
```

More than one:

```
NEOCLAW_OPERATORS=@evans:matrix.home,@hopper:matrix.home
```

A server may carry a port, as Matrix permits:

```
NEOCLAW_OPERATORS=@evans:matrix.home:8448
```

### The one thing that will not work

A bare localpart. `evans` is **not** an identity — `@evans:any.federated.server`
shares the localpart `evans` and is a different person. The gate compares the exact
full ID, so `evans` matches nobody, silently, and the refusal names a sender the
operator thought they had configured.

```
NEOCLAW_OPERATORS=evans,hopper          # matches nothing; refuses everyone
NEOCLAW_OPERATORS=@evans:matrix.home    # correct
```

An entry that cannot match (no `@`, no `:`) is named at boot with a warning, so this
misconfiguration announces itself instead of looking like "nobody set it". The two
states are different faults and they get different words:

| state | boot warning |
|---|---|
| variable unset or empty | *unset — every `!` command will be refused; set it to a full Matrix ID* |
| set to entries that cannot match | *contains N entries that cannot match any sender: "evans"* |

The warning's **words** are covered by rows in `test/services/hub/operator_contract_test.rb`. The
wiring is covered twice, and each covers a different half. One row reads this process's own
boot log and asserts the warning is in it — that establishes that boot runs the contract, for
the unset state CI boots in. `script/probe-boot-operator-contract.sh` boots the app three
times in its own processes, bounded, and checks all three states, including that a usable
list is **silent**. Neither is a unit row and neither could be: `Rails.application.config
.after_initialize` is not a readable list, so a test cannot re-run this one hook without
re-running every initializer's. If both are removed, this paragraph stops being true and the
sentence above becomes a reading again.

### Where to set it

Both launch paths pass it through from the environment, so an operator sets it once
on the host and does not need to touch either script:

- `manager/entrypoint.sh:131` — `-e NEOCLAW_OPERATORS` (bare name, deliberately;
  see the comment there: a value-bearing form would make the container see an empty
  string rather than an unset variable, and the gate cannot tell those apart)
- `manager/run.sh:63` — the same

```sh
export NEOCLAW_OPERATORS=@evans:matrix.home
manager/run.sh
```

## The rest

| variable | default | notes |
|---|---|---|
| `NEOCLAW_AS_TOKEN` | *(none — required)* | application-service token |
| `NEOCLAW_HS_TOKEN` | *(none — required)* | homeserver token |
| `NEOCLAW_SYNAPSE_URL` | `http://localhost:8008` | |
| `NEOCLAW_SERVER_NAME` | `matrix.home` | the server half of a full Matrix ID |
| `NEOCLAW_MANAGER_URL` | `http://10.0.0.3:9200` | |
| `NEOCLAW_APPSERVICE_USER` | `neoclaw` | |
| `NEOCLAW_IDENTITIES` | *(empty)* | fallback identity list used only when the Manager is unreachable |

`NEOCLAW_AS_TOKEN` and `NEOCLAW_HS_TOKEN` have no default on purpose: `ENV.fetch`
raises rather than running with a token nobody set.

## What is deliberately not here

`BABO_TRUSTED_SOURCES` and the retired `BABO_OPERATOR_SOURCES` belong to the babo
side of the house and are documented where they are read, not in this file. The
operator door those keys fed was retired on 2026-11-12 (Evans: *"No connection
whatsoever… it is an actuator for the UI, nothing else"*).

**`BABO_TRUSTED_SOURCES` is rendered only for the UI role.** `trusted_sources` gates a
TCP listener, and the manager role's channel is a unix socket — so as of 2026-11-14 the
manager no longer renders it, because a source list with no listener to gate reads as a
control to the next person and refuses nobody. The render says so in its own log line.
Whether the UI's core actually enforces the list is a babo-core question and is not
established from this repository; until it is, the field is a claim the UI pod makes and
the manager pod does not.

**The health endpoint binds loopback by default** (`BABO_HEALTH_ADDRESS`, default
`127.0.0.1`) and exposure is an explicit opt-in, because nothing gates it: it is an
unauthenticated liveness answer. On 2026-11-14 the manager's health returned 200 to an
address the rendered trust list did not contain. A pod that needs to answer health from
off-loopback sets `BABO_HEALTH_ADDRESS` to that address and gets a log line saying it is
exposed; a pod that does not, does not.
