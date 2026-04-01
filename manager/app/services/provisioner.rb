require "base64"

# Auth provisioning — the Manager's hands.
#
# Each service type has a provision_type that determines what happens:
#   "forgejo"  -> create user, add SSH key, grant repo access
#   "ssh_key"  -> append to authorized_keys via host SSH service
#   "valley"   -> token via valley-token-service on the host
#   "vikunja"  -> token via vikunja-token-service on the host
#   "token"    -> generate API token (generic, needs provision_config)
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
      when "valley"
        provision_valley(instance_name: instance_name)
      when "vikunja"
        provision_vikunja(instance_name: instance_name)
      when "matrix"
        provision_matrix(instance_name: instance_name)
      when "archiver"
        provision_archiver(instance_name: instance_name)
      when "none"
        {}
      else
        raise ProvisionError, "unknown provision type: #{service.provision_type}"
      end
    end

    # ----------------------------------------------------------------
    # Channel repo — shared project repo for all agents in a channel.
    # Called after Forgejo user provisioning so the user already exists.
    #
    # Creates channels/<channel> if it doesn't exist, then grants the
    # agent's Forgejo user collaborator access.
    # ----------------------------------------------------------------

    def provision_channel_repo(channel:, instance_name:)
      base_url = Surface.forgejo_url
      token = Surface.forgejo_admin_token
      repo_path = "channels/#{channel}"

      # Check if repo exists
      resp = http.get("#{base_url}/api/v1/repos/#{repo_path}",
        headers: auth_header(token))

      if !resp.respond_to?(:status) || resp.status == 404
        # Create it
        resp = api_post("#{base_url}/api/v1/orgs/channels/repos", {
          name: channel,
          description: "Shared repo for ##{channel}",
          private: true,
          auto_init: true,
          default_branch: "main"
        }, token: token)

        unless resp.respond_to?(:status) && [201, 409].include?(resp.status)
          Rails.logger.warn "channel repo: failed to create #{repo_path}: #{resp.respond_to?(:status) ? resp.status : resp}"
          return nil
        end
        Rails.logger.info "channel repo: created #{repo_path}"
      end

      # Grant collaborator access
      resp = api_put("#{base_url}/api/v1/repos/#{repo_path}/collaborators/#{instance_name}", {
        permission: "write"
      }, token: token)

      if resp.respond_to?(:status) && [204, 200, 422].include?(resp.status)
        Rails.logger.info "channel repo: #{instance_name} granted write on #{repo_path}"
        { channel_repo: repo_path, channel_repo_url: "ssh://git@#{Surface.host_wg_ip}:2222/#{repo_path}.git" }
      else
        Rails.logger.warn "channel repo: failed to grant #{instance_name} on #{repo_path}"
        nil
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
      when "valley"
        teardown_valley(instance_name: instance_name)
      when "vikunja"
        teardown_vikunja(instance_name: instance_name)
      when "matrix"
        teardown_matrix(instance_name: instance_name)
      when "archiver"
        teardown_archiver(instance_name: instance_name)
      when "none"
        # Nothing to revoke
      end
    end

    private

    # ----------------------------------------------------------------
    # Forgejo — stable per-agent user, per-instance context repo
    # ----------------------------------------------------------------

    def provision_forgejo(service, instance_name:, ssh_pubkey:)
      identity = instance_name.split("-").first
      config = AgentConfig.find_by(identity: identity)
      base_url = Surface.forgejo_url
      token = Surface.forgejo_admin_token

      # Per-instance user account
      generated_password = SecureRandom.hex(32)
      resp = api_post("#{base_url}/api/v1/admin/users", {
        username: instance_name,
        email: "#{instance_name}@neoclaw.local",
        password: generated_password,
        must_change_password: false,
        visibility: "private"
      }, token: token)
      unless [201, 422].include?(resp.status)
        raise ProvisionError, "forgejo create user: #{resp.status} #{resp.body}"
      end

      # Ensure current password known for API token minting
      reset = http.with(headers: auth_header(token).merge("content-type" => "application/json"))
        .request("PATCH", "#{base_url}/api/v1/admin/users/#{instance_name}",
          body: JSON.generate({ password: generated_password, must_change_password: false, active: true }))
      unless reset.respond_to?(:status) && [200, 201].include?(reset.status)
        Rails.logger.warn "forgejo: could not reset password for #{instance_name} (#{reset.respond_to?(:status) ? reset.status : reset})"
      end

      # Refresh SSH key for this per-instance account
      existing_keys = http.get("#{base_url}/api/v1/users/#{instance_name}/keys", headers: auth_header(token))
      if existing_keys.respond_to?(:status) && existing_keys.status == 200
        JSON.parse(existing_keys.body).each do |key|
          api_delete("#{base_url}/api/v1/admin/users/#{instance_name}/keys/#{key['id']}", token: token)
        end
      end
      key_resp = api_post("#{base_url}/api/v1/admin/users/#{instance_name}/keys", {
        title: "neoclaw-#{instance_name}",
        key: ssh_pubkey
      }, token: token)
      unless [201, 422].include?(key_resp.status)
        raise ProvisionError, "forgejo add key: #{key_resp.status} #{key_resp.body}"
      end

      # Baseline template repo (authoritative core files)
      baseline_repo = config&.repo || "#{identity}/workspace"
      context_repo = "#{instance_name}/workspace"

      # Ensure per-instance workspace repo exists
      exists = http.get("#{base_url}/api/v1/repos/#{context_repo}", headers: auth_header(token))
      created_context = false
      if !exists.respond_to?(:status) || exists.status == 404
        create = api_post("#{base_url}/api/v1/admin/users/#{instance_name}/repos", {
          name: "workspace",
          private: true,
          auto_init: true,
          default_branch: "main"
        }, token: token)
        unless [201, 409, 422].include?(create.status)
          raise ProvisionError, "forgejo create context repo: #{create.status} #{create.body}"
        end
        created_context = true
      end

      # Seed from <agent>/workspace on first creation
      if created_context
        begin
          tree = http.get("#{base_url}/api/v1/repos/#{baseline_repo}/git/trees/main?recursive=true", headers: auth_header(token))
          if tree.respond_to?(:status) && tree.status == 200
            entries = JSON.parse(tree.body)["tree"] || []
            entries.select { |e| e["type"] == "blob" }.each do |e|
              path = e["path"]
              blob = http.get("#{base_url}/api/v1/repos/#{baseline_repo}/contents/#{path}?ref=main", headers: auth_header(token))
              next unless blob.respond_to?(:status) && blob.status == 200
              data = JSON.parse(blob.body)
              next if data["content"].to_s.empty?
              # Create file in context repo (Forgejo expects POST for create)
              create_resp = api_post("#{base_url}/api/v1/repos/#{context_repo}/contents/#{path}", {
                message: "seed #{path} from #{baseline_repo}",
                content: data["content"].to_s.gsub("\n", ""),
                branch: "main"
              }, token: token)

              # If file already exists, fall back to update with SHA
              if create_resp.respond_to?(:status) && create_resp.status == 422
                existing = http.get("#{base_url}/api/v1/repos/#{context_repo}/contents/#{path}?ref=main", headers: auth_header(token))
                if existing.respond_to?(:status) && existing.status == 200
                  ex = JSON.parse(existing.body)
                  api_put("#{base_url}/api/v1/repos/#{context_repo}/contents/#{path}", {
                    message: "seed/update #{path} from #{baseline_repo}",
                    content: data["content"].to_s.gsub("\n", ""),
                    sha: ex["sha"],
                    branch: "main"
                  }, token: token)
                end
              end
            end
          end
        rescue => e
          Rails.logger.warn "forgejo: context seed failed for #{context_repo}: #{e.message}"
        end
      end

      # API token for this per-instance account
      api_token = nil
      basic = Base64.strict_encode64("#{instance_name}:#{generated_password}")
      token_name = "neoclaw-session-#{Time.now.to_i}-#{SecureRandom.hex(4)}"
      resp = http.post("#{base_url}/api/v1/users/#{instance_name}/tokens",
        json: { name: token_name, scopes: ["all"] },
        headers: { "Authorization" => "Basic #{basic}" })
      if resp.respond_to?(:status) && [200, 201].include?(resp.status)
        data = JSON.parse(resp.body, symbolize_names: true)
        api_token = data[:sha1] || data[:token]
      end

      result = {
        forge_url: base_url,
        forge_user: instance_name,
        workspace_repo: context_repo,
        baseline_repo: baseline_repo
      }
      result[:api_token] = api_token if api_token
      result
    end

    def teardown_forgejo(instance_name:)
      resp = api_delete(
        "#{Surface.forgejo_url}/api/v1/admin/users/#{instance_name}?purge=true",
        token: Surface.forgejo_admin_token
      )
      unless [204, 404].include?(resp.status)
        Rails.logger.warn "forgejo teardown #{instance_name}: #{resp.status}"
      end
    end

    # ----------------------------------------------------------------
    # SSH — manage authorized_keys via shared volume
    #
    # The Manager writes pubkeys to Surface.ssh_keys_dir, which is
    # mounted from /var/lib/neoclaw/ssh-keys/ on the host.
    # sshd reads via AuthorizedKeysCommand.
    # ----------------------------------------------------------------

    def provision_ssh_key(service, instance_name:, ssh_pubkey:)
      identity = instance_name.split("-").first

      # Write to per-instance and per-identity authorized_keys directories.
      # sshd's AuthorizedKeysCommand at /etc/neoclaw/ssh-authorized-keys.sh
      # reads from /var/lib/neoclaw/sftp-keys/<user>/authorized_keys.
      # We keep <instance> for audit/debug and <identity> for login.
      [instance_name, identity].uniq.each do |key_scope|
        keys_dir = File.join(Surface.ssh_keys_dir, key_scope)
        FileUtils.mkdir_p(keys_dir)
        File.write(File.join(keys_dir, "authorized_keys"), "#{ssh_pubkey}\n")
      end

      Rails.logger.info "ssh: authorized #{instance_name} as #{identity}"
      { host: Surface.host_wg_ip, user: identity, port: 22 }
    end

    def teardown_ssh_key(service, instance_name:)
      keys_dir = File.join(Surface.ssh_keys_dir, instance_name)
      FileUtils.rm_rf(keys_dir)
      Rails.logger.info "ssh: deauthorized #{instance_name}"
    end

    # ----------------------------------------------------------------
    # Valley — token via the valley-token-service on the host
    # ----------------------------------------------------------------

    def provision_valley(instance_name:)
      identity = instance_name.split("-").first
      valley_name = identity.capitalize  # Evennia accounts are capitalized

      resp = api_post("#{Surface.valley_token_url}/token/#{valley_name}", {})

      if resp.respond_to?(:status) && resp.status == 200
        data = JSON.parse(resp.body, symbolize_names: true)
        Rails.logger.info "valley: token generated for #{valley_name}"
        { token: data[:token], url: Surface.valley_url }
      else
        Rails.logger.warn "valley: token generation failed for #{valley_name}"
        { url: Surface.valley_url }
      end
    end

    def teardown_valley(instance_name:)
      identity = instance_name.split("-").first
      valley_name = identity.capitalize
      api_delete("#{Surface.valley_token_url}/token/#{valley_name}")
    rescue => e
      Rails.logger.warn "valley: token revocation failed for #{valley_name}: #{e.message}"
    end

    # ----------------------------------------------------------------
    # Vikunja — token via the vikunja-token-service on the host
    #
    # Same pattern as Valley: a host-side token service creates API
    # tokens via Vikunja's temp-password→JWT→PUT /tokens flow.
    # The token service handles the complexity; we just POST.
    # ----------------------------------------------------------------

    def provision_vikunja(instance_name:)
      identity = instance_name.split("-").first

      token_base = Surface.vikunja_token_url.to_s
      if token_base.empty?
        Rails.logger.info "vikunja: no token endpoint configured, WG-only access"
        return { url: Surface.vikunja_url }
      end

      resp = api_post("#{token_base}/token/#{identity}", {})

      if resp.respond_to?(:status) && resp.status == 200
        data = JSON.parse(resp.body, symbolize_names: true)
        Rails.logger.info "vikunja: token generated for #{identity}"
        { token: data[:token], url: Surface.vikunja_url, project_id: data[:project_id] }
      else
        Rails.logger.warn "vikunja: token generation failed for #{identity}"
        { url: Surface.vikunja_url }
      end
    end

    def teardown_vikunja(instance_name:)
      identity = instance_name.split("-").first
      api_delete("#{Surface.vikunja_token_url}/token/#{identity}")
    rescue => e
      Rails.logger.warn "vikunja: token revocation failed for #{identity}: #{e.message}"
    end

    # ----------------------------------------------------------------
    # Matrix — appservice token passthrough for MCP use
    #
    # This does not mint per-user Matrix tokens. It passes the appservice
    # token plus the puppet user_id so Matrix MCP can authenticate.
    # ----------------------------------------------------------------

    def provision_matrix(instance_name:)
      identity = instance_name.split("-").first
      token = Surface.matrix_as_token.to_s
      if token.empty?
        Rails.logger.warn "matrix: MATRIX_AS_TOKEN not configured; skipping token injection for #{identity}"
        return { user_id: "@#{identity}:#{Surface.matrix_server_name}", homeserver: Surface.matrix_homeserver_url }
      end

      {
        token: token,
        user_id: "@#{identity}:#{Surface.matrix_server_name}",
        homeserver: Surface.matrix_homeserver_url
      }
    end

    def teardown_matrix(instance_name:)
      # No per-agent token lifecycle yet (appservice token is shared).
      nil
    end

    # ----------------------------------------------------------------
    # Archiver — semantic retrieval service metadata
    # ----------------------------------------------------------------

    def provision_archiver(instance_name:)
      {
        url: Surface.archiver_url,
        api_key: Surface.archiver_api_key
      }
    end

    def teardown_archiver(instance_name:)
      nil
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
      resp = http.post(url, json: body, headers: headers)
      check_response!(resp, "POST #{url}")
    rescue ProvisionError
      raise
    rescue => e
      Rails.logger.error "Provisioner POST #{url}: #{e.message}"
      raise ProvisionError, "HTTP POST #{url}: #{e.message}"
    end

    def api_put(url, body, token: nil)
      headers = token ? auth_header(token) : {}
      resp = http.put(url, json: body, headers: headers)
      check_response!(resp, "PUT #{url}")
    rescue ProvisionError
      raise
    rescue => e
      Rails.logger.error "Provisioner PUT #{url}: #{e.message}"
      raise ProvisionError, "HTTP PUT #{url}: #{e.message}"
    end

    def api_delete(url, token: nil)
      headers = token ? auth_header(token) : {}
      resp = http.delete(url, headers: headers)
      check_response!(resp, "DELETE #{url}")
    rescue => e
      Rails.logger.error "Provisioner DELETE #{url}: #{e.message}"
      nil
    end

    # HTTPX returns ErrorResponse on connection failure instead of raising.
    # Convert to a real exception so callers don't crash on .status
    def check_response!(resp, context)
      unless resp.respond_to?(:status)
        error_msg = resp.respond_to?(:error) ? resp.error.message : resp.to_s
        raise ProvisionError, "#{context}: #{error_msg}"
      end
      resp
    end

    def http
      @http ||= HTTPX.with(timeout: { operation_timeout: 15 })
    end

    def auth_header(token)
      { "Authorization" => "token #{token}" }
    end
  end
end
