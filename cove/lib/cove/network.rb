require "digest"
require "ipaddr"
require "open3"
require "securerandom"
require "fileutils"
require "json"

module Cove
  # The pod's side of the tunnel, as code — the host-born ordering, learned the hard way.
  #
  #   1. ip link add wg-<slug> type wireguard      IN THE HOST NAMESPACE
  #   2. set private key, peer, endpoint, address
  #   3. ip link set wg-<slug> up                  the socket opens host-side
  #   4. ip link set wg-<slug> netns <pod pid>     and only now does the device move
  #   5. in the pod: rename, RE-ADD the address, up, `default dev wg0`
  #
  # Step 5's re-add is load-bearing: addresses do not survive a netns move, and without
  # it you get a tunnel that handshakes and carries nothing.
  #
  # Everything here is an argv array through sudo. No shell, no interpolation.
  module Network
    # Every number here is a default for a bare proof harness. The Manager always
    # passes the plan's values explicitly (see Plan), because the tunnel subnet and
    # the Router's transport address are properties of an installation and not of
    # this class. Left as ENV so script/net-proof still runs on its own.
    WG_NET      = ENV.fetch("COVE_WG_NET", "10.201.0.0/20")
    ROUTER_ADDR = ENV.fetch("COVE_ROUTER_ADDR", "10.201.0.1")

    # Evans, 2026-11-23: "The Router is a router, it's the default gateway for all
    # pods. Their Allowed IPs list for the Router connection should be 0.0.0.0/0, all
    # connections go through the router."
    #
    # This was the tunnel network, which put the pod's own cryptokey routing table
    # inside the Router's permit list -- two lists of what may be reached, able to
    # disagree without either being wrong. The Router's permits decide what exists;
    # the pod's table only decides what it will encrypt for.
    #
    # THE COST, written here because a ruling that hides its cost is a trap:
    # allowed-ips is BIDIRECTIONAL. On a peer it means both "encrypt to these" and
    # "accept these sources from this peer". At 0.0.0.0/0 the pod accepts anything
    # arriving through wg0, so its door no longer discriminates by source -- it
    # accepts the whole interface. The Router is the only peer and it is ours, so the
    # practical difference is small; the real difference is that the Router's rules
    # are now the ONLY thing deciding what may reach a pod, where there used to be
    # two independent places to be wrong. That is the trade Evans chose, and R16's
    # term4 condition exists so that whichever way it is set is visible in the run.
    PEER_ALLOWED_IPS = "0.0.0.0/0".freeze
    ROUTER_TRANSPORT = ENV.fetch("COVE_ROUTER_TRANSPORT", "10.89.4.2")
    ROUTER_PORT = Integer(ENV.fetch("COVE_ROUTER_PORT", "51820"))
    ROUTER_NAME = ENV.fetch("COVE_ROUTER_NAME", "cove-router")
    # IFNAMSIZ is 16 bytes, so 15 characters, and the kernel says so with an error
    # that names no field: "Attribute failed policy validation." Measured on z620
    # 2026-11-20 — `cove-wg-test-agent-a` is 19 characters and never existed for a
    # millisecond. The host-side name only has to survive one `ip link set ... netns`
    # before the device is renamed to wg0 inside the pod, so it is a short, stable
    # digest of the slug: readable enough in `ip link`, and never too long.
    IFACE_PREFIX = "cwg-".freeze
    IFACE_MAX = 15
    KEY_DIR = Pathname.new(ENV.fetch("COVE_STATE", "/tmp/cove-net"))
                        .join("keys")

    Step = Struct.new(:ok, :argv, :out, :err, keyword_init: true) do
      def ok? = !!ok
      def to_s = ok? ? "ok" : "#{argv.join(' ')} -> #{err.to_s.strip.split("\n").last}"
    end

    class << self
      def sudo(*argv) = run(*Cove.sudo_prefix, *argv)
      def host(*argv) = run(*argv)

      def run(*argv)
        out, err, st = Open3.capture3(*argv)
        Step.new(ok: st.success?, argv: argv, out: out, err: err)
      end

      # Writing a file INSIDE the pod needs the MOUNT namespace as well as the net one.
      # `nsenter -t <pid> -n` alone writes the HOST's /etc/resolv.conf -- measured
      # 2026-11-22, and it is why row 16 first reported a pod resolver as present when
      # the pod had none at all. Still argv-only: `tee` takes the content on stdin, so
      # a document is never interpolated into a command line.
      def write_in_pod(pid, path, content)
        out, err, st = Open3.capture3(*Cove.sudo_prefix, "nsenter", "-t", pid.to_s, "-m", "-n", "--",
                                      "tee", path, stdin_data: content.to_s)
        Step.new(ok: st.success?, argv: ["nsenter", "-t", pid.to_s, "-m", "-n", "--", "tee", path],
                 out: out, err: err)
      end

      # --- keys ---------------------------------------------------------------
      # The Manager holds the pod's keypair only long enough to set it from the host
      # side and then discard it (spec §2). On disk here for the proof harness; the
      # Manager's version keeps them in memory.
      def iface_for(slug)
        name = "#{IFACE_PREFIX}#{Digest::SHA256.hexdigest(slug.to_s)[0, 8]}"
        raise Cove::DocumentError, "interface name too long for IFNAMSIZ: #{name}" if name.length > IFACE_MAX

        name
      end

      def keypair(slug)
        FileUtils.mkdir_p(KEY_DIR, mode: 0o700)
        priv = KEY_DIR.join("#{slug}.key")
        unless priv.exist?
          FileUtils.chmod(0o700, KEY_DIR)
          raw, st = Open3.capture2("wg", "genkey")
          raise Cove::DocumentError, "wg genkey failed" unless st.success?
          File.write(priv, raw)
          File.chmod(0o600, priv)
        end
        # `wg pubkey` reads the private key on stdin; it takes no file argument
        pub, st = Open3.capture2("wg", "pubkey", stdin_data: File.read(priv))
        raise Cove::DocumentError, "wg pubkey failed" unless st.success?
        [priv.to_s, pub.strip]
      end

      # --- create -------------------------------------------------------------
      # Returns a Hash of facts; raises on the first step that fails, naming it.
      #
      # private_key: is the ephemeral path the Manager minted for this launch. When
      # it is given nothing is written under KEY_DIR: the pod's private key exists
      # only as that file, for as long as the `wg set` that reads it. The proof
      # harness passes nothing and gets the on-disk keypair instead.
      def attach(sheet_slug:, pod_ip:, image:, command: [], router_pub:, private_key: nil,
                 router_transport: ROUTER_TRANSPORT, router_port: ROUTER_PORT, wg_net: WG_NET,
                 listen_port: 0, router_addr: ROUTER_ADDR, dns_resolver: nil)
        # The pod's address must lie inside the plan's tunnel, and the check is here --
        # before anything is created -- because a persisted pod_ip outlives a plan change
        # and the failure that produces is silent: the pod comes up, the handshake
        # succeeds, and the Router, whose only route is the tunnel's own prefix, has
        # nowhere to send the reply. That is the measured shape of a star that
        # handshakes and forwards nothing.
        #
        # `wg_net` stopped being the peer's permit on 2026-11-23 (see PEER_ALLOWED_IPS),
        # and a parameter that is passed and then ignored is worse than one that is not
        # passed at all. So it keeps a job: it is the plan's claim about where its own
        # addresses live, and this is the one moment that claim is cheap to test.
        tunnel = begin
          IPAddr.new(wg_net.to_s)
        rescue StandardError
          nil
        end
        raise Cove::DocumentError, "attach #{sheet_slug}: wg_net #{wg_net.inspect} is not a CIDR" if tunnel.nil?

        pod_net = begin
          IPAddr.new(pod_ip.to_s)
        rescue StandardError
          nil
        end
        raise Cove::DocumentError, "attach #{sheet_slug}: #{pod_ip.inspect} is not an address" if pod_net.nil?
        unless tunnel.include?(pod_net)
          raise Cove::DocumentError,
                "attach #{sheet_slug}: #{pod_ip} is outside the plan's tunnel #{wg_net}. " \
                "A persisted pod_ip does not move when the plan does: clear this sheet's " \
                "pod_ip (or destroy and relaunch it) so the allocator can place it in the new range."
        end

        priv, pub = if private_key
                      [private_key.to_s, Keys.pubkey_of(File.read(private_key))]
                    else
                      keypair(sheet_slug)
                    end
        iface = iface_for(sheet_slug)
        pod = "cove-#{sheet_slug}"

        podman = run(*Cove.sudo_prefix, "podman", "run", "-d", "--name", pod, "--network", "none",
                     "--security-opt", "label=disable", *["--label", "cove.managed=1"],
                     *["--label", "cove.agent=#{sheet_slug}"], image, *command)
        raise Cove::DocumentError, "podman run: #{podman.err}" unless podman.ok?

        pid = run(*Cove.sudo_prefix, "podman", "inspect", "-f", "{{.State.Pid}}", pod).out.strip
        raise Cove::DocumentError, "no pid for #{pod}" if pid.empty? || pid == "0"

        # Idempotence, and the one step whose failure is not one: there is normally
        # no device by this name, and "nothing to delete" is the success case. It is
        # excluded by identity and not by pattern — the earlier version matched argv,
        # and adding `-E` to the priv esc shifted every position so the guard silently
        # stopped guarding and every first launch failed on its own cleanup.
        idempotent_del = sudo("ip", "link", "del", iface)
        steps = []
        steps << idempotent_del
        steps << sudo("ip", "link", "add", iface, "type", "wireguard")
        steps << sudo("ip", "addr", "add", "#{pod_ip}/32", "dev", iface)
        steps << sudo("wg", "set", iface, "private-key", priv, "listen-port", listen_port.to_s)
        steps << sudo("wg", "set", iface, "peer", router_pub,
                      "endpoint", "#{router_transport}:#{router_port}",
                      "allowed-ips", PEER_ALLOWED_IPS, "persistent-keepalive", "5")
        steps << sudo("ip", "link", "set", iface, "up")
        # the move
        steps << sudo("ip", "link", "set", iface, "netns", pid)
        steps << sudo("nsenter", "-t", pid, "-n", "ip", "link", "set", iface, "name", "wg0")
        steps << sudo("nsenter", "-t", pid, "-n", "ip", "addr", "add", "#{pod_ip}/32", "dev", "wg0")
        steps << sudo("nsenter", "-t", pid, "-n", "ip", "link", "set", "wg0", "up")
        steps << sudo("nsenter", "-t", pid, "-n", "ip", "route", "add", "default", "dev", "wg0")
        # The pod's own door (§15 row 3). The Router is the map of which roads exist;
        # the pod is the one place that can enforce "no road but the tunnel" without
        # asking anything: loopback and wg0, everything else dropped. Two layers,
        # because a pod that trusts the far end has no door of its own, and a Router
        # that is the only filter is one bug away from a leak.
        steps << sudo("nsenter", "-t", pid, "-n", "iptables", "-P", "INPUT", "DROP")
        steps << sudo("nsenter", "-t", pid, "-n", "iptables", "-P", "FORWARD", "DROP")
        steps << sudo("nsenter", "-t", pid, "-n", "iptables", "-P", "OUTPUT", "DROP")
        steps << sudo("nsenter", "-t", pid, "-n", "iptables", "-A", "INPUT", "-i", "lo", "-j", "ACCEPT")
        steps << sudo("nsenter", "-t", pid, "-n", "iptables", "-A", "OUTPUT", "-o", "lo", "-j", "ACCEPT")
        steps << sudo("nsenter", "-t", pid, "-n", "iptables", "-A", "INPUT", "-i", "wg0", "-j", "ACCEPT")
        steps << sudo("nsenter", "-t", pid, "-n", "iptables", "-A", "OUTPUT", "-o", "wg0", "-j", "ACCEPT")
        # THE POD'S RESOLVER, written at attach time from the plan. Evans, 2026-11-23:
        # until a Service pod serves DNS, the Agent pods reach DNS on the z620 through
        # the Router.
        #
        # It has to be written here rather than left to podman, because the pod is
        # created with --network none and -- measured 2026-11-22 -- has no
        # /etc/resolv.conf at all. A pod with no resolver cannot resolve the name R16
        # fetches, and R16 then reports that as an egress failure: the right fact read
        # by the wrong instrument.
        #
        # No resolver named in the plan means NO FILE, never an empty one. A nameserver
        # line with nothing after it does not fail loudly, it times out, and a DNS
        # timeout reads exactly like a shut road.
        unless dns_resolver.to_s.strip.empty?
          resolv = "# Written by Cove at attach time from plan.yml (dns.resolver).\n" \
                   "nameserver #{dns_resolver.to_s.strip}\n" \
                   "options timeout:2 attempts:2\n"
          steps << write_in_pod(pid, "/etc/resolv.conf", resolv)
        end
        failed = steps.reject { |s| s.equal?(idempotent_del) }.reject(&:ok?)
        unless failed.empty?
          # leave nothing half-built
          detach(sheet_slug)
          raise Cove::DocumentError, "attach #{sheet_slug}: #{failed.map(&:to_s).join('; ')}"
        end

        # Commission the tunnel: make the peer speak once, from inside its own
        # namespace. A peer that has never sent a packet has no endpoint as far as the
        # Router is concerned, and a peer with no endpoint is answered "no route to
        # host" — so "the pod is attached" is not the same claim as "the tunnel is
        # up", and only the second one is worth returning. The echo is allowed to
        # fail: it is here to cause a handshake, not to prove one.
        sudo("nsenter", "-t", pid, "-n", "ping", "-c", "1", "-W", "2", router_addr)

        { pod: pod, pid: pid.to_i, pubkey: pub, pod_ip: pod_ip, iface: "wg0" }
      end

      # --- destroy ------------------------------------------------------------
      # Pod, interface, key, and the Router's peer. Idempotent: destroying what is not
      # there is a success, because the state we want is "gone" either way.
      def detach(sheet_slug)
        iface = iface_for(sheet_slug)
        pod = "cove-#{sheet_slug}"
        results = []
        # --time 0, and it is measured, not defensive: a container's PID 1 that has not
        # installed a SIGTERM handler ignores it, and `sleep 86400` as PID 1 does
        # exactly that. podman then waits out its full ten-second grace period before
        # SIGKILL, which made a one-pod teardown take 10.7 s and read to the crank as
        # "http 0, the endpoint does not exist". Nothing here wants a graceful stop:
        # the pod is being destroyed.
        results << run(*Cove.sudo_prefix, "podman", "rm", "-f", "--time", "0", pod)
        results << sudo("ip", "link", "del", iface)
        FileUtils.rm_f(KEY_DIR.join("#{sheet_slug}.key").to_s)
        results
      end

      # Host-side leftovers for a sheet: the truth about "gone", asked of the kernel.
      def leftovers(sheet_slug)
        iface = iface_for(sheet_slug)
        {
          "interface" => run("ip", "link", "show", iface).ok?,
          "pod" => run(*Cove.sudo_prefix, "podman", "container", "exists", "cove-#{sheet_slug}").ok?,
          "key" => KEY_DIR.join("#{sheet_slug}.key").exist?
        }
      end
    end
  end
end
