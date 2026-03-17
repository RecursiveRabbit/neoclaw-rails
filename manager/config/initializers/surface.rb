# The Manager's surface area. Every file it touches, every connection
# it makes, every credential it holds — declared here.
#
# This is the contract between the Manager container and the host.
# If it's not listed here, the Manager can't reach it.

module Surface
    extend self

    # =================================================================
    # Capacity
    # =================================================================

    def soft_cap
      ENV.fetch("MANAGER_SOFT_CAP", "8").to_i
    end

    def hard_cap
      ENV.fetch("MANAGER_HARD_CAP", "9").to_i
    end

    # =================================================================
    # Mounts — host paths presented to the container
    # =================================================================

    # Podman socket — how we create and destroy containers
    # Mount: -v /run/podman/podman.sock:/run/podman/podman.sock
    def podman_socket
      ENV.fetch("PODMAN_SOCKET", "/run/podman/podman.sock")
    end

    # Spawn secrets directory — we write spawn.json, podman mounts it
    # Mount: -v /var/lib/neoclaw/spawn:/spawn
    def spawn_dir
      ENV.fetch("SPAWN_DIR", "/spawn")
    end

    # Agent container image name
    def agent_image
      ENV.fetch("AGENT_IMAGE", "localhost/neoclaw-agent:latest")
    end

    # =================================================================
    # WireGuard — our connections to the world
    #
    # The Manager sits on every WG interface so it can:
    #   1. Add/remove agent peers (via wg-admin helper on host)
    #   2. Reach services to provision auth
    #   3. Callback to the Hub
    #
    # Each interface is a separate WG peer in our container config.
    # =================================================================

    def wg_private_key_file
      ENV.fetch("WG_PRIVATE_KEY_FILE", "/run/secrets/wg_private_key")
    end

    def manager_wg_address
      ENV.fetch("MANAGER_WG_ADDRESS", "10.0.0.2")
    end

    # WG admin endpoint on the host — a tiny privileged helper that
    # accepts "add-peer" and "remove-peer" commands. The Manager
    # can't run `wg set` itself because it doesn't own the host
    # network namespace. The helper does one thing.
    def wg_admin_url
      ENV.fetch("WG_ADMIN_URL", "http://10.0.0.1:9100")
    end

    # =================================================================
    # Service endpoints — reached over WireGuard
    # =================================================================

    # Forgejo — user creation, SSH key management, repo access
    def forgejo_url
      ENV.fetch("FORGEJO_URL", "http://10.0.0.3:3000")
    end

    def forgejo_admin_token
      ENV.fetch("FORGEJO_ADMIN_TOKEN")
    end

    # Evennia (Valley) — token generation
    def valley_url
      ENV.fetch("VALLEY_URL", "http://10.0.0.4:4002")
    end

    # Vikunja — API token generation
    def vikunja_url
      ENV.fetch("VIKUNJA_URL", "http://10.0.0.5:3456")
    end

    def vikunja_admin_token
      ENV.fetch("VIKUNJA_ADMIN_TOKEN", "")
    end

    # Hub — where we send callbacks
    def hub_url
      ENV.fetch("HUB_URL", "http://10.0.0.1:3000")
    end

    # =================================================================
    # Credentials — injected as secrets
    # =================================================================

    # All injected via environment or secret files.
    # Nothing discovered, nothing inherited.
    #
    # Required secrets:
    #   FORGEJO_ADMIN_TOKEN  — Forgejo admin API token
    #   WG_PRIVATE_KEY_FILE  — Manager's WireGuard private key
    #
    # Optional:
    #   VIKUNJA_ADMIN_TOKEN  — Vikunja admin token (if using Vikunja)

    # =================================================================
    # Container spec — what the Manager pod looks like
    # =================================================================
    #
    # podman run \
    #   --name neoclaw-manager \
    #   --network neoclaw-services \
    #   -v /run/podman/podman.sock:/run/podman/podman.sock \
    #   -v /var/lib/neoclaw/spawn:/spawn \
    #   -v /var/lib/neoclaw/manager-db:/app/db \
    #   --secret wg_private_key,target=/run/secrets/wg_private_key \
    #   --cap-add NET_ADMIN \        # for WireGuard inside the container
    #   -e FORGEJO_ADMIN_TOKEN=... \
    #   -e HUB_URL=http://10.0.0.1:3000 \
    #   -e WG_ADMIN_URL=http://10.0.0.1:9100 \
    #   -p 9200:9200 \               # Manager API (only reachable over WG)
    #   localhost/neoclaw-manager:latest
end
