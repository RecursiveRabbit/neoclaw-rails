# The seam.
#
# The router does not exist yet. When it does, it will be a dumb box that reads
# this file and nothing else — so this file is the entire contract between what
# Evans clicks and what the network will be.
#
# Three properties, and each one is enforced by the code below rather than by a
# comment in a spec:
#
#   1. TOTAL.  render/2 takes only the two document sets and emits every line
#              the intent implies. There is no patch path, no diff, no append.
#   2. PURE.   No timestamps, no hostnames of the moment, no query results.
#              Identical intent renders identical bytes, so `git diff` on this
#              file shows intent changes and nothing else.
#   3. HONEST. An agent that names a service the service book does not have is
#              rendered as `unresolved`, never silently dropped and never
#              invented. The file says what the Manager could not decide.
module Cove
  module RouterConfig
    FORMAT_VERSION = 1
    # v2 is the network the Router can actually program: peers with keys and
    # addresses, services with a port, permits resolved to an address:port, and a
    # digest so a short file cannot pass for a whole one. v1 is what the Manager
    # writes today; the Router reads v2 and refuses v1 loudly rather than half-
    # configuring itself.
    NETWORK_VERSION = 2

    class << self
      # => String, the whole configuration, every time.
      #
      # net: nil  -> v1, byte-identical to the format the Manager already writes.
      # net: hash -> v2, the whole network. Keys:
      #   "router"  => { "address" => "10.99.0.1/24", "listen" => 51820 }
      #   "peers"   => { "agent:alpha" => { "address" => "10.99.2.10", "pubkey" => "..." }, ... }
      def render(agents, services, net = nil)
        return render_v1(agents, services) if net.nil?
        render_v2(agents, services, net)
      end

      def render_v1(agents, services)
        agents = agents.sort_by(&:slug)
        services = services.sort_by(&:name)
        known = services.map(&:name)

        lines = []
        lines << "# cove router intent — the whole of it, rewritten whole on every change."
        lines << "# Read by the router and by nothing else. Do not edit: the Manager overwrites this file."
        lines << "# No timestamps: identical intent renders identical bytes, so a diff shows only intent."
        lines << "version #{FORMAT_VERSION}"
        lines << ""

        agents.each do |agent|
          allowed = agent.services.uniq.sort
          lines << %(agent "#{q(agent.slug)}"#{allowed.empty? ? "" : %( services="#{q(allowed.join(" "))}")})
        end

        unless services.empty?
          lines << ""
          services.each { |s| lines << %(service "#{q(s.name)}" address="#{q(s.address)}") }
        end

        allows = []
        unresolved = []
        agents.each do |agent|
          agent.services.uniq.sort.each do |service_name|
            if known.include?(service_name)
              allows << [agent.slug, service_name]
            else
              unresolved << [agent.slug, service_name]
            end
          end
        end

        unless allows.empty?
          lines << ""
          lines << "# permits: a pod may reach exactly what is listed here and nothing else"
          allows.sort.each { |a, s| lines << %(allow "#{q(a)}" "#{q(s)}") }
        end

        unless unresolved.empty?
          lines << ""
          lines << "# unresolved: named by a sheet, absent from the service book — the Manager cannot decide these"
          unresolved.sort.each { |a, s| lines << %(unresolved "#{q(a)}" "#{q(s)}") }
        end

        lines << ""
        lines << "# agents=#{agents.size} services=#{services.size} allows=#{allows.size} unresolved=#{unresolved.size}"
        lines.join("\n") + "\n"
      end

      # v2: the whole network, in a shape a dumb Router can program without
      # consulting anything else — including this code.
      def render_v2(agents, services, net)
        require "digest"
        agents = agents.sort_by(&:slug)
        services = services.sort_by(&:name)
        known = services.map(&:name)
        peers = (net["peers"] || {})
        router = (net["router"] || {})

        body = []
        body << "version #{NETWORK_VERSION}"
        # `dns` is the resolver the pods are told about at attach time, and the Router
        # needs it too: it is the one host service a pod is allowed to reach, and the
        # rule that permits it has to be written beside the rules that deny the rest of
        # the private network -- or a reader has to guess which is meant.
        dns = Cove::Plan.dns_resolver
        router_line = %(router address="#{q(router['address'].to_s)}" listen="#{q(router['listen'].to_s)}")
        router_line += %( dns="#{q(dns)}") unless dns.to_s.empty?
        body << router_line
        body << ""

        # Peers, sorted by key. A peer with no key is written UNKEYED and the
        # Router refuses to program it: an absent key must not look like a key.
        peers.keys.sort.each do |name|
          p = peers[name].to_h
          key = p["pubkey"].to_s
          # endpoint is OPTIONAL and it is the host-side underlay address, never the
          # pod's tunnel address: with the netns-move pattern the pod's UDP socket is
          # born host-side, so the Router has to send to the host, not to the tunnel.
          # Absent endpoint = this peer initiates and the Router learns it on handshake.
          ep = p["endpoint"].to_s
          line = %(peer "#{q(name)}" address="#{q(p['address'].to_s)}" pubkey="#{q(key.empty? ? 'UNKEYED' : key)}")
          line += %( endpoint="#{q(ep)}") unless ep.empty?
          body << line
        end

        body << ""
        services.each do |s|
          host, port = split_address(s.address)
          body << %(service "#{q(s.name)}" address="#{q(host)}" port="#{q(port)}")
        end

        permits = []
        unresolved = []
        # A permit's source is the *peer name*, not the slug: the Router is dumb and
        # must not be asked to guess a naming convention. If the network map does
        # not name a peer for a live sheet, that is a peer the Router cannot open a
        # road for, and the file says so rather than guessing.
        peer_for = lambda do |slug|
          return "agent:#{slug}" if peers.key?("agent:#{slug}")
          return slug if peers.key?(slug)
          nil
        end

        agents.each do |agent|
          agent.services.uniq.sort.each do |service_name|
            svc = services.find { |s| s.name == service_name }
            src_peer = peer_for.call(agent.slug)
            if svc.nil?
              unresolved << [agent.slug, service_name]
            elsif src_peer.nil?
              unresolved << [agent.slug, "peer-not-in-network-map"]
            else
              host, port = split_address(svc.address)
              permits << [src_peer, service_name, host, port]
            end
          end
        end

        unless permits.empty?
          body << ""
          body << "# permits: the only roads. Anything not listed here is refused by default."
          permits.sort.each { |a, s, h, p| body << %(permit "#{q(a)}" "#{q(s)}" to="#{q(h)}" port="#{q(p)}") }
        end

        unless unresolved.empty?
          body << ""
          body << "# unresolved: the Manager could not decide these — the Router will not guess"
          unresolved.sort.each { |a, s| body << %(unresolved "#{q(a)}" "#{q(s)}") }
        end

        body << ""
        body << "# peers=#{peers.size} services=#{services.size} permits=#{permits.size} unresolved=#{unresolved.size}"
        body_text = body.join("\n") + "\n"

        # The digest covers the body only, so the header stays out of the hash.
        header = []
        header << "# cove router intent v#{NETWORK_VERSION} — the whole network, rewritten whole."
        header << "# Read by the Router and by nothing else. Do not edit: the Manager overwrites this file."
        # The sentence here used to say "the last line of this file is the sha256 of
        # every line above it", which was false in both halves: the digest is the
        # fourth line, and it covers what comes BELOW it. The desk filed it on
        # 2026-11-20 (pass 42, Finding 1) and it has been rendered to whoever opened
        # /router.conf ever since -- an instrument under oath with prose about the
        # instrument that was not, in the one place a reader is invited to check.
        header << "# body-sha256 on the next line covers every line BELOW it, the footer included."
        header << "# It cannot be the last line: the footer is part of the body it hashes. A short file cannot pass."
        header << "body-sha256 #{Digest::SHA256.hexdigest(body_text)}"
        header.join("\n") + "\n" + body_text
      end

      # A service address is `host:port`. The Manager does not know what the
      # service is; it only knows it has one address, and the Router needs two
      # fields. A malformed address is refused rather than guessed at.
      def split_address(address)
        s = address.to_s.strip
        host, port = s.split(":", 2)
        if host.to_s.empty? || port.to_s.empty?
          raise Cove::DocumentError, "service address is not host:port: #{s.inspect}"
        end
        [host, port]
      end

      # Render from what is on disk and write it. The only writer of router.conf.
      # Any mutation anywhere calls this; there is nowhere else to call.
      def write!(net = nil)
        agents = Sheet.all
        # Before the render, heal any sheet that has an address but has lost its public
        # key. A peer line needs both, so a sheet missing its key renders as absent and
        # the Router subtracts a LIVE pod's peer -- measured, twice, with nothing
        # reported. See Cove::Recover for why the repair is possible and why it lives
        # here: this is the one function every intent change passes through.
        healed = Cove::Recover.identities!(agents)
        # The map the caller passed was built from the sheets as they were BEFORE the
        # heal, so a recovered peer is missing from it -- the repair applied after the
        # thing it repairs had already been read. R22 caught exactly this: the sheet came
        # back and the Router still held no peer for it. Recompute whenever something
        # actually changed; when nothing did, the caller's map is still true and costs
        # nothing.
        net = Plan.network_map if net && !healed.empty?
        # NOT ServiceBook.all. A service is a name and an address, and it can come
        # from two places: the book (things already running somewhere) and a
        # service-kind sheet (a thing this Manager launched on the tunnel). The plan
        # is the one place that merges them into one vocabulary. Measured on z620
        # 2026-11-20: rendering from the book alone left all four test permits
        # "unresolved", the Router opened no road, and rows 12-18 could not move
        # while every peer line looked perfectly correct.
        services = Plan.services
        body = render(agents, services, net)
        previous = self.current
        Cove.write_atomic(Cove.router_file, body)
        # THE CHANGE RESTARTS THE ROUTER, AND THE RUNNING CONFIGURATION MATCHES THE INTENT.
        # Evans, 2026-11-25 (vault/specs/Cove-Tests-2.md). write! is the one function every
        # intent change passes through, so it is the one place that can honour that
        # sentence. Guarded inside: not running (the bootstrap renders before it launches)
        # and identical bytes (the render is deterministic) both return without touching a
        # live tunnel.
        #
        # Not raised: a Router that refuses its file must not make the sheet edit that
        # produced it look like the sheet's fault. restart! distinguishes the two in its
        # message, and a dead Router is visible in `podman ps`.
        RouterPod.restart_if_changed!(previous, body)
        body
      end

      def current
        File.exist?(Cove.router_file) ? File.read(Cove.router_file) : nil
      end

      private

      # The format is one-line-per-fact, split on whitespace outside quotes. A
      # quote inside a name would break a dumb reader, so it is refused loudly
      # rather than escaped into something the reader cannot see.
      def q(value)
        s = value.to_s
        if s.include?('"') || s.include?("\n")
          raise Cove::DocumentError, "cannot render a value containing a quote or newline: #{s.inspect}"
        end
        s
      end
    end
  end
end
