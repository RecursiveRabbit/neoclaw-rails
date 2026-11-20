# Cove Manager

A Rails control pane for **agent sheets**, **pods**, and **one text file**. It has no
database, no asset pipeline, no background jobs, no cache, and no idea what a service
does.

Read `the-townline/requests/2026-11-19-from-evans-via-nime-to-dova-soro-the-cove-manager.md`
for the commission and `vault/specs/cove.md` for the intent. This README is how to run it.

## The four facts that explain the whole thing

1. **A sheet is a YAML file** in `state/agents/<slug>.yml`. It holds desired state and
   history: name, harness, model, repo, image, command, tools, allowed services.
   It never says whether anything is running.
2. **`state/services.yml`** is the service book: `name` and `address`. That is the whole
   model of a service in this build.
3. **`state/router.conf`** is the seam. Rewritten whole, atomically, on every change to
   any sheet — never patched, never appended, no timestamps (identical intent, identical
   bytes). The router doesn't exist; when it does it reads this file and nothing else.
4. **Podman is the only thing that can act**, and the relay is the only thing that can say
   what is happening inside a pod. Neither answer is stored: the pods page queries podman
   at render time, the pod page asks the relay at render time. Every question the relay
   cannot answer is written to `state/relay-wants.jsonl`, which is the relay's build list.

## Run it on the host (for development)

    cd cove
    bundle install
    bundle exec puma -b tcp://127.0.0.1:9200 config.ru

Then open <http://127.0.0.1:9200/>.

## Run it where it belongs (a pod on z620)

    podman build -t localhost/cove-manager:latest -f Containerfile .
    # 9200 is taken by a host process on z620; the port is a property of the run.
    podman run -d --name cove-manager-dova \
      -p 127.0.0.1:9411:9200 \
      -v /run/user/$(id -u)/podman/podman.sock:/run/podman/podman.sock \
      -v "$PWD/state:/app/state:Z" \
      localhost/cove-manager:latest

`-p 127.0.0.1:<port>:9200` is the fence: the Manager is reachable from the host and from
nowhere else (§4). The socket mount is what makes the start button real; without it the
button reports, honestly, that podman is not on the other end.

## Check it rather than trust it — and know what this check is worth

`soro`'s acceptance harness (`script/cove-acceptance/` in the repo) lives **outside** this
app and never requires its classes. That one is the gate. `./script/verify` is a fast
local loop that happens to live in the tree it tests, which means in principle the app
could satisfy it; treat a green here as "not obviously broken", never as a witness.

    ./script/verify

That script boots the app against a throwaway state directory and then checks, by
mutation:

- a second render of unchanged intent is byte-identical (purity);
- deleting a line from `router.conf` and re-saving any sheet brings the whole file back
  (totality);
- a sheet naming a service that is not in the service book renders as `unresolved` and
  never invents a `service` line for it;
- no service name appears anywhere in `app/`, `config/`, or `script/` — the discipline
  test from the commission, run as a grep.

## What is deliberately absent

WireGuard, the router process, token minting, Matrix, the fold, salvage. Each is a real
component with a state machine; this slice is one button, one file, and an honest record
of what it could not learn.
