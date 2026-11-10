#!/bin/bash
# keys_per_boot_test.sh — proof that no WG private key survives a boot.
#
# Runs anywhere with wireguard-tools; no podman needed. Proves the rendering
# half of the claim. The Router-replacement half (same key within a boot, no
# pod reconfiguration) needs podman: test/proof/keys_per_boot_live.sh.
#
# Exit 0 = all checks pass; 1 = at least one failed. No eval; plain commands.

set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
PASS=0; FAIL=0

ok()  { PASS=$((PASS+1)); echo "PASS  $*"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL  $*"; }
t()   { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
eq()  { local d="$1" a="$2" b="$3"; if [ "$a" = "$b" ]; then ok "$d"; else bad "$d ($a != $b)"; fi; }
ne()  { local d="$1" a="$2" b="$3"; if [ "$a" != "$b" ]; then ok "$d"; else bad "$d (both $a)"; fi; }
no_file() { local d="$1" p="$2"; if [ ! -e "$p" ]; then ok "$d"; else bad "$d ($p exists)"; fi; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PUB="$TMP/public"
mkdir -p "$PUB"
(umask 077 && wg genkey > "$TMP/host.key")
wg pubkey < "$TMP/host.key" > "$PUB/nc-host.pub"
printf '  user-1:\n    pubkey: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="\n    allowed_ips: "10.2.0.1/32"\n' > "$PUB/users-peers.fragment"
printf '\nservices:\n  default:\n    tcp: [3100]\n' > "$PUB/router-services.yml"

boot() {  # $1 = runtime dir; echoes "router manager hub boot_id"
    (
        RUNTIME_DIR="$1"
        PUBLIC_DIR="$PUB"
        HOST_WG_PUBKEY="$(cat "$PUB/nc-host.pub")"
        # shellcheck source=/dev/null
        source "$REPO/manager/runtime-keys.sh"
        render_boot_runtime || exit 1
        printf '%s %s %s %s\n' "$ROUTER_PUBKEY" "$MANAGER_PUBKEY" "$HUB_PUBKEY" "$BOOT_ID"
    )
}

A="$TMP/bootA"
B="$TMP/bootB"
B1=$(boot "$A") || { echo "FATAL: boot A render failed"; exit 1; }
R1=$(printf '%s\n' "$B1" | cut -d' ' -f1)
M1=$(printf '%s\n' "$B1" | cut -d' ' -f2)
H1=$(printf '%s\n' "$B1" | cut -d' ' -f3)
I1=$(printf '%s\n' "$B1" | cut -d' ' -f4)
echo "--- boot A router ${R1:0:12}..."

# 1. Keys are real and internally consistent.
eq "router public key matches its private key"   "$(wg pubkey < "$A/router/private.key")" "$R1"
eq "manager public key matches its private key"  "$(wg pubkey < "$A/manager/private.key")" "$M1"
t  "manager wg0.conf peer is this boot's Router"  grep -qx "PublicKey = $R1" "$A/manager/wg0.conf"
t  "hub wg0.conf peer is this boot's Router"      grep -qx "PublicKey = $R1" "$A/hub/wg0.conf"
t  "router config peer manager matches"           grep -qx "    pubkey: \"$M1\"" "$A/router/config.yml"
t  "router config peer hub matches"               grep -qx "    pubkey: \"$H1\"" "$A/router/config.yml"
t  "router config peer host is the baked host key" grep -qx "    pubkey: \"$(cat "$PUB/nc-host.pub")\"" "$A/router/config.yml"
t  "router config points at the mounted key file" grep -qx "  wg_private_key: /etc/router/private.key" "$A/router/config.yml"
t  "static user fragment appended"                grep -qx "  user-1:" "$A/router/config.yml"
t  "service map appended"                         grep -qx "services:" "$A/router/config.yml"

# 2. Permissions.
eq "runtime dir is 0700"          "$(stat -c %a "$A")" "700"
eq "router private key is 0600"   "$(stat -c %a "$A/router/private.key")" "600"
eq "manager private key is 0600"  "$(stat -c %a "$A/manager/private.key")" "600"
eq "hub private key is 0600"      "$(stat -c %a "$A/hub/private.key")" "600"
eq "manager wg0.conf is 0600"     "$(stat -c %a "$A/manager/wg0.conf")" "600"

# 3. Public handoff.
eq "router.pubkey handoff equals this boot's Router key" "$(cat "$A/router.pubkey")" "$R1"
t  "boot.json carries the matching Router key" grep -q "\"router_pubkey\":\"$R1\"" "$A/boot.json"

# 4. A second boot differs everywhere.
B2=$(boot "$B") || { echo "FATAL: boot B render failed"; exit 1; }
R2=$(printf '%s\n' "$B2" | cut -d' ' -f1)
M2=$(printf '%s\n' "$B2" | cut -d' ' -f2)
I2=$(printf '%s\n' "$B2" | cut -d' ' -f4)
echo "--- boot B router ${R2:0:12}..."
ne "boot B Router pubkey differs from boot A"  "$R1" "$R2"
ne "boot B Manager pubkey differs from boot A" "$M1" "$M2"
ne "boot ids differ"                           "$I1" "$I2"

# 5. Re-rendering the SAME dir (a real reboot on the same host) replaces the key.
OLD_KEY=$(cat "$A/router/private.key")
B3=$(boot "$A") || { echo "FATAL: re-render failed"; exit 1; }
R3=$(printf '%s\n' "$B3" | cut -d' ' -f1)
ne "re-render in the same dir makes a new Router key" "$R1" "$R3"
ne "the old private key no longer exists on disk"     "$OLD_KEY" "$(cat "$A/router/private.key")"
eq "the new private key matches the new public key"   "$(wg pubkey < "$A/router/private.key")" "$R3"

# 6. Nothing key-shaped is baked into any build context.
no_file "no baked router private key"  "$REPO/router/wg-private.key"
no_file "no baked manager wg0.conf"    "$REPO/manager/wg0.conf"
no_file "no baked router pubkey file"  "$REPO/manager/router_pubkey"
no_file "no baked hub wg0.conf"        "$REPO/wg0.conf"
t "Router Containerfile copies no key"       bash -c "! grep -q 'wg-private.key' '$REPO/router/Containerfile'"
t "Manager Containerfile copies no wg0.conf" bash -c "! grep -q 'COPY wg0.conf' '$REPO/manager/Containerfile'"
t "Hub Containerfile copies no wg0.conf"     bash -c "! grep -q 'COPY wg0.conf' '$REPO/Containerfile.hub'"
t "Router entrypoint refuses to start without a mounted config" grep -q 'must be mounted' "$REPO/router/entrypoint.sh"

# 7. build.sh generates no deployment private key.
t "build.sh does not generate the Router keypair"  bash -c "! grep -qF 'ROUTER_PRIVKEY=\$(wg genkey)' '$REPO/manager/build.sh'"
t "build.sh does not generate the Manager keypair" bash -c "! grep -qF 'MANAGER_PRIVKEY=\$(wg genkey)' '$REPO/manager/build.sh'"

# 8. run.sh has no default secrets and owns the host handoff.
t "run.sh carries no default Forgejo token" bash -c "! grep -qE 'FORGEJO_ADMIN_TOKEN=[A-Za-z0-9]{16,}' '$REPO/manager/run.sh'"
t "run.sh carries no default Matrix tokens" bash -c "! grep -qE 'NEOCLAW_(AS|HS)_TOKEN=[A-Za-z0-9]{16,}' '$REPO/manager/run.sh'"
t "run.sh re-points the host peer from router.pubkey" grep -q 'wg set nc-host peer' "$REPO/manager/run.sh"
t "run.sh renders user config templates with the boot key" grep -q '__ROUTER_PUBKEY__' "$REPO/manager/run.sh"

echo "---"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
