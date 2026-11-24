#!/usr/bin/env ruby
# frozen_string_literal: true

# The Router.
#
# A dumb box with no configuration surface and no API: it reads one file, checks
# that the file is whole, and programs itself from it. It has no opinion about
# services — a permit names an address and a port, and the Router opens that road
# and no other. It does not know what a Forgejo is and never will.
#
# It REFUSES, with one line on stderr and exit 2, on: a body whose sha256 does not
# match its own digest line; a v1 file (no addresses, no keys); a directive it does
# not know; a peer with no key (UNKEYED); a permit to a service the file never
# declares; a malformed permit. It never skips a line it did not understand: a line
# that might have been a permit is not a line to ignore.
#
# It re-reads that same file continuously and diff-applies a change. That is not a
# configuration surface — there is no command, no socket, no verb, and no second
# input. Measured on z620 (2026-11-19): a cold program is ~471 ms, almost all of it
# container and interpreter start; a re-apply is ~20 ms, because `wg syncconf` never
# takes the interface down and `iptables-restore` replaces the whole table atomically.
# The running config and the intended config stay the same object; the gap between
# them is now the diff-apply, not the relaunch.

require "digest"
require "open3"

CONF  = ARGV[0] || ENV.fetch("COVE_ROUTER_CONF", "/etc/cove/router.conf")
KEY   = ENV.fetch("COVE_ROUTER_KEY", "/etc/cove/router.key")
IFACE = ENV.fetch("COVE_ROUTER_IFACE", "wg0")
DRY   = ENV["COVE_ROUTER_DRY"] == "1"
WATCH = ENV.fetch("COVE_ROUTER_WATCH", "1") == "1"

def die(reason)
  warn "router: refusing to program: #{reason}"
  exit 2
end

def run!(*argv)
  return puts("  (dry) #{argv.join(' ')}") if DRY
  out, err, st = Open3.capture3(*argv)
  die "command failed: #{argv.join(' ')} -- #{err.strip.empty? ? out.strip : err.strip}" unless st.success?
  out
end

# ---- the file must be whole ------------------------------------------------
def verify(raw)
  digest_line = raw[/^body-sha256 ([0-9a-f]{64})$/, 1]
  die "no body-sha256 line: this file cannot prove it is whole" if digest_line.nil?
  body = raw.split(/^body-sha256 [0-9a-f]{64}\n/, 2)[1]
  die "nothing after the digest line" if body.nil? || body.strip.empty?
  actual = Digest::SHA256.hexdigest(body)
  die "body digest mismatch: file says #{digest_line[0, 12]}…, body is #{actual[0, 12]}…" unless actual == digest_line
  body
end

