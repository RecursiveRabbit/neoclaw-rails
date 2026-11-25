#!/usr/bin/env python3
"""cove-host-routes — the HOST HALF of R16, derived from the plan.

Evans / the desk, 2026-11-23 — the pods' path out is entirely host-side:
  1. the pod-subnet routes, via the Router's transport address;
  2. a FORWARD accept keyed to the Router (the desk's half, already in place);
  3. the LAN-gateway reply path BLOCKED as a backstop behind the route.

(1) and (3) are this script. Nothing in cove/ creates them and nothing in cove/
can: they are the host's.

WHY THIS FILE EXISTS AT ALL, stated plainly. The routes were installed by hand
twice, on 2026-11-24, and the power blip at 10:18 the same day took them with it:
after 16:35 the host had NO route to 10.201.0.0/20, so a reply to a pod fell to
the default route via the LAN gateway and R16 read

    return=LAN-PATH-OPEN(10.201.2.10 via 10.0.0.1)

A requirement installed by hand is a requirement with a timer on it. It is also —
and this is the worse half — a requirement whose absence is INVISIBLE: the route
that is missing and the route that was never asked for look the same in `ip
route`, and only a row that asks `ip route get <pod>` can tell them apart.

THE VALUES COME FROM plan.yml, NOT FROM THIS FILE. The tunnel, the two pools and
the Router's transport are read at every run. A plan that moves must move the host
with it, or the host becomes the one document that still says 10.99. The
second and third readings of this script are what caught that: the first draft had
10.89.4.2 and 10.201.1.0/24 typed into it, which is the same fault as a row with a
literal in it — correct until the day it moves, and silent about it after.

THE BACKSTOP FAILS CLOSED, AND IT IS `prohibit` FOR A MEASURED REASON. A `prohibit`
route for the whole tunnel network sits at a high metric under the two /24s. Longest
prefix wins, so the real routes carry while they exist; if a real route is ever
missing again, the packet is refused rather than handed to the LAN gateway, and R16
reads NO-ROUTE — which is honest ("blocked, and replies do not arrive") instead of
LAN-PATH-OPEN, the address the ruling forbids. A construction whose failure mode is
"leak toward the LAN" is the thing Evans ruled against; one whose failure mode is
"refuse and be counted" is the backstop he asked for.

`prohibit` and not `blackhole`, and the difference was measured before choosing it
(z620, 2026-11-24): `ip route get` prints nothing at all on stdout for ANY of the
three blocked route types, and one line on stderr — "Permission denied" for
prohibit, "No route to host" for unreachable, "Invalid argument" for blackhole.
"Administratively prohibited" is what a ruling looks like in a routing table;
"Invalid argument" is what a wrong argument looks like. That measurement also found
that R16 could not see any of them (it read stdout with the error discarded), which
is fixed in neoclaw-rails#84.

Idempotent: `ip route replace` throughout, so a re-run after a reboot, a bridge
renumber, or a plan move is the same operation as the first run.

Exit 0 = the routes are in place. Exit non-zero = they are not, and the unit says
so; this never reports success for a partial state.
"""
import ipaddress
import re
import subprocess
import sys
import time

PLAN = "/home/sexton/cove-state/plan.yml"
BACKSTOP_METRIC = 1000


def die(msg):
    print(f"cove-host-routes: {msg}", file=sys.stderr)
    sys.exit(1)


def sh(*argv):
    return subprocess.run(argv, capture_output=True, text=True)


def read_plan():
    try:
        text = open(PLAN, encoding="utf-8").read()
    except OSError as e:
        die(f"cannot read the plan at {PLAN}: {e}")

    def grab(pattern, what):
        m = re.search(pattern, text, re.M)
        if not m:
            die(f"plan.yml names no {what} — refusing to guess a route")
        return m.group(1).strip()

    tunnel = grab(r"^network:\s*(\S+)", "network")
    transport = grab(r"^\s+transport:\s*(\S+)", "router transport")
    agent = grab(r"^\s+agent:\s*(\S+)", "agent pool")
    service = grab(r"^\s+service:\s*(\S+)", "service pool")
    return tunnel, transport, agent, service


