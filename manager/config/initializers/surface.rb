# The Manager's surface area. Every file it touches, every connection
# it makes, every credential it holds — declared here.
#
# This is the contract between the Manager container and the host.
# If it's not listed here, the Manager can't reach it.
#
# The Manager runs INSIDE a container. These paths are container paths.
# If you're reading this on the host and wondering why Rails won't start,
# that's the point. Build the image, run the container.

module Surface
    extend self

    # =================================================================
    # Container assertions — verified at boot
    # =================================================================
    #
    # These are not configurable. They are physical facts about the
    # container's filesystem. If they don't exist, you're not in the
    # container, and the Manager has no business running.

    SPAWN_DIR              = "/spawn"
    SSH_KEYS_DIR           = "/ssh-keys"
    PODMAN_SOCKET          = "/run/podman/podman.sock"
    CLAUDE_DIR             = "/run/secrets/claude"

    HOST_SPAWN_DIR         = ENV.fetch("HOST_SPAWN_DIR", "/var/lib/neoclaw/spawn")
    HOST_SSH_KEYS_DIR      = ENV.fetch("HOST_SSH_KEYS_DIR", "/var/lib/neoclaw/sftp-keys")
    HOST_RESCUE_DIR        = ENV.fetch("HOST_RESCUE_DIR", "/var/lib/neoclaw/sessions")
    HOST_CLAUDE_DIR        = ENV.fetch("HOST_CLAUDE_DIR", "/home/hopper/.claude")

    def verify_container!
      errors = []
      errors << "#{SPAWN_DIR} not mounted"           unless Dir.exist?(SPAWN_DIR)
      errors << "#{SSH_KEYS_DIR} not mounted"         unless Dir.exist?(SSH_KEYS_DIR)
      errors << "#{PODMAN_SOCKET} not mounted"        unless File.exist?(PODMAN_SOCKET)

      unless errors.empty?
        $stderr.puts ""
        $stderr.puts "=" * 60
        $stderr.puts "  FATAL: Manager is not running inside its container."
        $stderr.puts ""
        errors.each { |e| $stderr.puts "    - #{e}" }
        $stderr.puts ""
        $stderr.puts "  The Manager requires mounted volumes and secrets"
        $stderr.puts "  that only exist inside the neoclaw-manager pod."
        $stderr.puts "  Build the image, run the container."
        $stderr.puts "=" * 60
        $stderr.puts ""
        exit 1
      end
    end

    # =================================================================
    # Capacity — memory budget, not pod count.
    # Idle agents cost ~15MB each. The budget is the real constraint.
    # =================================================================

    def memory_budget
      Setting.get("resources.memory_budget")
    end

    # =================================================================
    # Mounts — container paths, not configurable
    # =================================================================

    def podman_socket   = PODMAN_SOCKET
    def spawn_dir       = SPAWN_DIR
    def ssh_keys_dir    = SSH_KEYS_DIR
    def host_spawn_dir  = HOST_SPAWN_DIR
    def host_ssh_keys_dir = HOST_SSH_KEYS_DIR
    def host_rescue_dir = HOST_RESCUE_DIR

    def host_claude_dir = HOST_CLAUDE_DIR

    def agent_network
      ENV.fetch("AGENT_NETWORK", "podman")
    end

    def agent_image
      ENV.fetch("AGENT_IMAGE", "localhost/neoclaw-agent:latest")
    end

    # =================================================================
    # WireGuard — the Manager peers with the Router over WG.
    # All services are reached through the Router at the Host's WG IP.
    # =================================================================

    def manager_wg_address
      ENV.fetch("MANAGER_WG_ADDRESS", "10.0.0.3")
    end

    # =================================================================
    # Router — owns all WG peering and firewall rules.
    # The Manager talks to the Router's HTTP API to manage agents.
    # =================================================================

    def router_url
      ENV.fetch("ROUTER_URL", "http://10.0.0.1:8080")
    end

    # Rendered fresh every Manager boot by entrypoint.sh Phase 0, and reused
    # for every Router replacement within that boot. Agents need it to peer
    # with the Router; a stale value means a pod built for a dead Router, so
    # there is no baked fallback that would quietly "work".
    def router_pubkey
      @router_pubkey ||= File.read(File.join(SPAWN_DIR, "runtime", "router.pubkey")).strip
    rescue Errno::ENOENT
      raise "router pubkey missing at #{SPAWN_DIR}/runtime/router.pubkey — Manager boot did not render it"
    end

    # =================================================================
    # Mesh underlay — ONE source
    # =================================================================
    #
    # manager/network.env holds the network name, subnet, gateway, Router
    # underlay address and WG endpoint. Nothing in the Ruby code carries a
    # literal address: the file is the source, and an ENV override is the only
    # way to change a value at run time (the startup assertion in
    # manager/mesh-network.sh checks the live network against the same file).
    #
    # It is parsed, not required: a missing file leaves mesh_value nil so the
    # accessor that needs it fails loudly, rather than silently falling back to
    # a default that is no longer anyone's.

    NETWORK_ENV_PATH = File.expand_path("../../network.env", __dir__)

    def network_env
        @network_env ||= begin
            values = {}
            if File.exist?(NETWORK_ENV_PATH)
                File.readlines(NETWORK_ENV_PATH).each do |line|
                    line = line.strip
                    next if line.empty? || line.start_with?("#")
                    key, value = line.split("=", 2)
                    next if key.nil? || value.nil?

                    values[key.strip] = value.strip.delete_prefix('"').delete_suffix('"')
                end
            end
            values
        end
    end

    def mesh_value(key)
        ENV[key] || network_env[key]
    end

    def mesh_network = mesh_value("NC_MESH_NETWORK")
    def mesh_subnet  = mesh_value("NC_MESH_SUBNET")
    def mesh_gateway = mesh_value("NC_MESH_GATEWAY")

    # Boot id of the current Manager boot (matches the Router key in use).
    def boot_id
      JSON.parse(File.read(File.join(SPAWN_DIR, "runtime", "boot.json")))['boot_id']
    rescue StandardError
      "unknown"
    end

    # Router's underlay IP + WG port. Baked into agent spawn.json.
    def router_endpoint
        mesh_value("ROUTER_ENDPOINT") ||
            raise("no ROUTER_ENDPOINT in manager/network.env — the mesh has no endpoint")
    end

    # =================================================================
    # Hub — Matrix bridge for agents. Has its own WG identity.
    # =================================================================

    HUB_WG_ADDRESS = "10.0.0.4"
    def hub_wg_address = HUB_WG_ADDRESS

    # =================================================================
    # Service endpoints — reached over WireGuard via the Router.
    # All services are on the Host at 10.0.0.2.
    # =================================================================

    HOST_WG_IP = "10.0.0.2"

    def host_wg_ip
      ENV.fetch("HOST_WG_IP", HOST_WG_IP)
    end

    def forgejo_url
      ENV.fetch("FORGEJO_URL", "http://#{host_wg_ip}:3000")
    end

    def forgejo_admin_token
      ENV.fetch("FORGEJO_ADMIN_TOKEN")
    end

    def valley_url
      ENV.fetch("VALLEY_URL", "http://#{host_wg_ip}:8888")
    end

    def valley_token_url
      ENV.fetch("VALLEY_TOKEN_URL", "http://#{host_wg_ip}:8889")
    end

    def vikunja_url
      ENV.fetch("VIKUNJA_URL", "http://#{host_wg_ip}:3456")
    end

    def vikunja_token_url
      ENV.fetch("VIKUNJA_TOKEN_URL", "http://#{host_wg_ip}:8890")
    end

    def vikunja_admin_token
      ENV.fetch("VIKUNJA_ADMIN_TOKEN", "")
    end

    def hub_url
      ENV.fetch("HUB_URL", "http://#{hub_wg_address}:3100")
    end

    # =================================================================
    # Infrastructure — Router and Hub managed by the Manager.
    # Keys and configs are baked into images at build time.
    # Only image names and bridge IP needed at runtime.
    # =================================================================

    def router_image
      ENV.fetch("ROUTER_IMAGE", "localhost/neoclaw-router:latest")
    end

    def router_bridge_ip
        mesh_value("ROUTER_BRIDGE_IP") ||
            raise("no ROUTER_BRIDGE_IP in manager/network.env — the Router has no address")
    end

    def hub_image
      ENV.fetch("HUB_IMAGE", "localhost/neoclaw-hub:latest")
    end

    # Infrastructure container names — used for cleanup and health checks.
    INFRA_CONTAINERS = %w[neoclaw-manager wg-router neoclaw-hub].freeze
    def infra_containers = INFRA_CONTAINERS
end

# =================================================================
# Boot — verify we're in the container, or die
# =================================================================

unless ENV["RAILS_ENV"] == "test" || defined?(Rake)
  Surface.verify_container!
end
