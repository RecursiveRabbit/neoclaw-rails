# Relay → Manager endpoints.
# Containers report health, stream output, and signal lifecycle events.

class RelayController < ApplicationController
  skip_forgery_protection

  # POST /containers/:instance/health
  def health
    container = find_container
    return unless container

    container.update!(
      last_health_at: Time.current,
      context_usage: params[:context_usage]&.to_f || container.context_usage,
      last_message_at: params[:last_message_at] ? Time.parse(params[:last_message_at]) : container.last_message_at
    )

    # Sunset warning if context is getting full
    if container.context_usage > 0.85
      HubClient.callback(event: "sunset_warning",
        instance: container.instance_name,
        context_usage: container.context_usage)
    end

    head :ok
  end

  # POST /containers/:instance/output
  # Claude Code stream-json lines arrive here from the relay.
  # Store in the output buffer and broadcast to any live viewers.
  def output
    container = find_container
    return unless container

    data = request.body.read

    # Store in the output buffer — persists whether anyone is watching or not
    StreamBuffer.append(container.instance_name, data)

    # Broadcast to any live ActionCable subscribers
    ActionCable.server.broadcast(
      "container_stream_#{container.instance_name}",
      data
    )

    container.update!(last_health_at: Time.current)

    head :ok
  end

  # POST /containers/:instance/ready
  # Agent has cloned, read identity, and is ready for messages.
  def ready
    container = find_container
    return unless container

    container.update!(state: "alive")
    AuditLog.record("READY",
      instance_name: container.instance_name,
      identity: container.identity,
      detail: "Agent ready")

    # Tell the Hub — it can flip the agent from resolving to alive
    HubClient.callback(event: "ready", instance: container.instance_name)

    head :ok
  end

  # POST /containers/:instance/freeze_ready
  # Agent has pushed work and is ready to be torn down.
  def freeze_ready
    container = find_container
    return unless container

    # Determine ended_reason from the audit trail — SUNSET vs FREEZE
    last_event = AuditLog.where(instance_name: container.instance_name)
      .where(event: %w[FREEZE SUNSET]).order(created_at: :desc).first
    ended_reason = last_event&.event == "SUNSET" ? "context_limit" : "idle"

    # Process session metadata before teardown (pod still alive)
    SessionProcessor.process(container, ended_reason: ended_reason)

    Lifecycle.teardown!(container)

    head :ok
  end

  private

  def find_container
    container = Container.find_by(instance_name: params[:instance])
    unless container
      head :not_found
      return nil
    end
    container
  end
end
