# A running (or recently running) agent container.
# This is the Manager's view of reality. Podman is ground truth.

class Container < ApplicationRecord
  validates :instance_name, presence: true, uniqueness: true

  scope :alive, -> { where(state: "alive") }
  scope :starting, -> { where(state: "starting") }
  scope :freezing, -> { where(state: "freezing") }

  scope :idle, ->(threshold = 10.minutes) {
    alive.where("last_message_at < ?", threshold.ago)
  }

  def alive?
    state == "alive"
  end

  def uptime
    return 0 unless created_at
    Time.current - created_at
  end

  def context_percent
    (context_usage * 100).round(1)
  end
end
