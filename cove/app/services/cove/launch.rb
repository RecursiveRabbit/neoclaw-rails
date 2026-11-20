module Cove
  # The start button's real body: make one sheet true.
  #
  # This is the piece slice one did not have. There, "start" meant `podman run` on a
  # bridge network and the sheet never learned anything. Here a launch is four steps
  # that must all have happened or none of them may be believed:
  #
  #   1. the Router is running (row 4), and it is the Router's own file that peers it;
  #   2. the sheet has an address from the plan;
  #   3. the pod exists with `--network none` and a WireGuard interface created in the
  #      host namespace, moved in, and re-addressed inside (Cove::Network);
  #   4. the sheet keeps the address and the PUBLIC key, and the private key is gone.
  #
  # Step 4 in that order matters: the sheet is written only after the attach has
  # succeeded, so a failed launch cannot leave a peer in router.conf for a pod that
  # does not exist. And the key that is discarded is the reason a destroyed pod can
  # never be inherited: there is no old identity on disk to inherit (§2, §13).
  #
  # The peer only reaches the Router when the file is re-rendered and the Router
  # applies it, so the last thing a launch does is WAIT for the Router to say it
  # holds that key. A launch that returns before then is a launch that lies: the pod
  # is up, its tunnel handshakes into a drop, and the first ping is the one that
  # finds out.
  module Launch
    PEER_WAIT = Float(ENV.fetch("COVE_PEER_WAIT", "10"))

    Result = Struct.new(:ok, :message, :facts, keyword_init: true) do
      def ok? = !!ok
    end

    class << self
      def ensure!(sheet)
        raise Cove::DocumentError, "podman is not available to this Manager (#{Podman.why_unavailable})" unless Podman.available?

        RouterPod.ensure!

        current = Sheet.find(sheet.slug) || sheet
        if running?(current)
          return already_running(current) unless current.pubkey.to_s.empty? || current.pod_ip.to_s.empty?

          # A pod is up that the Manager holds no peer for: it cannot vouch for its
          # key, and re-attaching would only steal an interface from a stranger.
          return Result.new(ok: false,
                            message: "#{current.pod_name} is running but this Manager holds no peer for it; " \
                                     "destroy it and start again")
        end

        pod_ip = current.pod_ip.to_s.empty? ? Plan.allocate(current) : current.pod_ip
        port = Plan.peer_port(current)
        key = Keys.ephemeral
        begin
          facts = Network.attach(
            sheet_slug: current.slug,
            pod_ip: pod_ip,
            image: current.image,
            command: current.command_argv,
            router_pub: Keys.router_pubkey,
            private_key: key.path,
            router_transport: Plan.router_transport,
            router_port: Plan.router_port,
            wg_net: Plan.wg_net,
            listen_port: port,
            router_addr: Plan.router_ip
          )
        ensure
          Keys.discard(key) # the pod's private key does not outlive this call
        end

        current.assign("pod_ip" => pod_ip, "pubkey" => key.pubkey, "wg_port" => port.to_s)
        current.save!
        RouterConfig.write!(Plan.network_map)

        unless RouterPod.holds_peer?(key.pubkey, within: PEER_WAIT)
          return Result.new(ok: false, facts: facts,
                            message: "#{facts[:pod]} is up at #{pod_ip} and dressed, but the Router did not take its " \
                                     "key within #{PEER_WAIT}s — the tunnel would handshake into a drop")
        end

        Result.new(ok: true,
                   message: "#{facts[:pod]} up at #{pod_ip}, peered with the Router",
                   facts: facts)
      rescue Cove::DocumentError => e
        Result.new(ok: false, message: e.message)
      end

      # Destroy one sheet: pod, interface, key, and its road on the Router.
      #
      # The Router is not a sheet, so it is not destroyed here — it is emptied, by
      # re-rendering an intent that no longer names this peer. The address is kept
      # (an address is the sheet's, and a relaunch should get it back); the key is
      # not (an identity is the pod's, and a reborn pod must not inherit one).
      def destroy!(sheet)
        Network.detach(sheet.slug)
        current = Sheet.find(sheet.slug) || sheet
        current.assign("pubkey" => "")
        current.save!
        RouterConfig.write!(Plan.network_map)
        Result.new(ok: true, message: "#{current.pod_name} destroyed")
      rescue Cove::DocumentError => e
        Result.new(ok: false, message: e.message)
      end

      # After any change to the intent the Router rebuilds its device, and a rebuild
      # forgets every endpoint it had learned. WireGuard cannot be told an endpoint
      # from the file — the Router parses `endpoint=` and does not pass it to
      # `wg set` — so the only way a peer becomes addressable again is to speak.
      # Measured on z620 2026-11-20: after a rebuild, 1 of 4 peers had an endpoint;
      # the rest returned one per five seconds of keepalive, and the tunnel was
      # unreachable for about fifteen. So the Manager nudges: one echo per live pod,
      # from inside its own namespace, immediately after the file changes.
      def recommission!
        Sheet.all.each do |s|
          next unless s.pod_ip.to_s.empty?

          pid = Podman.sudo("podman", "inspect", "-f", "{{.State.Pid}}", s.pod_name)
          next unless pid.ok? && pid.stdout.strip != "0"

          Network.sudo("nsenter", "-t", pid.stdout.strip, "-n", "ping", "-c", "1", "-W", "1", Plan.router_ip)
        end
        true
      rescue StandardError
        false
      end

      def destroy_all!
        # Only sheets with a pod standing are touched. A sheet is a document; a
        # teardown destroys pods, and destroying a document because a suite asked
        # for "nothing left running" would be a different verb wearing this one's
        # name.
        doomed = Sheet.all.select { |s| pod_exists?(s) }
        failures = []
        doomed.each do |s|
          r = destroy!(s)
          failures << "#{s.slug}: #{r.message}" unless r.ok?
        end
        # One render at the end, from whatever the sheets now say, so the Router is
        # left holding no peer even if one sheet's teardown went wrong.
        RouterConfig.write!(Plan.network_map)
        if failures.empty?
          Result.new(ok: true, message: doomed.empty? ? "no pods to destroy" :
                                                      "destroyed #{doomed.map(&:pod_name).join(' ')}")
        else
          Result.new(ok: false, message: failures.join("; "))
        end
      rescue Cove::DocumentError => e
        Result.new(ok: false, message: e.message)
      end

      def pod_exists?(sheet)
        Podman.sudo("podman", "container", "exists", sheet.pod_name).ok?
      end

      private

      def running?(sheet)
        r = Podman.sudo("podman", "container", "inspect", "-f", "{{.State.Running}}", sheet.pod_name)
        r.ok? && r.stdout.strip == "true"
      end

      def already_running(sheet)
        Result.new(ok: true, message: "#{sheet.pod_name} is already running at #{sheet.pod_ip}")
      end
    end
  end
end
