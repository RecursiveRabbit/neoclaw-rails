# An identity is who you are across all instances.
# Silas, Margaux, Kael, Wren, Ember, Parallax, Hopper...
#
# Identities persist forever. Agents come and go.

class Identity < ApplicationRecord
  has_many :agents, dependent: :destroy
  has_many :rooms, through: :agents
  has_many :listeners, dependent: :destroy

  validates :name, presence: true, uniqueness: true

  # Does this identity listen on a channel? Unaddressed messages
  # in a listened channel are routed to the identity implicitly.
  def listens_on?(channel_slug)
    listeners.exists?(channel_slug: channel_slug)
  end

  # The instance name for a given channel.
  # Singletons always use the same name regardless of channel.
  def instance_name_for(channel)
    singleton? ? name : "#{name}-#{channel}"
  end
end
