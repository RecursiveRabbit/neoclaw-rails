# A registered service type — Forgejo, SSH, Valley, ComfyUI, etc.

class ServiceType < ApplicationRecord
  validates :name, presence: true, uniqueness: true

  scope :enabled, -> { where(enabled: true) }

  def peer_config
    {
      public_key: wg_public_key,
      endpoint: wg_endpoint,
      allowed_ips: "#{wg_ip}/32"
    }
  end
end
