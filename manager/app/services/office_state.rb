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
        backend: inventory_error? ? "unavailable" : "podman",  # dova's enum
        inventory_error: inventory_error,
        observed_at: Time.current.utc.iso8601,
        boot_id: Surface.boot_id,
        states: STATES,
        counts: agents.group_by { |a| a[:state] }.transform_values(&:size)
      }
    end

    # The office view fails UNKNOWN, never dead: an unreadable inventory says
    # nothing about a handle, and "dead" is a claim about the pod. (Credentials
    # fail the other way — the reconciler refuses to treat an unreadable
    # inventory as "no live pods" because revoking on a guess destroys keys.)
    def inventory_error
      @inventory_error
    end

    def inventory_error?
      !@inventory_error.nil?
    end

    # Seam: tests set a callable inventory_source (which may raise).
    attr_writer :inventory_source

    def inventory
      @inventory_error = nil
      source = @inventory_source || -> { Podman.inventory }
      source.call
    rescue StandardError => e
      @inventory_error = "#{e.class}: #{e.message}"
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

      if pod.nil? && inventory_error?
        # We cannot see podman at all. Saying "dead" here would turn an
        # unreadable inventory into an accusation about the agent.
        ["unknown", { podman: "error", record: record_state || "absent",
                      note: "podman inventory unreadable (#{@inventory_error}); state unknown" }]
      elsif pod.nil?
        # No pod. Three honest outcomes, not one:
        #   frozen — the agent stood down on purpose and its work was kept
        #   dead   — the pod is gone with no record of a graceful ending
        #   unknown— we have no opinion at all (no pod, no record)
        if record_state.nil?
          ["unknown", { podman: "absent", record: "absent", note: "no pod and no record" }]
        else
          ending = last_ending(container.instance_name)
          if ending
            reason, detail = ending
            ["frozen", { podman: "absent", record: record_state,
                         ended_reason: reason,
                         note: "stood down (#{reason}); work preserved" }]
          else
            ["dead", { podman: "absent", record: record_state,
                       ended_reason: nil,
                       note: "pod gone with no graceful stand-down on record" }]
          end
        end
      elsif paused
        ["frozen", { podman: "paused", record: record_state }]
      elsif alive_in_podman
        if record_state == "freezing"
          # Stand-down in flight: the pod is running but the agent is closing
          # out. Neither alive nor frozen yet; say so instead of picking.
          ["unknown", { podman: "running", record: record_state,
                         note: "stand-down in progress (record freezing)" }]
        elsif %w[alive starting].include?(record_state)
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

    # Did this instance stand down on purpose? The discriminator is the
    # ended_reason the session processor wrote: idle/context_limit are a
    # graceful stand-down (work preserved); crash is not; no row at all is not.
    def last_ending(instance_name)
      row = AuditLog.where(instance_name: instance_name, event: "SESSION_PROCESSED")
                    .order(created_at: :desc).first
      return nil unless row&.detail

      reason = JSON.parse(row.detail)["ended_reason"] rescue nil
      return nil unless %w[idle context_limit].include?(reason)

      [reason, row.detail]
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
