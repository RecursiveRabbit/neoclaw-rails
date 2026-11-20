require "set"
require "yaml"

module Cove
  # The addressing plan: the only place in the Manager that decides which address a
  # pod gets, and the only place that knows the Router's address and port.
  #
  # It is DATA (state/plan.yml), because the numbers are a property of an
  # installation and not of this code. The acceptance suite addresses the plan by
  # literal (10.99.0.1 is the Router, 10.99.2.x agents, 10.99.1.x services), which
  # is exactly why the plan has to be a document someone can read and change
  # without editing Ruby.
  #
  # Allocation is deterministic and PERSISTED: a sheet keeps its pod_ip once it has
  # one, and the allocator hands out the lowest free number in its pool. A pod's
  # address must survive a Manager restart, because the Router's peer list and its
  # permits are keyed to it; a *key* does not survive, and never should (§13).
  module Plan
    DEFAULT = {
      "network" => "10.99.0.0/16",
      "router"  => {
        # The prefix length is NOT decoration, and a /32 is the wrong answer:
        # `wg set` installs no routes, and the only connected route the Router ever
        # gets is the one `ip addr add` makes for its own address. With a /32 the
        # Router has no route to any peer and sends service-bound packets out its
        # underlay NIC instead — measured on z620 2026-11-20: `ip route get
        # 10.99.1.10` answered `via 10.89.x.1 dev eth0`, i.e. a star that handshakes
        # and forwards nothing, and leaks toward whatever else owns 10.99/16 on the
        # host. With the subnet here (/16) the same command answers `dev wg0`, and
        # WireGuard's cryptokey routing picks the peer. One prefix length is the
        # whole of the star's routing table.
        "address"   => "10.99.0.1/16",
        "listen"    => 51820,
        # The Router's host-side underlay: it is a pod on the underlay bridge, and
        # this is the address a pod's tunnel socket sends its UDP to.
        "transport" => "10.89.4.2"
      },
      # 10.89.0.0/24 is NOT free on this host: rootful neoclaw-isolated and a
      # leftover rootless cove-net both hold it. Cove gets its own /24 under the
      # same /16 family so the bridge address that peers show up from is still
      # recognisable as Cove's.
      "underlay" => { "network" => "cove-underlay", "subnet" => "10.89.4.0/24", "gateway" => "10.89.4.1" },
      "host"     => { "address" => "10.99.0.3" },
      "pools"    => { "agent" => "10.99.2", "service" => "10.99.1" },
      "first_host" => 10,
      "last_host"  => 250
    }.freeze

    class << self
      def file = Cove.state_dir.join("plan.yml")

      # plan.yml overrides the default, key by key, at any depth. A partial plan is
      # a set of decisions, not a broken one.
      def data
        over = Cove.yaml_load(file) || {}
        raise Cove::DocumentError, "#{file}: plan must be a mapping" unless over.is_a?(Hash)
        merge(DEFAULT, over)
      end

      def router_address  = data.dig("router", "address").to_s
      def router_listen   = data.dig("router", "listen").to_i
      def router_transport = data.dig("router", "transport").to_s
      # The tunnel subnet, as a CIDR, for a peer's allowed-ips. Derived from the
      # router's own address so the two cannot drift apart: a peer allowed a
      # subnet the Router does not route is a permit to nowhere.
      def wg_net          = data["network"].to_s
      def router_ip       = router_address.split("/").first.to_s
      def router_port     = router_listen
      def underlay        = data["underlay"] || {}
      def host_address    = data.dig("host", "address").to_s
      def first_host      = data["first_host"].to_i
      def last_host       = data["last_host"].to_i

      def pool_for(kind)
        pools = data["pools"] || {}
        prefix = pools[kind.to_s == "service" ? "service" : "agent"]
        raise Cove::DocumentError, "#{file}: no pool for kind #{kind.inspect}" if prefix.to_s.empty?

        prefix.to_s
      end

      # Lowest free address in the sheet's pool. "Taken" includes every other
      # sheet's persisted pod_ip, because two pods with one address is not a
      # mistake the Router could recover from.
      def allocate(sheet)
        prefix = pool_for(sheet.kind)
        taken = Set.new(Sheet.all.reject { |s| s.slug == sheet.slug }.map(&:pod_ip).compact.reject(&:empty?))
        (first_host..last_host).each do |n|
          ip = "#{prefix}.#{n}"
          return ip unless taken.include?(ip)
        end
        raise Cove::DocumentError, "no free address in #{prefix}.0/24 (plan #{file})"
      end

      # Every service the Router may be told about, in one shape: name + "host:port".
      #
      # Two sources and one vocabulary. The service book holds things already
      # running somewhere (the host's services). A service-kind sheet is a thing
      # this Manager launched on the tunnel, and its address is its pod_ip and its
      # declared listen port. A name declared twice with two different addresses is
      # a contradiction, not a preference: refuse it rather than pick.
      def services
        out = {}
        (ServiceBook.all || []).each { |e| out[e.name] = e.address }
        Sheet.all.select { |s| s.kind == "service" }.sort_by(&:slug).each do |s|
          next if s.pod_ip.to_s.empty?

          address = "#{s.pod_ip}:#{s.listen}"
          if out.key?(s.slug) && out[s.slug] != address
            raise Cove::DocumentError,
                  "service #{s.slug.inspect} is declared twice: #{out[s.slug]} in the book, #{address} in its sheet"
          end
          out[s.slug] = address
        end
        out.sort.map { |name, address| ServiceBook::Entry.new(name: name, address: address) }
      end

      # The whole network, as RouterConfig v2 wants it.
      #
      # A sheet appears as a peer only once it has BOTH an address and a public key:
      # a peer line without a key is what the Router refuses as UNKEYED, and a peer
      # with no address cannot be permitted. So "not yet launched" renders as
      # absent, and the sheet's services render as unresolved — never as a guess.
      #
      # No endpoint is written for a pod peer, and that is deliberate: with the
      # host-born ordering the pod's UDP socket is opened on the host, so its source
      # port is the host's to choose and the Manager does not know it. The Router
      # learns it from the first handshake, and persistent-keepalive makes sure
      # there is one.
      def network_map
        peers = {}
        Sheet.all.sort_by(&:slug).each do |s|
          next if s.pod_ip.to_s.empty? || s.pubkey.to_s.empty?

          peers["#{s.kind}:#{s.slug}"] = { "address" => s.pod_ip, "pubkey" => s.pubkey }
        end
        { "router" => { "address" => router_address, "listen" => router_listen }, "peers" => peers }
      end

      private

      def merge(base, over)
        base.merge(over) do |_k, a, b|
          a.is_a?(Hash) && b.is_a?(Hash) ? merge(a, b) : b
        end
      end
    end
  end
end