def device_for(transport):
    """The interface that holds an address in the transport's own /24.

    Derived, not assumed: the underlay bridge is podman5 today and a renumbered
    bridge tomorrow, and a route with a stale device name is a route that looks
    installed and carries nothing.
    """
    want = ipaddress.ip_network(f"{transport}/24", strict=False)
    out = sh("ip", "-4", "-o", "addr", "show")
    if out.returncode != 0:
        die(f"`ip addr` failed: {out.stderr.strip()}")
    for line in out.stdout.splitlines():
        m = re.search(r"^\d+:\s+(\S+)\s+inet\s+(\d+\.\d+\.\d+\.\d+)/", line)
        if not m:
            continue
        dev, addr = m.group(1), m.group(2)
        try:
            if ipaddress.ip_address(addr) in want:
                return dev
        except ValueError:
            continue
    return None


def main():
    tunnel, transport, agent, service = read_plan()
    try:
        net = ipaddress.ip_network(tunnel, strict=False)
    except ValueError:
        die(f"plan.yml's network is not a CIDR: {tunnel!r}")

    dev = device_for(transport)
    if dev is None:
        return "no-bridge"
    did = []

    for pool in (agent, service):
        try:
            subnet = ipaddress.ip_network(f"{pool}.0/24", strict=False)
        except ValueError:
            die(f"pool {pool!r} is not a prefix to hang a /24 on")
        # `subnet in net` IS NOT THIS QUESTION and it answers False for a true
        # containment: Python's IPv4Network.__contains__ is about ADDRESSES, and
        # 10.201.2.0/24 in 10.201.0.0/20 is False while .subnet_of() is True.
        # Measured while writing this script, 2026-11-24 — a boolean of the right
        # type carrying the wrong value, which is the family of faults this line of
        # work keeps finding. subnet_of, not `in`.
        if not subnet.subnet_of(net):
            die(f"pool {subnet} is outside the plan's tunnel {net} — a route to it "
                f"would send a pod's traffic to a network the plan does not claim")
        r = sh("ip", "route", "replace", str(subnet), "via", transport, "dev", dev)
        if r.returncode != 0:
            die(f"could not install {subnet} via {transport} dev {dev}: {r.stderr.strip()}")
        did.append(f"{subnet} via {transport} dev {dev}")

    r = sh("ip", "route", "replace", "prohibit", str(net), "metric", str(BACKSTOP_METRIC))
    if r.returncode != 0:
        die(f"could not install the backstop prohibit route for {net}: {r.stderr.strip()}")
    did.append(f"prohibit {net} metric {BACKSTOP_METRIC} (backstop: the LAN path cannot carry)")

    for line in did:
        print(f"cove-host-routes: {line}")

    # Prove the two roads the ruling names, and report the one it forbids, from the
    # routing table itself rather than from what we just typed.
    ok = True
    for pool in (agent, service):
        probe = f"{pool}.10"
        g = sh("ip", "route", "get", probe)
        line = (g.stdout or g.stderr).strip().splitlines()[0] if (g.stdout or g.stderr).strip() else "no answer"
        good = g.returncode == 0 and transport in g.stdout and dev in g.stdout
        print(f"cove-host-routes:   {probe:16s} -> {line}  [{ 'via Router' if good else 'NOT via Router' }]")
        ok = ok and good
    if not ok:
        die("a probe address does not route via the Router — the host half is NOT in place")
    return 0


if __name__ == "__main__":
    # The bridge may not exist yet at boot: the unit runs after network-online, but
    # podman creates the bridge when the first container starts. Wait for it, briefly
    # and honestly — a fixed sleep would be a guess about someone else's boot order.
    rc = None
    for attempt in range(30):
        rc = main()
        if rc != "no-bridge":
            sys.exit(rc)
        if attempt == 0:
            print("cove-host-routes: waiting for the underlay bridge …")
        time.sleep(2)
    print("cove-host-routes: the underlay bridge never came up, so no route was "
          "installed and the pods have no path out", file=sys.stderr)
    sys.exit(1)
