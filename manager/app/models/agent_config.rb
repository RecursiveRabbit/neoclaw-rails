# Configuration for an identity — what services they get, what model, timeouts.
# Edit in the admin UI. Changes take effect on next spawn.

class AgentConfig < ApplicationRecord
  has_many :agent_room_configs, dependent: :destroy

  validates :identity, presence: true, uniqueness: true

  # Resolve services for a specific channel.
  # Three layers, all additive:
  #   1. Agent base services (always)
  #   2. Room services (everyone in this room gets these)
  #   3. Agent+Room override (this identity in this room gets these)
  def services_for(channel)
    base = base_services || []
    room = RoomConfig.find_by(channel: channel)
    room_extras = room&.extra_services || []
    agent_room = agent_room_configs.find_by(channel: channel)
    agent_room_extras = agent_room&.extra_services || []
    (base + room_extras + agent_room_extras).uniq
  end

  # Resolve model for a specific channel.
  # Agent+Room override > Room default > Agent config
  def model_for(channel)
    agent_room = agent_room_configs.find_by(channel: channel)
    return agent_room.model_override if agent_room&.model_override.present?
    room = RoomConfig.find_by(channel: channel)
    return room.model_default if room&.model_default.present?
    model
  end

  def has_service?(service_name)
    (base_services || []).include?(service_name)
  end
end
