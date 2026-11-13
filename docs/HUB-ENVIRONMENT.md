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

`BABO_TRUSTED_SOURCES` and the retired `BABO_OPERATOR_SOURCES` belong to the manager
side of the house and are documented where they are read, not in this file. The
operator door those keys fed was retired on 2026-11-12 (Evans: *"No connection
whatsoever… it is an actuator for the UI, nothing else"*).
