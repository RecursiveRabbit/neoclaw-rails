# A listener maps an identity to a channel it monitors.
# Unaddressed messages in #general route to Hopper because
# Hopper has a Listener for "general".

class Listener < ApplicationRecord
  belongs_to :identity

  validates :channel_slug, presence: true
  validates :identity_id, uniqueness: { scope: :channel_slug }

  # All identities listening on a given channel slug.
  scope :for_channel, ->(slug) { where(channel_slug: slug) }
end
