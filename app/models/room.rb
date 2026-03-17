# A room is 1:1 with a Matrix room. Created on demand.
# When the project's done, the room is the archive.

class Room < ApplicationRecord
  has_many :agents, dependent: :destroy
  has_many :identities, through: :agents

  validates :matrix_room_id, presence: true, uniqueness: true

  before_validation :derive_slug, if: -> { name.present? && slug.blank? }

  # Find the living agent for an identity in this room.
  def agent_for(identity)
    agents.alive.find_by(identity: identity)
  end

  private

  def derive_slug
    self.slug = name.strip.delete_prefix("#").strip
      .gsub(/[^\w\s-]/, "").downcase
      .gsub(/[\s_]+/, "-").gsub(/\A-|-\z/, "")
    self.slug = "general" if slug.blank?
  end
end
