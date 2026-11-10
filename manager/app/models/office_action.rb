# One requested lifecycle action on one agent handle, with its honest state.
#
# The office UI polls this; it never guesses. States are a closed set and
# mean exactly what they say:
#   pending   — accepted, not started
#   running   — the executor is in the action
#   succeeded — the action completed and the post-state was observed
#   failed    — it ran and broke; `detail` carries the executor's words
#   refused   — it did not run: unknown handle, gate off, bad action
#   timeout   — it ran past its deadline; outcome unknown, not "failed"
#
# `refused` and `timeout` are deliberately NOT failures: a UI that shows a
# refusal as a crash teaches the operator to ignore crashes.

class OfficeAction < ApplicationRecord
  ACTIONS = %w[wake freeze spawn rescue destroy].freeze
  STATES  = %w[pending running succeeded failed refused timeout].freeze
  FINAL   = %w[succeeded failed refused timeout].freeze

  validates :handle, :action, :state, presence: true
  validates :action, inclusion: { in: ACTIONS }
  validates :state, inclusion: { in: STATES }

  scope :recent_first, -> { order(created_at: :desc) }

  def final?
    FINAL.include?(state)
  end

  def start!
    update!(state: "running", started_at: Time.current)
  end

  def finish!(state:, detail: nil)
    update!(state: state, detail: detail, finished_at: Time.current)
  end

  # Wire shape for GET /api/v1/office/actions/:id — the UI reads `state` and
  # `detail` verbatim.
  def as_api
    {
      action_id: id,
      handle: handle,
      action: action,
      state: state,
      detail: detail,
      reason: reason,
      started_at: started_at&.utc&.iso8601,
      finished_at: finished_at&.utc&.iso8601,
      requested_at: created_at&.utc&.iso8601
    }
  end
end
