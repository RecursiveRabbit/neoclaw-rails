#!/usr/bin/env ruby
# frozen_string_literal: true

# The Router.
#
# A dumb box with no configuration surface and no API: it reads one file, checks
# that the file is whole, and programs itself from it. It has no opinion about
# services — a permit names an address and a port, and the Router opens that road
# and no other. It does not know what a Forgejo is and never will.
#
# What it refuses to do is the point:
#   - a file whose body does not match its own sha256      -> exit 2 (a short file
#     can never pass for a whole one, which is what slice one's digest was for)
#   - a file that is not v2                                -> exit 2 (v1 has no
#     addresses or keys, so programming from it would be a guess)
#   - a directive it does not know                         -> exit 2 (never silently
#     ignore a line that might have been a permit)
#   - a peer with no key (UNKEYED)                         -> exit 2 (an absent key
#     must not look like a key)
#   - a malformed permit                                   -> exit 2
#
# Applied state is destroyed and rebuilt on every start. The Router has no
# incremental path, because the running config and the intended config are the
# same object (spec §5): a change means relaunch.

require "digest"

CONF = ARGV[0] || ENV.fetch("COVE_ROUTER_CONF", "/etc/cove/router.conf")
KEY  = ENV.fetch("COVE_ROUTER_KEY", "/etc/cove/router.key")
IFACE = ENV.fetch("COVE_ROUTER_IFACE", "wg0")
DRY = ENV["COVE_ROUTER_DRY"] == "1"

def die(reason)
  warn "router: refusing to program: #{reason}"
  exit 2
end

def run!(*argv)
  return puts("  (dry) #{argv.join(' ')}") if DRY
  out, err, st = Open3.capture3(*argv)
  unless st.success?
    die "command failed: #{argv.join(' ')} -- #{err.strip.empty? ? out.strip : err.strip}"
  end
  out
end

require "open3"

die "no config at #{CONF}" unless File.exist?(CONF)
raw = File.read(CONF)

# ---- the file must be whole ------------------------------------------------
digest_line = raw[/^body-sha256 ([0-9a-f]{64})$/, 1]
die "no body-sha256 line: this file cannot prove it is whole" unless digest_line
body = raw.split(/^body-sha256 [0-9a-f]{64}\n/, 2)[1]
die "nothing after the digest line" if body.nil? || body.strip.empty?
actual = Digest::SHA256.hexdigest(body)
die "body digest mismatch: file says #{digest_line[0, 12]}…, body is #{actual[0, 12]}…" unless actual == digest_line

# ---- parse ----------------------------------------------------------------
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
die "no router private key at #{KEY}" unless DRY || File.exist?(KEY)

# Every permit must land on a service line that exists; a permit to a service the
# file never describes is a road to nowhere, and a typo must not become a hole.
permits.each do |p|
  die "permit to an undeclared service: #{p[:svc]}" unless services.key?(p[:svc])
end

# ---- plan ------------------------------------------------------------------
puts "router: plan"
puts "  interface   #{IFACE}  #{router['address']}  listen #{router['listen']}"
puts "  peers       #{peers.size}"
peers.sort.each { |n, p| puts "    #{n.ljust(28)} #{p['address'].ljust(16)} #{p['pubkey'][0, 12]}…" }
puts "  services    #{services.size}"
services.sort.each { |n, s| puts "    #{n.ljust(28)} #{s['address']}:#{s['port']}" }
puts "  permits     #{permits.size}"
permits.each { |p| puts "    #{p[:src]} -> #{p[:svc]} (#{p[:to]}:#{p[:port]})" }
puts "  unresolved  #{unresolved.size} (no permit is rendered for these)" unless unresolved.empty?

# ---- tear down and rebuild --------------------------------------------------
system("ip", "link", "del", IFACE, out: File::NULL, err: File::NULL) unless DRY
system("iptables", "-F", "FORWARD", out: File::NULL, err: File::NULL) unless DRY

run!("ip", "link", "add", IFACE, "type", "wireguard")
run!("ip", "addr", "add", router["address"], "dev", IFACE)
run!("wg", "set", IFACE, "private-key", KEY, "listen-port", router["listen"].to_s)
peers.each { |_n, p| run!("wg", "set", IFACE, "peer", p["pubkey"], "allowed-ips", "#{p['address']}/32") }
run!("ip", "link", "set", IFACE, "up")

# Default deny in FORWARD. Nothing forwards that the file did not name.
run!("iptables", "-P", "FORWARD", "DROP")
run!("iptables", "-A", "FORWARD", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT")
permits.each do |p|
  # The Manager does not say whether a service speaks tcp or udp, and the Router
  # is not allowed to know. It opens the port on both, and says so here rather
  # than choosing a protocol on a service's behalf.
  %w[tcp udp].each do |proto|
    run!("iptables", "-A", "FORWARD", "-s", p[:src_addr], "-d", p[:to],
         "-p", proto, "--dport", p[:port], "-j", "ACCEPT")
  end
end

puts "router: programmed #{peers.size} peer(s), #{permits.size} permit(s) — #{unresolved.size} unresolved, no road"
