#!/bin/bash
# Can the tunnel actually carry anything? Ask wg, before you ask the application.
#
# Three times in one day a run reported `000` at the application layer and the
# cause was two layers down: a generated `wg0.conf` whose `[Peer]` block had lost
# its `AllowedIPs`. Each time it was found by patching at run time — `wg set …
# allowed-ips` plus a hand-made route — and each time the patch worked for the
# peers I remembered and not the third one.
#
# A workaround used three times is a missing tool, not a repeated mistake. This is
# the tool: it reads `wg show` and fails when any peer has an empty `allowed ips`.
#
# Usage:
#   mesh-preflight.sh <container> [<container> ...]     # podman exec + wg show
#   mesh-preflight.sh --stdin                            # check wg show output on stdin
#
# Exit: 0 every peer has allowed ips; 1 a peer has none; 2 the check could not run.
set -u

check() { # reads `wg show` output on stdin; exit 1 on an empty allowed-ips
    local peers=0 empty=0 current=""
    while IFS= read -r line; do
        case "$line" in
            peer:*) peers=$((peers + 1)); current="${line#peer: }" ;;
            *"allowed ips:"*)
                local ips="${line#*allowed ips:}"
                ips="$(printf '%s' "$ips" | tr -d '[:space:]')"
                if [ -z "$ips" ] || [ "$ips" = "(none)" ]; then
                    echo "UNMET: peer ${current:-?} has no allowed ips — the tunnel will handshake and route nothing" >&2
                    empty=$((empty + 1))
                fi
                ;;
        esac
    done

    if [ "$peers" -eq 0 ]; then
        echo "UNMET: no peers in this output — nothing to check, which is not the same as a pass" >&2
        return 2
    fi
    if [ "$empty" -gt 0 ]; then
        echo "FAIL: $empty of $peers peer(s) have no allowed ips" >&2
        return 1
    fi
    echo "OK: $peers peer(s), every one with allowed ips"
    return 0
}

if [ "${1:-}" = "--stdin" ]; then
    check
    exit $?
fi

if [ "$#" -eq 0 ]; then
    echo "usage: $0 <container> [<container> ...] | --stdin" >&2
    exit 2
fi

status=0
for container in "$@"; do
    if ! output="$(podman exec "$container" wg show wg0 2>&1)"; then
        echo "UNMET: $container — wg show failed: $output" >&2
        status=2
        continue
    fi
    echo "== $container"
    printf '%s\n' "$output" | check || status=$?
done
exit "$status"
