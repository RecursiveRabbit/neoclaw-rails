# The credential ledger.
#
# One row per credential issued to an agent launch. It records WHAT was
# issued, to WHICH launch, and how to revoke it — never the credential
# itself. The row is the only durable trace of a secret's existence; the
# secret lives in the pod's spawn.json and dies with it.
#
# Invariant (enforced by test, not by hope): no column of this table ever
# holds a secret value. `revoke_handle` is a locator, not a token.

class CredentialCheckout < ApplicationRecord
  SCOPES = %w[
    forgejo-user forgejo-token ssh-key valley-token vikunja-token generic-token
  ].freeze

  validates :id, presence: true
  validates :scope, inclusion: { in: SCOPES }
  validates :instance_name, :launch_ref, :revoke_handle, :issued_at, presence: true

  scope :open, -> { where(revoked_at: nil) }
  scope :revoked, -> { where.not(revoked_at: nil) }

  def self.issue!(scope:, instance_name:, revoke_handle:, launch_ref: nil,
                  expires_at: nil, unrevocable: false, note: nil)
    create!(
      id: SecureRandom.uuid,
      scope: scope,
      instance_name: instance_name,
      launch_ref: launch_ref || current_launch_ref(instance_name),
      revoke_handle: revoke_handle,
      unrevocable: unrevocable,
      issued_at: Time.current,
      expires_at: expires_at,
      note: note
    )
  end

  # "<boot_id>:<instance>" — the Manager boot that minted it.
  def self.current_launch_ref(instance_name)
    "#{Surface.boot_id}:#{instance_name}"
  rescue StandardError
    "unknown:#{instance_name}"
  end

  def self.open_for(instance_name)
    open.where(instance_name: instance_name)
  end

  def revoke!(reason:, at: Time.current)
    update!(revoked_at: at, revoked_reason: reason)
  end

  # Rows that can never be closed by this system, stated as such.
  def unrevocable?
    unrevocable
  end
end
