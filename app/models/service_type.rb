# A registered service type — Forgejo, SSH, Valley, ComfyUI, etc.
# Each one knows its WireGuard interface and how to provision access.
#
# The provision_type field determines what happens at spawn:
#   "forgejo"  → create user, add SSH key, grant repo access
#   "ssh_key"  → append to authorized_keys
#   "token"    → generate API token
#   "none"     → WireGuard peering only (no additional auth)

class ServiceType < ApplicationRecord
  validates :name, presence: true, uniqueness: true

  scope :enabled, -> { where(enabled: true) }
end
