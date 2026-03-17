# An agent is a route in the Hub's routing table.
# Not a record of who's alive — a record of where to send messages.
# Created when the Manager returns an address. Destroyed when the route drops.

class Agent < ApplicationRecord
  belongs_to :identity
  belongs_to :room

  validates :instance_name, presence: true, uniqueness: true

  scope :alive, -> { where(state: "alive") }
  scope :resolving, -> { where(state: "resolving") }
  scope :idle, -> { where("last_message_at < ?", 10.minutes.ago) }

  # Deliver a message to this agent's relay.
  def deliver(sender:, content:, attachments: [])
    return unless alive?

    response = Hub::Relay.post_message(
      ip: wg_address,
      sender: sender,
      channel: room.slug,
      content: content,
      attachments: attachments
    )

    touch(:last_message_at) if response
    response
  end

  def alive?
    state == "alive"
  end

  def relay_url
    "http://#{wg_address}:9300"
  end
end
