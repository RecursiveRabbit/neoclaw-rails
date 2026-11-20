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
    CONF  = "/etc/cove/router.conf"
    KEY   = "/etc/cove/router.key"

    # soro's router.rb programs itself and then EXITS — measured on z620 2026-11-20
    # (exit 0, ~0.3 s, pod gone). §5 as ruled wants the process kept and the whole
    # file re-applied in place, so the launcher keeps it alive and re-runs it when,
    # and only when, the file's own body digest changes.
    #
    # This is a launch argument and not a change to his artefact: the programming
    # logic stays entirely his, and `podman inspect` shows this loop. If he would
    # rather the watch lived in the image, this string is the thing to delete.
    #
    # It cannot hide a fault: router.rb validates digest, version, directives and
    # permits *before* it tears anything down, so a bad file leaves the running
    # configuration untouched and the loop keeps waiting for a good one.
    WATCH = <<~SH.gsub("\n", " ").strip
      last="";
      while :; do
        cur=$(sed -n "s/^body-sha256 //p" #{CONF} 2>/dev/null | head -1);
        if [ -n "$cur" ] && [ "$cur" != "$last" ]; then
          if ruby /router/router.rb; then last="$cur"; else echo "router: refused, waiting for a whole file"; sleep 2; fi;
        fi;
        sleep 0.2;
      done
    SH

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
          "-v", "#{Cove.router_file}:#{CONF}:ro",
          "-v", "#{Keys.ensure_router!}:#{KEY}:ro",
          "--entrypoint", "/bin/sh",
          IMAGE, "-c", WATCH
        ]
        r = Podman.run(*argv)
        raise Cove::DocumentError, "router did not launch: #{r.message}" unless r.ok?

        Result.new(ok: true, message: "router launched on #{Plan.router_transport}")
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
