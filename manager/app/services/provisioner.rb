# Auth provisioning — the Manager's hands.
#
# Each service type has a provision_type that determines what happens:
#   "forgejo"  -> create user, add SSH key, grant repo access
#   "ssh_key"  -> append to authorized_keys via host SSH service
#   "token"    -> generate API token (service-specific)
#   "none"     -> WireGuard peering only (no additional auth)
#
# Every provision step reaches the service over WireGuard.
# Nothing touches the host directly.

class Provisioner
  class ProvisionError < StandardError; end

  class << self
    def provision(service, instance_name:, ssh_pubkey:)
      case service.provision_type
      when "forgejo"
        provision_forgejo(service, instance_name: instance_name, ssh_pubkey: ssh_pubkey)
      when "ssh_key"
        provision_ssh_key(service, instance_name: instance_name, ssh_pubkey: ssh_pubkey)
      when "token"
        provision_token(service, instance_name: instance_name)
      when "none"
        {}
      else
        raise ProvisionError, "unknown provision type: #{service.provision_type}"
      end
    end

    def teardown(service, instance_name:)
      case service.provision_type
      when "forgejo"
        teardown_forgejo(instance_name: instance_name)
      when "ssh_key"
        teardown_ssh_key(service, instance_name: instance_name)
      when "token"
        teardown_token(service, instance_name: instance_name)
      when "none"
        # Nothing to revoke
      end
    end

    private

    # ----------------------------------------------------------------
    # Forgejo — create ephemeral user, add SSH key, grant repo access
    # ----------------------------------------------------------------

    def provision_forgejo(service, instance_name:, ssh_pubkey:)
      config = AgentConfig.find_by(identity: instance_name.split("-").first)
      base_url = Surface.forgejo_url
      token = Surface.forgejo_admin_token

      # Create ephemeral user for this agent instance
      resp = api_post("#{base_url}/api/v1/admin/users", {
        username: instance_name,
        email: "#{instance_name}@neoclaw.local",
        password: SecureRandom.hex(32),
        must_change_password: false,
        visibility: "private"
      }, token: token)

      # 201 = created, 422 = already exists (idempotent)
      unless [201, 422].include?(resp.status)
        raise ProvisionError, "forgejo create user: #{resp.status} #{resp.body}"
      end

      # Delete any existing SSH keys for this user (stale from prior spawn)
      existing_keys = http.get("#{base_url}/api/v1/users/#{instance_name}/keys",
        headers: auth_header(token))
      if existing_keys.respond_to?(:status) && existing_keys.status == 200
        JSON.parse(existing_keys.body).each do |key|
          api_delete("#{base_url}/api/v1/admin/users/#{instance_name}/keys/#{key['id']}",
            token: token)
        end
      end

      # Add the agent's SSH public key
      resp = api_post("#{base_url}/api/v1/admin/users/#{instance_name}/keys", {
        title: "neoclaw-#{instance_name}",
        key: ssh_pubkey
      }, token: token)

      unless [201, 422].include?(resp.status)
        raise ProvisionError, "forgejo add key: #{resp.status} #{resp.body}"
      end

      # Grant write access to the identity's repo
      if config&.repo
        resp = api_put("#{base_url}/api/v1/repos/#{config.repo}/collaborators/#{instance_name}", {
          permission: "write"
        }, token: token)

        unless [204, 200, 422].include?(resp.status)
          raise ProvisionError, "forgejo grant repo: #{resp.status} #{resp.body}"
        end
      end

      { forge_url: base_url, forge_user: instance_name }
    end

    def teardown_forgejo(instance_name:)
      resp = api_delete(
        "#{Surface.forgejo_url}/api/v1/admin/users/#{instance_name}?purge=true",
        token: Surface.forgejo_admin_token
      )
      # 204 = deleted, 404 = already gone — both fine
      unless [204, 404].include?(resp.status)
        Rails.logger.warn "forgejo teardown #{instance_name}: #{resp.status}"
      end
    end

    # ----------------------------------------------------------------
    # SSH — manage authorized_keys via the host's SSH key service
    #
    # The SSH service type's provision_config should contain:
    #   { "port": 9022 }
    #
    # The key service is a tiny HTTP API on the host (over WireGuard)
    # that manages authorized_keys files per unix user.
    # ----------------------------------------------------------------

    def provision_ssh_key(service, instance_name:, ssh_pubkey:)
      identity = instance_name.split("-").first
      port = service.provision_config&.dig("port") || 9022

      resp = api_post("http://#{service.wg_ip}:#{port}/keys", {
        user: identity,
        key: ssh_pubkey,
        comment: "neoclaw-#{instance_name}"
      })

      unless resp&.status == 200 || resp&.status == 201
        Rails.logger.warn "ssh provision #{instance_name}: #{resp&.status}"
      end

      { ssh_host: service.wg_ip, ssh_user: identity }
    end

    def teardown_ssh_key(service, instance_name:)
      port = service.provision_config&.dig("port") || 9022
      api_delete("http://#{service.wg_ip}:#{port}/keys/neoclaw-#{instance_name}")
    end

    # ----------------------------------------------------------------
    # Token — service-specific API token generation
    #
    # The service type's provision_config should contain:
    #   { "token_endpoint": "/api/v1/tokens", "admin_token": "..." }
    #
    # If no token endpoint is configured, the service relies on
    # WireGuard peering as its only access control.
    # ----------------------------------------------------------------

    def provision_token(service, instance_name:)
      endpoint = service.provision_config&.dig("token_endpoint")
      admin_token = service.provision_config&.dig("admin_token")
      base_url = "http://#{service.wg_ip}"

      if endpoint && admin_token
        resp = api_post("#{base_url}#{endpoint}", {
          name: "neoclaw-#{instance_name}",
          scopes: ["read", "write"]
        }, token: admin_token)

        if [200, 201].include?(resp.status)
          data = JSON.parse(resp.body, symbolize_names: true)
          return { token: data[:token] || data[:access_token], url: base_url }
        else
          raise ProvisionError, "token provision #{service.name}: #{resp.status} #{resp.body}"
        end
      end

      # No token API configured — WG peering is the only access control
      Rails.logger.info "#{service.name}: no token endpoint configured, WG-only access"
      { url: base_url }
    end

    def teardown_token(service, instance_name:)
      endpoint = service.provision_config&.dig("token_endpoint")
      admin_token = service.provision_config&.dig("admin_token")
      return unless endpoint && admin_token

      base_url = "http://#{service.wg_ip}"
      api_delete("#{base_url}#{endpoint}/neoclaw-#{instance_name}", token: admin_token)
    end

    # ----------------------------------------------------------------
    # HTTP helpers — every call checks the response
    # ----------------------------------------------------------------

    def api_post(url, body, token: nil)
      headers = token ? auth_header(token) : {}
      http.post(url, json: body, headers: headers)
    rescue => e
      Rails.logger.error "Provisioner POST #{url}: #{e.message}"
      raise ProvisionError, "HTTP POST #{url}: #{e.message}"
    end

    def api_put(url, body, token: nil)
      headers = token ? auth_header(token) : {}
      http.put(url, json: body, headers: headers)
    rescue => e
      Rails.logger.error "Provisioner PUT #{url}: #{e.message}"
      raise ProvisionError, "HTTP PUT #{url}: #{e.message}"
    end

    def api_delete(url, token: nil)
      headers = token ? auth_header(token) : {}
      http.delete(url, headers: headers)
    rescue => e
      Rails.logger.error "Provisioner DELETE #{url}: #{e.message}"
      nil
    end

    def http
      @http ||= HTTPX.with(timeout: { operation_timeout: 15 })
    end

    def auth_header(token)
      { "Authorization" => "token #{token}" }
    end
  end
end
