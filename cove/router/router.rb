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
# It reads that file ONCE, programs itself, and exits; the launcher holds the container
# open and the Manager RESTARTS it when the intent changes (Evans, 2026-11-25). That is
# not a configuration surface either — no command, no socket, no verb, no second input,
# and no re-read: the file is the intent at the moment of the start, and the running
# configuration is that intent or the container is dead. Measured on z620 (2026-11-19):
# a cold program is ~471 ms, almost all of it container and interpreter start, and the
# programming itself is ~210 ms in a bare netns.

require "digest"
require "open3"

CONF  = ARGV[0] || ENV.fetch("COVE_ROUTER_CONF", "/etc/cove/router.conf")
KEY   = ENV.fetch("COVE_ROUTER_KEY", "/etc/cove/router.key")
IFACE = ENV.fetch("COVE_ROUTER_IFACE", "wg0")
DRY   = ENV["COVE_ROUTER_DRY"] == "1"

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

  [peers, router, permits, unresolved]
end

# ---- apply -----------------------------------------------------------------
def apply(peers, permits, router)
# One start, one program. Evans, 2026-11-25 (vault/specs/Cove-Tests-2.md): a change to
# the Manager's intended Router configuration RESTARTS this container, so the running
# configuration matches the intent. There is no in-place re-apply and no watch loop any
# more, and the sync path is deleted rather than left dead: the device is built from
# nothing on every start, so no field can survive unnamed and there is no window in
# which the device has no identity.
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

  # One atomic replace of the whole filter table: at no instant is the chain
  # half-written, and the policy is DROP for everything the file did not name.
  # A permit is a port, not a protocol — the Manager is not allowed to know whether
  # a service speaks tcp or udp, so the Router opens both and says so here.
  rules = +"*filter\n:FORWARD DROP [0:0]\n"
  rules << "-A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n"

  # THE PODS' ROAD TO THE WORLD, AND THE ONLY PLACE TRANSIT POLICY LIVES.
  #
  # Evans, 2026-11-25: "ip_tables is the rules that the router runs, not something that
  # must be configured each pod." So the whole transit decision is this ordered list,
  # and a pod's own firewall has one job left: make its service reachable.
  #
  # The policy is three sentences, and each one belongs to somebody:
  #   a pod MAY reach the world through this device -- it is the pods' default gateway,
  #     and Evans' ruling is that its allowed-ips is 0.0.0.0/0 "and nothing weaker";
  #   a pod may NOT reach the private network. That is what "neither agent can connect to
  #     a service listening on the host" means once the host is a machine with a dozen
  #     addresses rather than one. The resolver is the named exception (Evans 2026-11-23:
  #     the agent pods reach DNS on the z620 through the router);
  #   a pod may NOT reach another pod, except where a permit names the pair.
  #
  # ORDER IS THE IMPLEMENTATION. Permits first, because they are the exceptions the
  # Manager granted; then the resolver; then the denials; then the world. A DROP placed
  # before a permit's ACCEPT would make every permit invisible, and it would read from
  # every row as "the permit does not work".
  net = router["address"].to_s
  dns = router["dns"].to_s
  permits.each do |p|
    # A PERMIT NAMES A SERVICE, AND A SERVICE IS NOT ALWAYS A PORT.
    #
    # Evans, 2026-11-25: "service-pod-a and service-pod-b, ICMP is their service." A pod
    # that answers pings has no port to open, so `port="icmp"` is the permit's whole
    # content: one protocol, no destination port, and the Router opens exactly that. The
    # alternative -- opening tcp and udp on a port nothing listens on -- would be a permit
    # to a road with no traffic, which is the shape of fault this file exists to refuse.
    if p[:port].to_s.strip.downcase == "icmp"
      rules << "-A FORWARD -s #{p[:src_addr]} -d #{p[:to]} -p icmp -j ACCEPT\n"
    else
      %w[tcp udp].each do |proto|
        rules << "-A FORWARD -s #{p[:src_addr]} -d #{p[:to]} -p #{proto} -m #{proto} --dport #{p[:port]} -j ACCEPT\n"
      end
    end
  end
  unless dns.empty? || net.empty?
    rules << "-A FORWARD -s #{net} -d #{dns} -p udp -m udp --dport 53 -j ACCEPT\n"
    rules << "-A FORWARD -s #{net} -d #{dns} -p tcp -m tcp --dport 53 -j ACCEPT\n"
  end
  unless net.empty?
    rules << "-A FORWARD -s #{net} -d #{net} -j DROP\n"
    # RFC1918, CGNAT and link-local: the private network is not the world. Written as an
    # explicit denial list rather than as an absence, so a reader can see the shape
    # without holding the whole routing table in their head.
    %w[10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16].each do |priv|
      rules << "-A FORWARD -s #{net} -d #{priv} -j DROP\n"
    end
    rules << "-A FORWARD -s #{net} -j ACCEPT\n"
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
  # confirm must not report success. At the tail of apply, on the only path there is,
  # so a device that lost its identity under any future change cannot report success.
  pub = run!("wg", "show", IFACE, "public-key").to_s.strip
  if pub.empty?
    die "apply left the Router with no identity: `wg show #{IFACE} public-key` is empty " \
        "(#{peers.size} peer(s) programmed, key re-asserted from #{KEY})"
  end
end

def plan(peers, services, permits, unresolved, router)
  puts "router: plan"
  puts "  interface   #{IFACE}  #{router['address']}  listen #{router['listen']}"
  puts "  peers       #{peers.size}"
  peers.sort.each { |n, p| puts "    #{n.ljust(28)} #{p['address'].ljust(16)} #{p['pubkey'][0, 12]}…" }
  puts "  services    #{services.size}"
  services.sort.each { |n, s| puts "    #{n.ljust(28)} #{s['address']}:#{s['port']}" }
  puts "  permits     #{permits.size}"
  permits.each { |p| puts "    #{p[:src]} -> #{p[:svc]} (#{p[:to]}:#{p[:port]})" }
  puts "  unresolved  #{unresolved.size} (no permit is rendered for these)" unless unresolved.empty?
end

# ---- run -------------------------------------------------------------------
die "no config at #{CONF}" unless File.exist?(CONF)
raw = File.read(CONF)
body = verify(raw)
peers, router, permits, unresolved = parse(body)
services = Hash[body.each_line.grep(/^service /).map { |l| [l[/\A"([^"]*)"/] || l[/"([^"]*)"/, 1], { "address" => l[/address="([^"]*)"/, 1], "port" => l[/port="([^"]*)"/, 1] }] }]
die "no router private key at #{KEY}" unless DRY || File.exist?(KEY)

plan(peers, services, permits, unresolved, router)
apply(peers, permits, router)
puts "router: programmed #{peers.size} peer(s), #{permits.size} permit(s) — #{unresolved.size} unresolved, no road"

# Nothing left to do and nothing left running: the launcher runs this file once and
# holds the container open, and every intent change restarts it. A refusal above exits 2
# and the container dies, which is the honest shape of a Router that will not program.
