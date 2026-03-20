# A room is 1:1 with a Matrix room. Created on demand.
# When the project's done, the room is the archive.

class Room < ApplicationRecord
  has_many :agents, dependent: :destroy
  has_many :identities, through: :agents

  validates :matrix_room_id, presence: true, uniqueness: true

  before_validation :derive_slug, if: -> { slug.blank? && (name.present? || canonical_alias.present?) }

  # Find the living agent for an identity in this room.
  def agent_for(identity)
    agents.alive.find_by(identity: identity)
  end

  private

  # Slug from the room address (#infra), not the display name ("Infrastructure").
  # Addresses are stable identifiers; display names can be anything.
  def derive_slug
    source = canonical_alias.presence || name
    self.slug = source.strip.delete_prefix("#").split(":").first.strip
      .gsub(/[^\w\s-]/, "").downcase
      .gsub(/[\s_]+/, "-").gsub(/\A-|-\z/, "")
    self.slug = "general" if slug.blank?
  end
end
