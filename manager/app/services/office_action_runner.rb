# Executes one OfficeAction. The Manager is the only executor: it holds the
# podman socket, talks to the Router, and mints/revokes credentials.
#
# The runner's job is to keep the record honest: `refused` when it must not
# run, `failed` when it ran and broke, `succeeded` only after the post-state
# was observed.

class OfficeActionRunner
  DEADLINE = 120 # seconds; past this the state is `timeout`, not `failed`

  class << self
    def run(action_id)
      action = OfficeAction.find_by(id: action_id)
      return unless action
      return if action.final?

      deadline = Time.current + DEADLINE
      action.start!

      begin
        result = execute(action, deadline)
        action.finish!(state: result[:state], detail: result[:detail])
      rescue => e
        Rails.logger.error "OfficeActionRunner #{action.id}: #{e.class}: #{e.message}"
        action.finish!(state: "failed", detail: "#{e.class}: #{e.message}")
      end
    end

    private

    def execute(action, deadline)
      container = Container.find_by(instance_name: action.handle)

      case action.action
      when "wake"
        wake(action.handle, container)
      when "freeze"
        return refuse("nothing to freeze: no pod for #{action.handle}") unless container
        freeze(container)
      when "spawn"
        spawn_agent(action.handle, container)
      when "rescue"
        return refuse("nothing to rescue: no pod for #{action.handle}") unless container
        rescue_agent(container)
      when "destroy"
        return refuse("nothing to destroy: no pod for #{action.handle}") unless container
        destroy(container)
      else
        refuse("unknown action #{action.action}")
      end
    end

    # Wake: if the pod is alive, nothing to do (say so). Otherwise spawn a
    # fresh pod for this identity — the workspace is restored by spawn's
    # boot_state; credentials are new.
    def wake(handle, container)
      if container&.alive?
        return { state: "succeeded", detail: "#{handle} is already alive; nothing to wake" }
      end
      identity = container&.identity || handle.split("-").first
      channel  = container&.channel
      return refuse("no identity/channel recorded for #{handle}; cannot wake") unless identity && channel

      begin
        result = Spawner.resolve(identity: identity, channel: channel)
        { state: "succeeded",
          detail: "woke #{handle} at #{result[:ip]}#{result[:starting] ? ' (starting)' : ''}" }
      rescue => e
        { state: "failed", detail: "spawn failed: #{e.class}: #{e.message}" }
      end
    end

    def spawn_agent(handle, container)
      identity = container&.identity || handle.split("-").first
      channel  = container&.channel
      return refuse("no identity/channel recorded for #{handle}; cannot spawn") unless identity && channel

      result = Spawner.resolve(identity: identity, channel: channel)
      { state: "succeeded",
        detail: "spawned #{handle} at #{result[:ip]}#{result[:starting] ? ' (starting)' : ''}" }
    rescue => e
      { state: "failed", detail: "spawn failed: #{e.class}: #{e.message}" }
    end

    # Freeze: the agent is asked to stand down, saves its work, and the pod is
    # released (see relay freeze_ready). This is NOT a paused process.
    def freeze(container)
      unless container.alive?
        return refuse("#{container.instance_name} is #{container.state}, not alive; nothing to freeze")
      end
      Lifecycle.freeze!(container)
      fresh = container.reload
      { state: "succeeded",
        detail: "freeze requested for #{container.instance_name}; state is #{fresh.state} " \
                "(stand-down is completed by the agent's freeze_ready)" }
    rescue => e
      { state: "failed", detail: "freeze failed: #{e.class}: #{e.message}" }
    end

    def rescue_agent(container)
      Lifecycle.rescue!(container)
      { state: "succeeded",
        detail: "rescued #{container.instance_name}; workspace preserved, credentials revoked " \
                "(new credentials are minted at the next wake)" }
    rescue => e
      { state: "failed", detail: "rescue failed: #{e.class}: #{e.message}" }
    end

    def destroy(container)
      Lifecycle.teardown!(container)
      { state: "succeeded", detail: "destroyed #{container.instance_name}; credentials revoked" }
    rescue => e
      { state: "failed", detail: "destroy failed: #{e.class}: #{e.message}" }
    end

    def refuse(detail)
      { state: "refused", detail: detail }
    end
  end
end
