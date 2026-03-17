# Receives Claude Code stream-json output from the Relay
# and broadcasts to any browser watching the live stream.
#
# POST /containers/:instance/output
# Body: { type: "thinking", content: "..." }
#        { type: "tool_use", name: "Read", input: {...} }
#        { type: "text", content: "Here's what I found..." }
#        { type: "result", content: "Done." }

class StreamController < ApplicationController
  skip_forgery_protection

  # POST /containers/:instance/output
  def output
    instance = params[:instance]
    data = request.body.read

    # Broadcast to any connected browsers
    ActionCable.server.broadcast(
      "container_stream_#{instance}",
      data
    )

    # Update container health while we're here
    container = Container.find_by(instance_name: instance)
    if container
      container.touch(:last_health_at)
      if params[:context_usage]
        container.update_column(:context_usage, params[:context_usage].to_f)
      end
    end

    head :ok
  end

  # POST /containers/:instance/health
  def health
    instance = params[:instance]
    container = Container.find_by(instance_name: instance)

    if container
      container.update!(
        last_health_at: Time.current,
        last_message_at: [container.last_message_at, Time.current].compact.max,
        context_usage: params[:context_usage]&.to_f || container.context_usage
      )
    end

    head :ok
  end
end
