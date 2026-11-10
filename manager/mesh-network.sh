#!/bin/bash
# mesh-network.sh — create the mesh underlay network, or assert it, at boot.
#
# A function file, not a script: sourced by manager/entrypoint.sh (inside the
# Manager container) and by manager/run.sh (on the host, before the Manager
# starts), so the network is created once and asserted by the same code both
# times. Values come from manager/network.env — the single source — and nothing
# here has a default of its own.
#
# Contract:
#   input  PODMAN            podman command (may carry --remote --url ...)
#   input  NC_MESH_NETWORK   network name
#   input  NC_MESH_SUBNET    expected subnet CIDR (from manager/network.env)
#   input  NC_MESH_GATEWAY   expected gateway inside that subnet
#   output nothing; returns non-zero with both values named on mismatch
#
# The assertion is the point: a host default that happens to look right is not
# evidence. The network this boot will use is inspected, and its subnet and
# gateway must equal the source. There is no silent fallback.

mesh_network_ensure() {
    local podman="${PODMAN:-podman}"
    local name="${NC_MESH_NETWORK:?NC_MESH_NETWORK is required (manager/network.env)}"
    local want_subnet="${NC_MESH_SUBNET:?NC_MESH_SUBNET is required (manager/network.env)}"
    local want_gw="${NC_MESH_GATEWAY:?NC_MESH_GATEWAY is required (manager/network.env)}"

    if ! $podman network exists "$name" >/dev/null 2>&1; then
        local created
        created=$($podman network create \
            --subnet "$want_subnet" \
            --gateway "$want_gw" \
            "$name" 2>&1) || {
            echo "mesh-network: could not create network '$name' with subnet $want_subnet gateway $want_gw: $created" >&2
            return 1
        }
    fi

    local got_subnet got_gw
    got_subnet=$($podman network inspect "$name" \
        --format '{{range .Subnets}}{{.Subnet}}{{end}}' 2>/dev/null)
    got_gw=$($podman network inspect "$name" \
        --format '{{range .Subnets}}{{.Gateway}}{{end}}' 2>/dev/null)

    if [ "$got_subnet" != "$want_subnet" ] || [ "$got_gw" != "$want_gw" ]; then
        echo "mesh-network: network '$name' is subnets=${got_subnet:-<unreadable>} gateway=${got_gw:-<unreadable>}," \
             "but manager/network.env declares subnet ${want_subnet} gateway ${want_gw}." \
             "Refusing to start on a network whose addresses we did not choose." >&2
        return 1
    fi

    echo "mesh-network: '$name' subnets=${got_subnet} gateway=${got_gw} (asserted)" >&2
    return 0
}
