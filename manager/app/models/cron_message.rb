class CronMessage < ApplicationRecord
  validates :channel, :schedule, :body, presence: true
  validate :valid_cron_schedule

  scope :enabled, -> { where(enabled: true) }
  scope :due, -> { enabled.where("next_fire_at <= ?", Time.current) }

  after_save :compute_next_fire

  def compute_next_fire
    parsed = Fugit::Cron.parse(schedule)
    if parsed
      update_column(:next_fire_at, parsed.next_time.to_t)
    end
  end

  def description
    "##{channel}: #{body.truncate(60)}"
  end

  private

  def valid_cron_schedule
    unless Fugit::Cron.parse(schedule)
      errors.add(:schedule, "is not a valid cron expression")
    end
  end
end
