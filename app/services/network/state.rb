# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "address_plan"
require_relative "key_material"

module Network
  # The Manager's desired-state record for the whole WireGuard network.
  #
  # Ownership (docs/NETWORK.md): the Manager owns every peer's addressing
  # and peering data, the Router's private key, and the mapping from an
  # identity to its authorized destination ports. The Router owns none of
  # that semantics. State is plain JSON plus key files in a mode-0700
  # directory; there is no Router-side counterpart of any of this.
  #
  # State layout under state_dir:
  #   state.json          — identities, peers, services, authorizations
  #                         (public key material only)
  #   keys/<name>.key     — WireGuard private keys (mode 600, never
  #                         printed, never committed)
  class State
    VERSION = 1

    class Error < StandardError; end

    attr_reader :dir

    def self.init(dir, router_endpoint:, host_endpoint:, manager_endpoint:)
      raise Error, "state dir already initialized: #{dir}" if File.exist?(File.join(dir, "state.json"))

      FileUtils.mkdir_p(dir, mode: 0o700)
      router = KeyMaterial.generate!(dir, "router")
      host   = KeyMaterial.generate!(dir, "host")
      mgr    = KeyMaterial.generate!(dir, "manager")

      state = {
        "version" => VERSION,
        "network" => {
          "router_ip"    => AddressPlan::ROUTER_IP,
          "host_ip"      => AddressPlan::HOST_IP,
          "manager_ip"   => AddressPlan::MANAGER_IP,
          "agent_network" => AddressPlan::AGENT_NET,
          "listen_port"  => AddressPlan::WG_PORT,
          "mtu"          => AddressPlan::WG_MTU,
          "router_endpoint"  => router_endpoint,
          "host_endpoint"    => host_endpoint,
          "manager_endpoint" => manager_endpoint
        },
        "router"  => { "public_key" => router.public_key, "private_key_file" => router.private_key_file },
        "host"    => { "public_key" => host.public_key,   "private_key_file" => host.private_key_file },
        "manager" => { "public_key" => mgr.public_key,    "private_key_file" => mgr.private_key_file },
        "agents"  => {},
        "services" => {},
        "authorizations" => []
      }
      new(dir, state).tap(&:save!)
    end

    def self.load(dir)
      path = File.join(dir, "state.json")
      raise Error, "no state: #{path}" unless File.readable?(path)
      new(dir, JSON.parse(File.read(path)))
    end

    def initialize(dir, data)
      @dir = dir
      @data = data
    end

    def save!
      path = File.join(dir, "state.json")
      tmp = "#{path}.tmp"
      File.write(tmp, JSON.pretty_generate(@data) + "\n")
      FileUtils.chmod(0o600, tmp)
      File.rename(tmp, path)
      self
    end

    def net = @data["network"]

    def router_public_key = @data["router"]["public_key"]
    def host_public_key   = @data["host"]["public_key"]
    def manager_public_key = @data["manager"]["public_key"]

    def router_private_key_file  = @data["router"]["private_key_file"]
    def host_private_key_file    = @data["host"]["private_key_file"]
    def manager_private_key_file = @data["manager"]["private_key_file"]

    def router_ip  = net["router_ip"]
    def host_ip    = net["host_ip"]
    def manager_ip = net["manager_ip"]

    def agent_network = net["agent_network"]
    def listen_port   = net["listen_port"]
    def mtu           = net["mtu"]
    def router_endpoint   = net["router_endpoint"]
    def host_endpoint     = net["host_endpoint"]
    def manager_endpoint  = net["manager_endpoint"]

    def add_agent!(name, endpoint: nil, ip: nil)
      raise Error, "agent already exists: #{name}" if @data["agents"].key?(name)
      pair = KeyMaterial.generate!(dir, "agent-#{name}")
      ip ||= AddressPlan.next_agent_ip(@data["agents"].values.map { |a| a["ip"] })
      @data["agents"][name] = {
        "name" => name,
        "ip" => ip,
        "endpoint" => endpoint,
        "public_key" => pair.public_key,
        "private_key_file" => pair.private_key_file
      }
      save!
    end

    def add_service!(name, host:, port:, protocol: "tcp")
      raise Error, "service already exists: #{name}" if @data["services"].key?(name)
      raise Error, "protocol must be tcp/udp/icmp" unless %w[tcp udp icmp].include?(protocol)
      @data["services"][name] = { "name" => name, "host" => host, "port" => port, "protocol" => protocol }
      save!
    end

    def authorize!(agent, service)
      raise Error, "no agent: #{agent}" unless agent == "manager" || @data["agents"].key?(agent)
      raise Error, "no service: #{service}" unless @data["services"].key?(service)
      entry = { "agent" => agent, "service" => service }
      unless @data["authorizations"].include?(entry)
        @data["authorizations"] << entry
        save!
      end
    end

    def agent(name)
      return manager_record if name == "manager"
      @data["agents"].fetch(name) { raise Error, "no agent: #{name}" }
    end
    def agents = @data["agents"]
    def services = @data["services"]
    def authorizations = @data["authorizations"]

    # Services an identity may reach. A room never changes this; the same
    # pod sees the same services in every room (docs/NETWORK.md §agent).
    def authorized_services(agent_name)
      authorizations.select { |a| a["agent"] == agent_name }
                    .map { |a| services.fetch(a["service"]) }
    end

    private

    def manager_record
      { "name" => "manager", "ip" => @data["network"]["manager_ip"],
        "endpoint" => @data["network"]["manager_endpoint"],
        "public_key" => @data["manager"]["public_key"],
        "private_key_file" => @data["manager"]["private_key_file"] }
    end
  end
end
