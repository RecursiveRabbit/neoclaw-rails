# WireGuard peer management.
#
# The Manager can't run `wg set` directly — it doesn't own the host
# network namespace. Instead it talks to a tiny privileged helper
# (wg-admin) running on the host that accepts add-peer/remove-peer.
#
# The helper is the only privileged thing on the host.
# It does one thing: modify WireGuard interfaces.

class WireGuard
  class << self
    def generate_keypair
      private_key = `wg genkey`.strip
      # Pipe via stdin — keeps the private key out of /proc args
      public_key = IO.popen("wg pubkey", "r+") { |io|
        io.write(private_key)
        io.close_write
        io.read.strip
      }
      { private: private_key, public: public_key }
    end

    def add_peer(interface:, public_key:, allowed_ips:)
      response = http.post("#{Surface.wg_admin_url}/add-peer", json: {
        interface: interface,
        public_key: public_key,
        allowed_ips: allowed_ips
      })

      unless response.status == 200
        raise "wg-admin add-peer failed: #{response.status} #{response.body}"
      end

      true
    end

    def remove_peer(interface:, public_key:)
      response = http.post("#{Surface.wg_admin_url}/remove-peer", json: {
        interface: interface,
        public_key: public_key
      })

      unless response.status == 200
        raise "wg-admin remove-peer failed: #{response.status} #{response.body}"
      end

      true
    rescue => e
      Rails.logger.warn "WG remove-peer: #{e.message}"
    end

    private

    def http
      @http ||= HTTPX.with(timeout: { operation_timeout: 5 })
    end
  end
end
