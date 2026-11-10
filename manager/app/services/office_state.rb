# GET /api/v1/office/state — one read for the office UI.
#
# Rule: podman is ground truth for existence; the Container record is the
# Manager's own bookkeeping; neither is allowed to win silently. Where they
# disagree the row says `unknown` and names which side said what (provenance).
#
# `state` is a CLOSED, lowercase set:
#   alive | frozen | starting | dead | unknown
# Clients may still be tolerant, but they will never see anything else from
# this serializer.

class OfficeState
  STATES = %w[alive frozen starting dead unknown].freeze

  class << self
    def as_api
      pods = inventory
      by_name = pods.each_with_object({}) { |p, h| h[p[:name]] = p }

      names = (by_name.keys + Container.pluck(:instance_name)).uniq.sort
      agents = names.map { |name| agent_row(name, by_name[name]) }

      {
        agents: agents,
        backend: "podman",
        observed_at: Time.current.utc.iso8601,
        boot_id: Surface.boot_id,
        states: STATES,
        counts: agents.group_by { |a| a[:state] }.transform_values(&:size)
      }
    end

    # Seam: tests set inventory_override.
    attr_writer :inventory_override

    def inventory
      return @inventory_override if @inventory_override

      Podman.inventory
    rescue StandardError => e
      Rails.logger.warn "OfficeState: podman inventory failed (#{e.class}): #{e.message}"
      []
    end

    private

    def agent_row(name, pod)
      container = Container.find_by(instance_name: name)
      pod_state = pod && (pod[:state] || pod[:status])

      state, provenance = resolve_state(pod, pod_state, container)

      {
        handle: name,
        state: state,
        wg_address: pod&.dig(:ip) || container&.wg_address,
        last_activity_at: container&.last_message_at&.utc&.iso8601,
        identity: container&.identity,
        context_usage: container&.context_usage,
        live_credentials: live_credentials(name),
        provenance: provenance
      }
    end

    def resolve_state(pod, pod_state, container)
      record_state = container&.state
      pod_running  = pod_state.to_s.downcase
      alive_in_podman = %w[running up].include?(pod_running)
      paused = pod_running == "paused"

      if pod.nil?
        # No pod. Dead if we believed it was alive or starting; unknown when
        # there is no opinion at all (record missing too).
        if record_state.nil?
          ["unknown", { podman: "absent", record: "absent", note: "no pod and no record" }]
        else
          ["dead", { podman: "absent", record: record_state, note: "record without pod" }]
        end
      elsif paused
        ["frozen", { podman: "paused", record: record_state }]
      elsif alive_in_podman
        if %w[alive starting].include?(record_state)
          [record_state == "starting" ? "starting" : "alive",
           { podman: "running", record: record_state }]
        else
          # podman says running, our bookkeeping does not. Show the fact,
          # name the disagreement, do not pick a winner.
          ["unknown", { podman: "running", record: record_state || "absent",
                        note: "podman running but record disagrees" }]
        end
      else
        ["dead", { podman: pod_running.empty? ? "unknown" : pod_running,
                   record: record_state }]
      end
    end

    def live_credentials(name)
      CredentialCheckout.open_for(name).map do |row|
        {
          id: row.id,
          scope: row.scope,
          issued_at: row.issued_at&.utc&.iso8601,
          expires_at: row.expires_at&.utc&.iso8601,
          unrevocable: row.unrevocable
        }
      end
    end
  end
end
