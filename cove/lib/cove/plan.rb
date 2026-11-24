require "ipaddr"
require "set"
require "yaml"

module Cove
  # The addressing plan: the only place in the Manager that decides which address a
  # pod gets, and the only place that knows the Router's address and port.
  #
  # It is DATA (state/plan.yml), because the numbers are a property of an
  # installation and not of this code. The rows address the plan through it: no row
  # retypes the Router's address or a pool prefix, because a literal that survives a
  # plan move turns a leak test into a green that cannot fail. That is a change of
  # 2026-11-23, made on the day this file's network moved for the first time -- the
  # literal version was fine only for as long as nobody moved it.
  #
  # A plan is a document someone can read and change without editing Ruby, and it is
  # now read by the thing that checks it.
  #
  # Allocation is deterministic and PERSISTED: a sheet keeps its pod_ip once it has
  # one, and the allocator hands out the lowest free number in its pool. A pod's
  # address must survive a Manager restart, because the Router's peer list and its
  # permits are keyed to it; a *key* does not survive, and never should (§13).
  module Plan
    DEFAULT = {
      "network" => "10.201.0.0/20",
      "router"  => {
        # The prefix length is NOT decoration, and a /32 is the wrong answer:
        # `wg set` installs no routes, and the only connected route the Router ever
        # gets is the one `ip addr add` makes for its own address. With a /32 the
        # Router has no route to any peer and sends service-bound packets out its
        # underlay NIC instead — measured on z620 2026-11-20: `ip route get
        # 10.201.1.10` answered `via 10.89.x.1 dev eth0`, i.e. a star that handshakes
        # and forwards nothing, and leaks toward whatever else owns the range on the
        # host. With the subnet here (/20) the same command answers `dev wg0`, and
        # WireGuard's cryptokey routing picks the peer. One prefix length is the
        # whole of the star's routing table.
        "address"   => "10.201.0.1/20",
        "listen"    => 51820,
        # The Router's host-side underlay: it is a pod on the underlay bridge, and
        # this is the address a pod's tunnel socket sends its UDP to.
        "transport" => "10.89.4.2"
      },
      # 10.89.0.0/24 is NOT free on this host: rootful neoclaw-isolated and a
      # leftover rootless cove-net both hold it, so Cove takes 10.89.4.0/24.
      #
      # This paragraph used to say the underlay sat "under the same /16 family" as
      # the tunnel, so a peer's bridge address stayed recognisable as Cove's. That
      # was false of both plans -- 10.89 is not inside 10.99 and never was -- and
      # it is dangerous as an idea: the underlay is the wire the tunnel rides ON.
      # Putting the Router's transport address inside the tunnel network would make
      # it a destination the tunnel is meant to carry, and the Router would have to
      # reach itself through itself. They are kept apart on purpose. Corrected
      # 2026-11-23 while moving the plan.
      "underlay" => { "network" => "cove-underlay", "subnet" => "10.89.4.0/24", "gateway" => "10.89.4.1" },
      "host"     => { "address" => "10.201.0.3" },
      "pools"    => { "agent" => "10.201.2", "service" => "10.201.1" },
      "first_host" => 10,
      "last_host"  => 250,
      # The UDP ports pods' tunnel sockets listen on. They are allocated and
      # persisted like the addresses, and for a harder reason: without a known port
      # the Router cannot know where a silent pod's socket is, and a peer that has
      # never spoken is a peer the Router answers "no route to host". See peer_port.
      "first_port" => 40000,
      "last_port"  => 41999
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
      # router's own address so the two cannot drift apart.
      #
      # "A peer allowed a subnet the Router does not route is a permit to nowhere" stood
      # here as a comment for three days and was never once measured -- the exact shape
      # of the fault it describes. It is measured now, from both ends: R6 and R16 ride
      # what the pod will actually encrypt for, R8 asserts every pod's default route,
      # and R22 proves a pod that loses its peer identity gets it back rather than being
      # silently subtracted. A property asserted in prose is a rumour until a row says
      # otherwise, so this comment now names its rows instead of being one.
      def wg_net          = data["network"].to_s
      def router_ip       = router_address.split("/").first.to_s
      def router_port     = router_listen
      def underlay        = data["underlay"] || {}
      def host_address    = data.dig("host", "address").to_s

      # The resolver a pod is told about at attach time. Evans, 2026-11-23: pods
      # reach DNS on the host through the Router until a Service pod serves it.
      #
      # Defaulted from the underlay gateway because that is where this host
      # answers -- measured on z620 2026-11-23, dnsmasq bound to 0.0.0.0:53 on udp
      # and tcp -- and because a partial plan is a set of decisions, not a broken
      # one. An installation that puts its resolver elsewhere says so in plan.yml.
      #
      # Returns "" when nothing can be named, and the caller must read that as
      # "write no resolver" rather than as a value: a pod pointed at an empty
      # nameserver does not fail loudly, it times out, which reads exactly like a
      # shut road.
      def dns_resolver
        explicit = data.dig("dns", "resolver").to_s
        return explicit unless explicit.empty?

        underlay.fetch("gateway", "").to_s
      end
      def first_host      = data["first_host"].to_i
      def last_host       = data["last_host"].to_i

      def pool_for(kind)
        pools = data["pools"] || {}
        prefix = pools[kind.to_s == "service" ? "service" : "agent"]
        raise Cove::DocumentError, "#{file}: no pool for kind #{kind.inspect}" if prefix.to_s.empty?

        prefix.to_s
      end

      # Does THIS plan route to THIS address? Asked of the network and not of the
      # spelling, the same way R23 asks it, and it exists because of what a plan move
      # leaves behind: `allocate` runs only when pod_ip is empty and `Launch.destroy!`
      # keeps pod_ip on purpose, so a sheet launched under the old plan holds an address
      # no Router will ever permit and nothing asks whether it is still an address.
      #
      # Three outcomes, and the third is not false. nil means the plan or the address
      # cannot be parsed, and a caller must not read that as "not ours": reallocating on
      # an unreadable plan is a guess wearing a fix's clothes, which is the same defect
      # R23 had on 2026-11-24 when it read an unparseable address as world-side.
      def covers?(addr)
        net = (IPAddr.new(wg_net) rescue nil)
        return nil if net.nil?

        ip = (IPAddr.new(addr.to_s) rescue nil)
        return nil if ip.nil?

        net.include?(ip)
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

      # The UDP port this sheet's socket listens on, allocated like an address and
      # persisted like one. This is what makes a peer's endpoint renderable, and a
      # rendered endpoint is what stops a silent pod from being unreachable: the
      # Router rebuilds its device on every change, and a rebuild forgets every
      # endpoint it learned. Measured on z620 2026-11-20: agent-a's SYN was forwarded
      # by the permit rule and came back "No route to host" because the service peer
      # had an allowed-ips and no endpoint — it had simply never spoken.
      def peer_port(sheet)
        return sheet.wg_port.to_i if sheet.wg_port.to_s.match?(/\A\d+\z/) && sheet.wg_port.to_i.positive?

        taken = Set.new(Sheet.all.reject { |s| s.slug == sheet.slug }.map(&:wg_port).map(&:to_i))
        (data["first_port"].to_i..data["last_port"].to_i).each do |n|
          return n unless taken.include?(n)
        end
        raise Cove::DocumentError, "no free tunnel port in #{data['first_port']}..#{data['last_port']} (plan #{file})"
      end

      # Where the Router should send a peer's packets: the host's own address on the
      # underlay bridge, because with the host-born ordering the pod's UDP socket is
      # born in the host namespace and its source address is the host's.
      def peer_endpoint(sheet)
        "#{underlay['gateway']}:#{peer_port(sheet)}"
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
      # An endpoint IS written for a pod peer (see peer_endpoint). This paragraph used
      # to say the opposite, and it was read as the opposite for three days: with the
      # host-born ordering the pod's UDP socket is opened on the host at the underlay
      # gateway, which the Manager DOES know, so the endpoint is renderable and the
      # Router does not have to wait to learn it. The old text argued that it could
      # not be known and that the Router would learn it from the first handshake --
      # which was true of the build on the box and false of this code, and the gap
      # between the two cost a day. A comment that is a true sentence about a
      # different program is the fault, not the fix.
      def network_map
        peers = {}
        Sheet.all.sort_by(&:slug).each do |s|
          next if s.pod_ip.to_s.empty? || s.pubkey.to_s.empty?

          peers["#{s.kind}:#{s.slug}"] = { "address" => s.pod_ip, "pubkey" => s.pubkey,
                                           "endpoint" => peer_endpoint(s) }
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
