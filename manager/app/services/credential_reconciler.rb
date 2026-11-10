# Boot-time reconciliation of the credential ledger.
#
# Runs after the Orchestrator has adopted (re-spawned) every pod it can.
# Any checkout still open whose launch belongs to a PREVIOUS boot and whose
# pod is not running now has no owner: its credentials are revoked, and the
# ledger says so.
#
# Deliberately conservative in the other direction: rows minted by the
# CURRENT boot are left alone (a spawn may still be in flight), and rows
# whose pod is alive are left alone even if the boot id is old.

class CredentialReconciler
  class << self
    # Returns a summary hash; never raises on per-row failures.
    def reconcile!
      live = live_instance_names
      counts = { scanned: 0, revoked: 0, failed: 0, unrevocable: 0, kept_live: 0 }

      CredentialCheckout.open.find_each do |row|
        counts[:scanned] += 1

        if row.launch_ref.start_with?("#{Surface.boot_id}:")
          next # current boot: still owned
        end
        if live.include?(row.instance_name)
          counts[:kept_live] += 1
          next
        end

        case CredentialRevoker.revoke(row, reason: "boot-reconcile")
        when :revoked     then counts[:revoked] += 1
        when :unrevocable then counts[:unrevocable] += 1
        else                   counts[:failed] += 1
        end
      end

      if counts[:revoked] > 0 || counts[:failed] > 0 || counts[:unrevocable] > 0
        AuditLog.record("CREDENTIAL_RECONCILE",
          detail: "boot=#{Surface.boot_id[0, 8]} scanned=#{counts[:scanned]} " \
                  "revoked=#{counts[:revoked]} failed=#{counts[:failed]} " \
                  "unrevocable=#{counts[:unrevocable]} kept_live=#{counts[:kept_live]}")
      end

      counts
    end

    # Seam: tests stub this; production reads the real podman inventory.
    def podman_inventory
      Podman.inventory.map { |p| p[:name] }.compact
    end

    private

    def live_instance_names
      podman_inventory
    rescue StandardError => e
      Rails.logger.warn "CredentialReconciler: podman inventory failed (#{e.class}) — treating all as not live"
      []
    end
  end
end
