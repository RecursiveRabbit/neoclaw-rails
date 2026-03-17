# Append-only audit trail. Every spawn, freeze, crash, provision.

class AuditLog < ApplicationRecord
  validates :event, presence: true

  scope :recent, -> { order(created_at: :desc).limit(100) }

  def self.record(event, instance_name: nil, identity: nil, detail: nil)
    create!(
      event: event,
      instance_name: instance_name,
      identity: identity,
      detail: detail,
      created_at: Time.current
    )
  end
end
