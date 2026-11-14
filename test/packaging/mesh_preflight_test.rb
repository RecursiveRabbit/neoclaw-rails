# The mesh preflight, tested on text — no podman, no tunnel.
#
# Three runs in one day reported `000` at the application layer with the cause two
# layers down: a generated `wg0.conf` whose `[Peer]` block had lost `AllowedIPs`.
# Each time it was patched at run time (`wg set … allowed-ips` plus a route), and
# each time the patch worked for the peers someone remembered.
#
# This row proves the tool that replaces the patch: it fails when any peer has no
# allowed ips, it passes when every peer has them, and it refuses to call an empty
# file a pass. It cannot prove reachability — that is the transport probe — and it
# does not repair a conf; it only refuses to start a run that cannot work.

require "test_helper"
require "open3"

class MeshPreflightTest < ActiveSupport::TestCase
  SCRIPT = Rails.root.join("deploy/babo/mesh-preflight.sh").to_s

  def preflight(input)
    out, err, status = Open3.capture3("bash", SCRIPT, "--stdin", stdin_data: input)
    [status.exitstatus, out, err]
  end

  test "a peer with no allowed ips fails the preflight, and the failure names it" do
    code, _out, err = preflight(<<~WG)
      interface: wg0
        public key: X
        listening port: 51820

      peer: AAA
        endpoint: 10.89.0.11:51820
        allowed ips: (none)
        latest handshake: 3 seconds ago

      peer: BBB
        allowed ips: 10.91.0.0/24
    WG

    assert_equal 1, code, "an empty allowed-ips must not pass"
    assert_includes err, "AAA", "the failure names the peer"
    assert_includes err, "no allowed ips"
  end

  test "every peer carrying allowed ips passes" do
    code, out, _err = preflight(<<~WG)
      interface: wg0

      peer: AAA
        allowed ips: 10.91.0.0/24

      peer: BBB
        allowed ips: 10.91.0.9/32
    WG

    assert_equal 0, code
    assert_includes out, "2 peer(s)"
  end

  test "an output with no peers at all is a failure, not a pass" do
    # "Nothing to check" and "everything checked out" are different facts, and
    # only one of them means the tunnel is ready.
    code, _out, err = preflight("interface: wg0\n  listening port: 51820\n")
    assert_equal 2, code
    assert_includes err, "not the same as a pass"
  end
end
