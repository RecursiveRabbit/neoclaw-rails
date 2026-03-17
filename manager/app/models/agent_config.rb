# Configuration for an identity — what services they get, what model, timeouts.
# Edit in the admin UI. Changes take effect on next spawn.

class AgentConfig < ApplicationRecord
  validates :identity, presence: true, uniqueness: true

  # Resolve services for a specific channel.
  # Base services + channel overrides (additive).
  def services_for(channel)
    base = base_services || []
    overrides = (channel_overrides || {})[channel] || []
    (base + overrides).uniq
  end

  # Does this config include a given service?
  def has_service?(service_name)
    (base_services || []).include?(service_name)
  end
end
