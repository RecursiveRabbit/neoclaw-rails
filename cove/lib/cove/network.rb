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
    WG_NET      = ENV.fetch("COVE_WG_NET", "10.99.0.0/16")
    ROUTER_ADDR = ENV.fetch("COVE_ROUTER_ADDR", "10.99.0.1")
    ROUTER_TRANSPORT = ENV.fetch("COVE_ROUTER_TRANSPORT", "10.89.4.2")
    ROUTER_PORT = Integer(ENV.fetch("COVE_ROUTER_PORT", "51820"))
    ROUTER_NAME = ENV.fetch("COVE_ROUTER_NAME", "cove-router")
    IFACE_PREFIX = "cove-wg-".freeze
    KEY_DIR = Pathname.new(ENV.fetch("COVE_STATE", "/tmp/cove-net"))
                        .join("keys")

    Step = Struct.new(:ok, :argv, :out, :err, keyword_init: true) do
      def ok? = !!ok
      def to_s = ok? ? "ok" : "#{argv.join(' ')} -> #{err.to_s.strip.split("\n").last}"
    end

    class << self
      def sudo(*argv) = run("sudo", *argv)
      def host(*argv) = run(*argv)

      def run(*argv)
        out, err, st = Open3.capture3(*argv)
        Step.new(ok: st.success?, argv: argv, out: out, err: err)
      end

      # --- keys ---------------------------------------------------------------
      # The Manager holds the pod's keypair only long enough to set it from the host
      # side and then discard it (spec §2). On disk here for the proof harness; the
      # Manager's version keeps them in memory.
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
                 router_transport: ROUTER_TRANSPORT, router_port: ROUTER_PORT, wg_net: WG_NET)
        priv, pub = if private_key
                      [private_key.to_s, Keys.pubkey_of(File.read(private_key))]
                    else
                      keypair(sheet_slug)
                    end
        iface = "#{IFACE_PREFIX}#{sheet_slug}"
        pod = "cove-#{sheet_slug}"

        podman = run("sudo", "podman", "run", "-d", "--name", pod, "--network", "none",
                     "--security-opt", "label=disable", *["--label", "cove.managed=1"],
                     *["--label", "cove.agent=#{sheet_slug}"], image, *command)
        raise Cove::DocumentError, "podman run: #{podman.err}" unless podman.ok?

        pid = run("sudo", "podman", "inspect", "-f", "{{.State.Pid}}", pod).out.strip
        raise Cove::DocumentError, "no pid for #{pod}" if pid.empty? || pid == "0"

        steps = []
        steps << sudo("ip", "link", "del", iface)          # idempotence: never two
        steps << sudo("ip", "link", "add", iface, "type", "wireguard")
        steps << sudo("ip", "addr", "add", "#{pod_ip}/32", "dev", iface)
        steps << sudo("wg", "set", iface, "private-key", priv, "listen-port", "0")
        steps << sudo("wg", "set", iface, "peer", router_pub,
                      "endpoint", "#{router_transport}:#{router_port}",
                      "allowed-ips", wg_net, "persistent-keepalive", "15")
        steps << sudo("ip", "link", "set", iface, "up")
        # the move
        steps << sudo("ip", "link", "set", iface, "netns", pid)
        steps << sudo("nsenter", "-t", pid, "-n", "ip", "link", "set", iface, "name", "wg0")
        steps << sudo("nsenter", "-t", pid, "-n", "ip", "addr", "add", "#{pod_ip}/32", "dev", "wg0")
        steps << sudo("nsenter", "-t", pid, "-n", "ip", "link", "set", "wg0", "up")
        steps << sudo("nsenter", "-t", pid, "-n", "ip", "route", "add", "default", "dev", "wg0")
        failed = steps.reject(&:ok?).reject { |s| s.argv[1, 4] == ["ip", "link", "del", iface] }
        unless failed.empty?
          # leave nothing half-built
          detach(sheet_slug)
          raise Cove::DocumentError, "attach #{sheet_slug}: #{failed.map(&:to_s).join('; ')}"
        end

        { pod: pod, pid: pid.to_i, pubkey: pub, pod_ip: pod_ip, iface: "wg0" }
      end

      # --- destroy ------------------------------------------------------------
      # Pod, interface, key, and the Router's peer. Idempotent: destroying what is not
      # there is a success, because the state we want is "gone" either way.
      def detach(sheet_slug)
        iface = "#{IFACE_PREFIX}#{sheet_slug}"
        pod = "cove-#{sheet_slug}"
        results = []
        results << run("sudo", "podman", "rm", "-f", pod)
        results << sudo("ip", "link", "del", iface)
        FileUtils.rm_f(KEY_DIR.join("#{sheet_slug}.key").to_s)
        results
      end

      # Host-side leftovers for a sheet: the truth about "gone", asked of the kernel.
      def leftovers(sheet_slug)
        iface = "#{IFACE_PREFIX}#{sheet_slug}"
        {
          "interface" => run("ip", "link", "show", iface).ok?,
          "pod" => run("sudo", "podman", "container", "exists", "cove-#{sheet_slug}").ok?,
          "key" => KEY_DIR.join("#{sheet_slug}.key").exist?
        }
      end
    end
  end
end
