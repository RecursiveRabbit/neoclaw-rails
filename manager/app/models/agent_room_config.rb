# A specific agent+room pairing — overrides that apply only when
# this identity is spawned in this room.
#
# Margaux in #art gets comfyui on top of her base services.
# Silas in #security gets... whatever you configure here.

class AgentRoomConfig < ApplicationRecord
  belongs_to :agent_config

  validates :channel, presence: true
  validates :agent_config_id, uniqueness: { scope: :channel }

  def has_service?(service_name)
    (extra_services || []).include?(service_name)
  end
end
