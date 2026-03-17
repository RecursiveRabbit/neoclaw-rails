# Room-level configuration — services and defaults that apply to
# every agent spawned in this room.
#
# #art gives everyone comfyui. #security gives everyone... nothing extra,
# but you could. The room is a capability grant.

class RoomConfig < ApplicationRecord
  has_many :agent_room_configs, primary_key: :channel, foreign_key: :channel

  validates :channel, presence: true, uniqueness: true

  def has_service?(service_name)
    (extra_services || []).include?(service_name)
  end
end
