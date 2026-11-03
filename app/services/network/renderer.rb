# frozen_string_literal: true

require "fileutils"
require "ipaddr"
require_relative "state"

module Network
  # Renders Manager desired state into:
  #
  #   1. the Router's network.json  — the ONLY thing the Router receives;
  #      raw addresses, keys, protocols, ports. No names.
  #   2. the host's WireGuard wg-quick config.
  #   3. an agent pod's WireGuard wg-quick config (peers ONLY with the
  #      Router; AllowedIPs = exactly the host IPs this identity is
  #      authorized to reach, never an ambient /8).
  #
  # Because rendering is a pure function of state, replacing the Router
  # from the same state yields the same IP, WireGuard key, and peer set —
  # an implementation replacement, not a network migration
  # (router/router.md "What replacement means").
  class Renderer
    class Error < StandardError; end

    def initialize(state)
      @state = state
    end

    # ---------------------------------------------------------------- Router
    # Writes network.json and the Router private key into out_dir, suitable
    # for mounting read-only at /etc/neoclaw in the Router container.
    def render_router_config(out_dir)
      FileUtils.mkdir_p(out_dir, mode: 0o700)
      conf = {
        "version" => State::VERSION,
        "interface" => "wg0",
        "address" => "#{@state.router_ip}/24",
        "listen_port" => @state.listen_port,
        "mtu" => @state.mtu,
        "agent_network" => @state.agent_network,
        "peers" => router_peers,
        "routes" => [{ "destination" => @state.agent_network }],
        "forward_rules" => forward_rules,
        "nat_rules" => []
      }
      File.write(File.join(out_dir, "network.json"), JSON.pretty_generate(conf) + "\n")
      key_dest = File.join(out_dir, "router.key")
      FileUtils.cp(@state.router_private_key_file, key_dest)
      FileUtils.chmod(0o600, key_dest)
      conf
    end

    def router_peers
      peers = [
        { "public_key" => @state.host_public_key,
          "allowed_ips" => ["#{@state.host_ip}/32"],
          "endpoint" => @state.host_endpoint,
          "persistent_keepalive" => 25 },
        { "public_key" => @state.manager_public_key,
          "allowed_ips" => ["#{@state.manager_ip}/32"],
          "endpoint" => @state.manager_endpoint,
          "persistent_keepalive" => 25 }
      ]
      @state.agents.each_value do |a|
        peers << {
          "public_key" => a["public_key"],
          "allowed_ips" => ["#{a['ip']}/32"],
          "endpoint" => a["endpoint"],
          "persistent_keepalive" => 25
        }.compact
      end
      peers
    end

    # Identity-level access translated into raw instructions the Router
    # applies. The Router does not learn that a source belongs to a
    # resident or that a port belongs to a named service. "manager" is an
    # identity like any other here — its rules are raw source/dest/proto/port
    # like everyone else's.
    def forward_rules
      @state.authorizations.map do |auth|
        ident = @state.agent(auth["agent"])
        svc   = @state.services.fetch(auth["service"])
        rule = {
          "source" => "#{ident['ip']}/32",
          "destination" => svc["host"],
          "protocol" => svc["protocol"]
        }
        rule["destination_port"] = svc["port"] if svc["port"]
        rule
      end
    end

    # ------------------------------------------------------------- host WG
    def host_wg_quick_config
      <<~CONF
        [Interface]
        Address = #{@state.host_ip}/24
        ListenPort = #{@state.listen_port}
        PrivateKey = #{File.read(priv_file("host")).strip}
        MTU = #{@state.mtu}

        [Peer]
        # Router — the path to every agent
        PublicKey = #{@state.router_public_key}
        Endpoint = #{@state.router_endpoint}
        AllowedIPs = #{@state.router_ip}/32, #{@state.agent_network}
        PersistentKeepalive = 25

        [Peer]
        # Manager — control access
        PublicKey = #{@state.manager_public_key}
        Endpoint = #{@state.manager_endpoint}
        AllowedIPs = #{@state.manager_ip}/32
        PersistentKeepalive = 25
      CONF
    end

    # ------------------------------------------------------------ agent WG
    # The pod pairs ONLY with the Router. Its AllowedIPs are exactly the
    # host IPs it is authorized to reach — no default route, no /8, no
    # peer route to any other agent. Port authorization still happens at
    # the Router's iptables; this is the pod-side half of fail-closed.
    def agent_wg_quick_config(name)
      ident = @state.agent(name)
      hosts = @state.authorized_services(name).map { |s| s["host"] }.uniq
      peer = if hosts.empty?
               "# No authorized services: this pod has no network path at all.\n# It is not peered with anything."
             else
               allowed = hosts.map { |h| "#{h}/32" }.join(", ")
               <<~PEER
                 [Peer]
                 # Router — the pod's ONLY peering
                 PublicKey = #{@state.router_public_key}
                 Endpoint = #{@state.router_endpoint}
                 AllowedIPs = #{allowed}
                 PersistentKeepalive = 25
               PEER
             end
      <<~CONF
        [Interface]
        Address = #{ident['ip']}/32
        ListenPort = #{@state.listen_port}
        PrivateKey = #{File.read(ident['private_key_file']).strip}
        MTU = #{@state.mtu}

        #{peer}
      CONF
    end

    def manager_wg_quick_config
      <<~CONF
        [Interface]
        Address = #{@state.manager_ip}/32
        ListenPort = #{@state.listen_port}
        PrivateKey = #{File.read(priv_file("manager")).strip}
        MTU = #{@state.mtu}

        [Peer]
        # Host — the Manager's only peering (control access).
        # Pod reachability is out of band (podman), not data-plane.
        PublicKey = #{@state.host_public_key}
        Endpoint = #{@state.host_endpoint}
        AllowedIPs = #{@state.host_ip}/32
        PersistentKeepalive = 25
      CONF
    end

    private

    def priv_file(who)
      case who
      when "host" then @state.host_private_key_file
      when "manager" then @state.manager_private_key_file
      else raise Error, "unknown key holder: #{who}"
      end
    end
  end
end
