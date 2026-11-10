# Revocation driver for the credential ledger.
#
# Each open checkout carries an opaque revoke_handle. This class knows how to
# turn a handle into an actual revocation call, and it refuses to mark a row
# revoked unless the revocation really happened. A handle with no endpoint in
# this system is `unrevocable: true` at issue time and stays open on purpose —
# visible in the ledger instead of silently counted as clean.

class CredentialRevoker
  class << self
    # Revoke every open checkout for an instance. Called on teardown, on
    # relaunch (spawn/rescue), and on orphan reconciliation.
    # Returns { revoked: n, failed: n, unrevocable: n }.
    def revoke_all(instance_name, reason:)
      counts = { revoked: 0, failed: 0, unrevocable: 0 }
      CredentialCheckout.open_for(instance_name).find_each do |row|
        result = revoke(row, reason: reason)
        counts[result] += 1
      end
      counts
    end

    # Revoke a single row. Returns :revoked, :failed, or :unrevocable.
    def revoke(row, reason:)
      return :unrevocable if row.unrevocable?

      case row.revoke_handle
      when /\Aforgejo:user:(.+)\z/
        revoke_forgejo_user(Regexp.last_match(1), row, reason)
      when /\Afile:(.+)\z/
        revoke_file(Regexp.last_match(1), row, reason)
      when /\Avalley:token:(.+)\z/
        revoke_http("valley", row, reason, "/token/#{Regexp.last_match(1)}")
      when /\Avikunja:token:(.+)\z/
        revoke_http("vikunja", row, reason, "/token/#{Regexp.last_match(1)}")
      else
        # Unknown handle kind: do not pretend. Leave open, record why.
        Rails.logger.warn "credential ledger: no revoker for #{row.revoke_handle}"
        row.update!(note: [row.note, "no revoker for handle kind (boot #{Surface.boot_id})"].compact.join("; "))
        :failed
      end
    end

    # HTTP seam — tests set http_override instead of the network.
    attr_writer :http_override

    def http
      @http_override || (@http ||= HTTPX)
    end

    private

    def revoke_forgejo_user(name, row, reason)
      resp = http.delete("#{Surface.forgejo_url}/api/v1/admin/users/#{name}?purge=true",
                          headers: { "Authorization" => "token #{Surface.forgejo_admin_token}" })
      # 204 deleted / 404 already gone = revoked. Anything else = failed.
      if [204, 404].include?(resp.status)
        row.revoke!(reason: reason)
        :revoked
      else
        row.update!(note: [row.note, "forgejo revoke HTTP #{resp.status}"].compact.join("; "))
        :failed
      end
    rescue StandardError => e
      row.update!(note: [row.note, "forgejo revoke error: #{e.class}"].compact.join("; "))
      Rails.logger.warn "credential ledger: forgejo revoke failed for #{name}: #{e.message}"
      :failed
    end

    def revoke_file(path, row, reason)
      FileUtils.rm_rf(path)
      if File.exist?(path)
        row.update!(note: [row.note, "file still present after rm"].compact.join("; "))
        :failed
      else
        row.revoke!(reason: reason)
        :revoked
      end
    rescue StandardError => e
      row.update!(note: [row.note, "file revoke error: #{e.class}"].compact.join("; "))
      :failed
    end

    def revoke_http(service, row, reason, path)
      url = case service
            when "valley"  then Surface.valley_token_url
            when "vikunja" then Surface.vikunja_token_url
            end
      resp = http.delete("#{url}#{path}")
      if resp.status.to_i.between?(200, 299) || resp.status == 404
        row.revoke!(reason: reason)
        :revoked
      else
        row.update!(note: [row.note, "#{service} revoke HTTP #{resp.status}"].compact.join("; "))
        :failed
      end
    rescue StandardError => e
      row.update!(note: [row.note, "#{service} revoke error: #{e.class}"].compact.join("; "))
      :failed
    end
  end
end
