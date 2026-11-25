module Cove
  # The Router, as the Manager sees it: one pod, one key, one file.
  #
  # The Manager does not configure the Router. It launches it (spec §5, §15 row 4)
  # and then the Router programs itself from state/router.conf, and applies the whole
  # file again whenever the file changes. So "launch" is the Manager's only verb here,
  # and it is idempotent: a running Router is the desired state and is left alone.
  #
  # The Router's private key is the Manager's (§2): it is mounted read-only into the
  # pod and never copied in. A Router relaunch re-handshakes with the peers that
  # already exist instead of re-keying them.
  module RouterPod
    NAME  = ENV.fetch("COVE_ROUTER_NAME", "cove-router")
    IMAGE = ENV.fetch("COVE_ROUTER_IMAGE", "localhost/cove-router:soro")
    # The Router reads its file through a DIRECTORY mount, and that is load-bearing:
    # every write in this system is atomic (temp file, fsync, rename), and a bind
    # mount of a single FILE is pinned to the inode that existed at launch. Measured
    # on z620 2026-11-20: the first launch rendered router.conf, mounted it, and every
    # later render renamed a new file over the path — which the Router could not see,
    # so it never learned a peer. A directory mount follows the rename.
    MOUNT = "/etc/cove"
    CONF  = "#{MOUNT}/router.conf"
    KEY   = "#{MOUNT}/keys/router.key"

    # Evans, 2026-11-25 (vault/specs/Cove-Tests-2.md): "This change to the Manager's
    # intended Router configuration causes the Router to restart with that
    # configuration; the running configuration matches the intent."
    #
    # So the launcher runs router.rb ONCE and then holds the container open. There is no
    # watch loop any more: router.rb program-once-and-exit is what it now does, and the
    # netns has to outlive it because the interface and the iptables table live in it.
    #
    # THE `&&` IS LOAD-BEARING. router.rb exits 2 on a file it will not program, so a
    # refusal leaves the container DEAD rather than idling. This is the fix for a fault
    # that cost a day: the old loop caught a refusal, printed a line, and waited for a
    # whole file — while the pod stayed up and forwarded nothing, which reads exactly
    # like a pod that is up.
    ENTRYPOINT = "ruby /router/router.rb && exec sleep infinity"

    Result = Struct.new(:ok, :message, keyword_init: true) do
      def ok? = !!ok
    end

    class << self
      def exists?
        Podman.sudo("podman", "container", "exists", NAME).ok?
      end

      def running?
        r = Podman.sudo("podman", "container", "inspect", "-f", "{{.State.Running}}", NAME)
        r.ok? && r.stdout.strip == "true"
      end

      def pid
        r = Podman.sudo("podman", "inspect", "-f", "{{.State.Pid}}", NAME)
        r.ok? ? r.stdout.strip : ""
      end

      # Creates the underlay bridge the Router is a pod on, with the subnet the
      # plan says. The Router's transport address (the one pods send UDP to) has to
      # be inside it, so a default podman network will not do.
      def ensure_underlay!
        net = Plan.underlay["network"].to_s
        return true if Podman.sudo("podman", "network", "exists", net).ok?

        subnet = Plan.underlay["subnet"].to_s
        gateway = Plan.underlay["gateway"].to_s
        r = Podman.sudo("podman", "network", "create",
                       "--subnet", subnet, "--gateway", gateway, net)
        raise Cove::DocumentError, "underlay network #{net} not created: #{r.message}" unless r.ok?

        true
      end

      # => Result. Launches only if it is not already running; removes a dead pod of
      # the same name first, because podman will not reuse a name.
      def ensure!
        ensure_underlay!
        # The file has to exist before it is bind-mounted: podman creates a
        # DIRECTORY where the source of a bind mount is missing, and then the Router
        # refuses a config it cannot read. Rendering first is also the honest order:
        # the Router is launched holding the intent as it is.
        RouterConfig.write!(Plan.network_map)
        # The key has to exist before the Router starts: the mount is read-only, so a
        # Router that has to generate one could not write it back, and §2 says this key
        # is the Manager's to keep. It is created once and reused, so a relaunch
        # re-handshakes with the existing peers instead of re-keying the fleet.
        Keys.ensure_router!
        return Result.new(ok: true, message: "router already running") if running?

        Podman.sudo("podman", "rm", "-f", NAME) if exists?

        argv = [
          *Cove.sudo_prefix, "podman", "run", "-d",
          "--name", NAME,
          "--network", Plan.underlay["network"].to_s,
          "--ip", Plan.router_transport,
          "--security-opt", "label=disable",
          "--cap-add", "NET_ADMIN",
          "--cap-add", "NET_RAW",
          "--sysctl", "net.ipv4.ip_forward=1",
          "--label", "cove.managed=1",
          "--label", "cove.router=1",
          "-v", "#{Cove.state_dir}:#{MOUNT}:ro",
          # router.rb takes the file as ARGV[0] or COVE_ROUTER_CONF, and its own KEY
          # default is /etc/cove/router.key — which is not where the Manager keeps the
          # key. Measured: the Router ran, refused every file with "no router private
          # key at /etc/cove/router.key", and sat there being a pod that had
          # programmed nothing. Both paths are said out loud here.
          "-e", "COVE_ROUTER_CONF=#{CONF}",
          "-e", "COVE_ROUTER_KEY=#{KEY}",
          "-e", "COVE_ROUTER_IFACE=wg0",
          "--entrypoint", "/bin/sh",
          IMAGE, "-c", ENTRYPOINT
        ]
        r = Podman.run(*argv)
        raise Cove::DocumentError, "router did not launch: #{r.message}" unless r.ok?

        Result.new(ok: true, message: "router launched on #{Plan.router_transport}")
      end

      # ---- restart, because a change to the intent IS a restart ----------------
      #
      # Evans, 2026-11-25: "causes the Router to restart with that configuration; the
      # running configuration matches the intent." Two obligations in one sentence, and
      # they are not the same obligation: restart it, AND be able to say the running
      # configuration is the intent. So a restart here is not done until the Router has
      # said so in its own log, and a Router that died instead is an error, not a delay.

      # The count of "router: programmed" lines the container has ever printed. Counted
      # rather than searched, because `podman restart` keeps the container's log: a plain
      # search finds the PREVIOUS start's line and reports it as this one's. That is the
      # whole of this helper's reason to exist.
      def programmed_count
        r = Podman.sudo("podman", "logs", NAME)
        r.ok? ? r.stdout.to_s.scan("router: programmed").size : -1
      end

      def last_programmed_line
        r = Podman.sudo("podman", "logs", NAME)
        return nil unless r.ok?

        r.stdout.to_s.lines.reverse.find { |l| l.include?("router: programmed") }&.strip
      end

      def restart!
        return Result.new(ok: false, message: "no Router pod named #{NAME} to restart") unless exists?

        before = programmed_count
        r = Podman.sudo("podman", "restart", NAME)
        return Result.new(ok: false, message: "router restart failed: #{r.message}") unless r.ok?

        await_programmed!(after: before)
      end

      # Waits for a NEW "router: programmed" line, then returns it. The message carries the
      # counts the Router printed, so a caller can compare them with the intent it
      # rendered — that comparison is the spec's "running configuration matches the
      # intent", and this is the only instrument in the system that can make it.
      def await_programmed!(after:, within: 25)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
        loop do
          now = programmed_count
          if now.positive? && now > after
            return Result.new(ok: true, message: last_programmed_line.to_s)
          end
          return Result.new(ok: false, message: "could not read the Router's log") if now.negative?

          running = Podman.sudo("podman", "container", "inspect", "-f", "{{.State.Running}}", NAME)
          if running.ok? && running.stdout.strip == "false"
            # router.rb refuses with exit 2, and the launcher's `&&` makes a refusal a dead
            # container. Saying so here is the difference between "the Router is up and
            # forwarding nothing" and "the Router refused the file".
            tail = Podman.sudo("podman", "logs", "--tail", "5", NAME).stdout.to_s.strip
            return Result.new(ok: false,
                              message: "router EXITED without programming — it refused the file: #{tail}")
          end
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            return Result.new(ok: false, message: "router did not report programming within #{within}s")
          end

          sleep 0.2
        end
      end

      # Called from RouterConfig.write!, the one function every intent change passes
      # through. Two guards, both to stop it doing damage:
      #   - not running: the bootstrap renders BEFORE it launches, so there is nothing to
      #     restart yet, and restarting a pod that does not exist is an error;
      #   - identical bytes: the render is deterministic, so most writes change nothing,
      #     and restarting a tunnel because somebody opened a page is a fault of its own.
      def restart_if_changed!(previous, current)
        return Result.new(ok: true, message: "router not running — nothing to restart") unless running?
        return Result.new(ok: true, message: "intent unchanged — no restart") if previous == current

        restart!
      end

      # Does the Router say it holds this key? Asked of its own namespace, because
      # `wg set` works over netlink in there and `wg show` reads sysfs and cannot.
      def holds_peer?(pubkey, within: 5)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + within
        loop do
          return true if peers.include?(pubkey.to_s)

          return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          sleep 0.2
        end
      end

      def peers
        p = pid
        return [] if p.empty? || p == "0"

        r = Podman.sudo("nsenter", "-t", p, "-n", "wg", "show", "wg0", "peers")
        r.ok? ? r.stdout.split("\n").map(&:strip).reject(&:empty?) : []
      end
    end
  end
end