# ---- parse -----------------------------------------------------------------
def parse(body)
  router = nil
  peers = {}
  services = {}
  permits = []
  egress = []
  unresolved = []
  version = nil

  body.each_line do |line|
    line = line.chomp
    next if line.empty? || line.start_with?("#")

    word, rest = line.split(" ", 2)
    kv = Hash[rest.to_s.scan(/(\w+)="([^"]*)"/)]

    case word
    when "version"
      version = rest.to_s.strip.to_i
    when "router"
      router = kv
    when "peer"
      name = rest[/\A"([^"]*)"/, 1]
      die "peer with no name" if name.nil?
      die "peer #{name} has no key (UNKEYED)" if kv["pubkey"].to_s.empty? || kv["pubkey"] == "UNKEYED"
      die "peer #{name} has no address" if kv["address"].to_s.empty?
      peers[name] = kv
    when "service"
      name = rest[/\A"([^"]*)"/, 1]
      die "service with no name" if name.nil?
      die "service #{name} has no address/port" if kv["address"].to_s.empty? || kv["port"].to_s.empty?
      services[name] = kv
    when "permit"
      src = rest[/\A"([^"]*)"/, 1]
      svc = rest[/\A"[^"]*" "([^"]*)"/, 1]
      die "malformed permit: #{line}" if src.nil? || svc.nil? || kv["to"].to_s.empty? || kv["port"].to_s.empty?
      src_addr = peers.dig(src, "address")
      die "permit names a pod with no peer line: #{src}" if src_addr.nil?
      permits << { src: src, src_addr: src_addr, svc: svc, to: kv["to"], port: kv["port"] }
    when "egress"
      # A BASELINE ROAD OUT, and the one permit no sheet can remove.
      #
      # Evans, 2026-11-23: "until then, the Agent pods should reach DNS on the Z620
      # through the router." This device's FORWARD policy is DROP, so a resolver that
      # no permit names is a resolver no pod can reach. Measured on z620 2026-11-24:
      # the pod's query ARRIVED here and the policy counter ate it (3 packets seen by
      # a hand-added rule in the same position), and the host saw nothing at all — so
      # the first diagnosis, "the Router is not forwarding", was wrong in the useful
      # direction: it was forwarding until the policy stopped it.
      #
      # An egress names an ADDRESS AND A PORT, not a service, and that is deliberate.
      # A permit names a service so that a typo cannot become a hole (see the check at
      # the tail of this parse). The resolver has no sheet and no service line, so the
      # only thing that can be verified about it is that it is an address.
      #
      # ABSENCE IS ACCEPTED IN THIS RELEASE. The renderer does not emit egress yet, and
      # a Router that refused a file without one would take the fleet dark the moment it
      # was deployed. Order of landing: the Router learns to accept it (here), then the
      # Manager starts emitting it, then a later Router may refuse a file without one.
      # `die` on an unknown directive still stands — that is what makes this order
      # mandatory rather than polite.
      to = kv["to"].to_s
      port = kv["port"].to_s
      die "malformed egress (needs to= and port=): #{line}" if to.empty? || port.empty?
      egress << { name: rest[/\A"([^"]*)"/, 1], to: to, port: port }
    when "unresolved"
      unresolved << line
    else
      die "unknown directive #{word.inspect} — a line the Router does not understand is never skipped"
    end
  end

  die "not a v2 file (version #{version.inspect}): v1 has no addresses or keys and cannot be programmed from" unless version == 2
  die "no router line" if router.nil? || router["address"].to_s.empty?

  # A permit to a service the file never describes is a road to nowhere, and a
  # typo must not become a hole.
  permits.each do |p|
    die "permit to an undeclared service: #{p[:svc]}" unless services.key?(p[:svc])
  end

  [peers, router, permits, unresolved, egress]
end

# ---- apply -----------------------------------------------------------------
def apply(peers, permits, router, egress, first:)
  if first
    system("ip", "link", "del", IFACE, out: File::NULL, err: File::NULL) unless DRY
    run!("ip", "link", "add", IFACE, "type", "wireguard")
    run!("ip", "addr", "add", router["address"], "dev", IFACE)
    run!("wg", "set", IFACE, "private-key", KEY, "listen-port", router["listen"].to_s)
    peers.each_value do |p|
      argv = ["wg", "set", IFACE, "peer", p["pubkey"], "allowed-ips", "#{p['address']}/32"]
      argv += ["endpoint", p["endpoint"]] unless p["endpoint"].to_s.empty?
      run!(*argv)
    end
    run!("ip", "link", "set", IFACE, "up")
  else
    # The Router's key does not CHANGE on a re-apply (the Manager holds it, spec §4),
    # so the diff is peers only — and syncconf leaves the interface up, so established
    # tunnels are not reset. "Does not change" was read for a day as "does not need
    # re-asserting", and that reading cost the fleet: see below.
    conf = +"[Interface]\n"
    conf << "ListenPort = #{router['listen']}\n"
    peers.each_value do |p|
      conf << "\n[Peer]\nPublicKey = #{p['pubkey']}\nAllowedIPs = #{p['address']}/32\n"
      conf << "Endpoint = #{p['endpoint']}\n" unless p["endpoint"].to_s.empty?
    end
    tmp = "/tmp/wg-sync.conf"
    File.write(tmp, conf)
    run!("wg", "syncconf", IFACE, tmp)
    File.unlink(tmp)
    # What was MEASURED on z620 2026-11-22: after one in-place apply, `wg show wg0`
    # printed no public key; four peers kept their endpoints and allowed-ips and
    # every one of them went silent; every row that reads the file still read a
    # correct configuration. Setting the key by hand restored four handshakes in
    # under four seconds, and the next render took it away again.
    #
    # What that means, stated no more strongly than the control supports: the sync
    # conf's [Interface] block named only ListenPort, and after the sync the device
    # had no identity. wg(8) describes setconf as applying the fields the block
    # NAMES and removing all peers; on wireguard-tools v1.0.20210914 the observed
    # behaviour is that an unnamed PrivateKey does not survive an in-place sync --
    # a scratch netns, key set, sync with ListenPort alone: public key gone; the
    # same sync with PrivateKey named: public key back. soro read the same page and
    # expected the other outcome, which is why the assertion at the tail of `apply`
    # exists: the docs and the box disagree, so the code must not take either on
    # faith. The key is re-asserted here from the read-only mount by PATH, so it
    # lands in neither the sync conf nor argv.
    #
    # Known and accepted: between the sync and this line the device is keyless for
    # well under a millisecond. A peer handshaking exactly there is dropped and
    # retries. It is not worth closing and it is worth saying.
    run!("wg", "set", IFACE, "private-key", KEY, "listen-port", router["listen"].to_s)
  end

  # One atomic replace of the whole filter table: at no instant is the chain
  # half-written, and the policy is DROP for everything the file did not name.
  # A permit is a port, not a protocol — the Manager is not allowed to know whether
  # a service speaks tcp or udp, so the Router opens both and says so here.
  rules = +"*filter\n:FORWARD DROP [0:0]\n"
  rules << "-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n"
  permits.each do |p|
    %w[tcp udp].each do |proto|
      rules << "-A FORWARD -s #{p[:src_addr]} -d #{p[:to]} -p #{proto} -m #{proto} --dport #{p[:port]} -j ACCEPT\n"
    end
  end
  # egress: one rule per PEER per egress, so the source is the pod's own address and
  # not the tunnel's. That is the same identity the permit rules are written against,
  # and it is the reason a per-pod address survives this device at all — a rule keyed
  # to the tunnel would let the single largest claim in this file ("a permit names a
  # pod") degrade into "a permit names the network".
  egress.each do |e|
    peers.each_value do |p|
      %w[tcp udp].each do |proto|
        rules << "-A FORWARD -s #{p['address']} -d #{e[:to]} -p #{proto} -m #{proto} --dport #{e[:port]} -j ACCEPT\n"
      end
    end
  end
  rules << "COMMIT\n"

  # NO NAT TABLE, AND THIS PARAGRAPH IS WHY. A nat/MASQUERADE rule stood here on
  # 2026-11-23 (11e5fbb) and was withdrawn the same day, because it was the wrong
  # instrument aimed at a real fault.
  #
  # The fault was real: a packet forwarded out this device carried its source still in
  # the tunnel, and nothing upstream could return it. But the answer to "nothing routes
  # this back" is a route, not a translation. Evans' ruling is "the host is essentially
  # giving the Router web access, not the Agent pods" -- that is a POLICY statement
  # about whose traffic the host admits (the Router's), and it is satisfied by a
  # FORWARD accept keyed to this device's ingress. It does not ask the Router to erase
  # who is speaking.
  #
  # And translation actively removes the thing the ruling asks for next: "Replies cannot
  # go through the LAN gateway. That path needs to be blocked." A masqueraded flow needs
  # no route back to the pod at all -- conntrack unwrites the translation -- so the
  # return-route requirement becomes vacuous and `ip route get <pod>` stops meaning
  # anything. A construction that makes the requirement it was built beside unmeasurable
  # is the wrong construction.
  #
  # So this Router routes. Per-pod source addresses survive it, which is the identity the
  # permit rules are written against and the identity the Mint architecture preserves.
  # If anything translates, it translates at the edge that owns the public address --
  # z620 -- where the translation is one hop from the world and no longer inside the
  # architecture. The host-side routes (the pod subnets via this device) are the
  # requirement, and they are the host's to install.
  if DRY
    puts "  (dry) iptables-restore <<< #{rules.lines.size} lines"
  else
    out, err, st = Open3.capture3("iptables-restore", stdin_data: rules)
    die "iptables-restore failed: #{err.strip.empty? ? out.strip : err.strip}" unless st.success?
  end

  # Soro's condition, 2026-11-22, and he is right that it is the condition and not
  # a nicety: the fix made the state correct, it did not make the fault loud, and
  # this fault cost a day precisely because nothing announced it. A verb that cannot
  # confirm must not report success. At the tail of apply so that the `first:` path
  # is covered by the same assertion as the in-place one.
  pub = run!("wg", "show", IFACE, "public-key").to_s.strip
  if pub.empty?
    die "apply left the Router with no identity: `wg show #{IFACE} public-key` is empty " \
        "(#{peers.size} peer(s) programmed, key re-asserted from #{KEY})"
  end
end

def plan(peers, services, permits, unresolved, router, egress)
  puts "router: plan"
  puts "  interface   #{IFACE}  #{router['address']}  listen #{router['listen']}"
  puts "  peers       #{peers.size}"
  peers.sort.each { |n, p| puts "    #{n.ljust(28)} #{p['address'].ljust(16)} #{p['pubkey'][0, 12]}…" }
  puts "  services    #{services.size}"
  services.sort.each { |n, s| puts "    #{n.ljust(28)} #{s['address']}:#{s['port']}" }
  puts "  permits     #{permits.size}"
  permits.each { |p| puts "    #{p[:src]} -> #{p[:svc]} (#{p[:to]}:#{p[:port]})" }
  puts "  egress      #{egress.size} (baseline, every peer)"
  egress.each { |e| puts "    #{e[:name].to_s.ljust(28)} -> #{e[:to]}:#{e[:port]}" }
  puts "  unresolved  #{unresolved.size} (no permit is rendered for these)" unless unresolved.empty?
end

# ---- run -------------------------------------------------------------------
die "no config at #{CONF}" unless File.exist?(CONF)
raw = File.read(CONF)
body = verify(raw)
peers, router, permits, unresolved, egress = parse(body)
services = Hash[body.each_line.grep(/^service /).map { |l| [l[/\A"([^"]*)"/] || l[/"([^"]*)"/, 1], { "address" => l[/address="([^"]*)"/, 1], "port" => l[/port="([^"]*)"/, 1] }] }]
die "no router private key at #{KEY}" unless DRY || File.exist?(KEY)

plan(peers, services, permits, unresolved, router, egress)
apply(peers, permits, router, egress, first: true)
puts "router: programmed #{peers.size} peer(s), #{permits.size} permit(s), #{egress.size} egress road(s) — " \
     "#{unresolved.size} unresolved, no road"

if WATCH
  last = Digest::SHA256.hexdigest(raw)
  puts "router: watching #{CONF} — diff-apply only, the interface stays up"
  loop do
    sleep 0.02
    begin
      now_raw = File.read(CONF)
    rescue Errno::ENOENT
      next
    end
    h = Digest::SHA256.hexdigest(now_raw)
    next if h == last
    last = h
    begin
      b = verify(now_raw)                      # a file that cannot prove itself is never applied, even hot
      p2, r2, perms2, _u2, e2 = parse(b)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      apply(p2, perms2, r2, e2, first: false)
      dt = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round(1)
      warn "router: re-applied #{perms2.size} permit(s), #{p2.size} peer(s) in #{dt} ms"
    rescue SystemExit
      warn "router: keeping the old configuration — the new file was refused"
    rescue => e
      warn "router: keeping the old configuration — #{e.class}: #{e.message}"
    end
  end
end
