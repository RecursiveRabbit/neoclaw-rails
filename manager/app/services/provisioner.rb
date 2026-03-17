# Auth provisioning — the Manager's hands.
#
# Each service type has a provision_type that determines what happens:
#   "forgejo"  -> create user, add SSH key, grant repo access
#   "ssh_key"  -> append to authorized_keys (via SSH to host)
#   "token"    -> generate API token
#   "none"     -> WireGuard peering only (no additional auth)
#
# Every provision step reaches the service over WireGuard.
# Nothing touches the host directly.

class Provisioner
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
        raise "unknown provision type: #{service.provision_type}"
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

    def provision_forgejo(service, instance_name:, ssh_pubkey:)
      config = AgentConfig.find_by(identity: instance_name.split("-").first)
      base_url = Surface.forgejo_url
      token = Surface.forgejo_admin_token

      http.post("#{base_url}/api/v1/admin/users", json: {
        username: instance_name,
        email: "#{instance_name}@neoclaw.local",
        password: SecureRandom.hex(32),
        must_change_password: false,
        visibility: "private"
      }, headers: auth_header(token))

      http.post("#{base_url}/api/v1/admin/users/#{instance_name}/keys", json: {
        title: "neoclaw-#{instance_name}",
        key: ssh_pubkey
      }, headers: auth_header(token))

      if config&.repo
        http.put(
          "#{base_url}/api/v1/repos/#{config.repo}/collaborators/#{instance_name}",
          json: { permission: "write" },
          headers: auth_header(token)
        )
      end

      { forge_url: base_url, forge_user: instance_name }
    end

    def teardown_forgejo(instance_name:)
      http.delete(
        "#{Surface.forgejo_url}/api/v1/admin/users/#{instance_name}?purge=true",
        headers: auth_header(Surface.forgejo_admin_token)
      )
    end

    def provision_ssh_key(service, instance_name:, ssh_pubkey:)
      identity = instance_name.split("-").first
      { ssh_host: service.wg_ip, ssh_user: identity }
    end

    def teardown_ssh_key(service, instance_name:)
    end

    def provision_token(service, instance_name:)
      token = SecureRandom.hex(32)
      { token: token, url: "http://#{service.wg_ip}" }
    end

    def teardown_token(service, instance_name:)
    end

    def http
      @http ||= HTTPX.with(timeout: { operation_timeout: 15 })
    end

    def auth_header(token)
      { "Authorization" => "token #{token}" }
    end
  end
end
