# Streams Claude Code output to the browser.
#
# The relay POSTs stream-json lines to /containers/:instance/output.
# The RelayController broadcasts them here.
# The browser subscribes and renders a live terminal view.
#
# stream-json types we handle:
#   { type: "assistant", message: { content: [...] } }
#   { type: "tool_use", name: "Read", input: {...} }
#   { type: "tool_result", content: "..." }
#   { type: "result", duration_ms: 1234 }

class ContainerStreamChannel < ApplicationCable::Channel
  def subscribed
    instance = params[:instance]
    stream_from "container_stream_#{instance}"

    # Send buffered history so the viewer can scroll back
    StreamBuffer.history(instance).each do |entry|
      transmit(entry[:data])
    end
  end

  # Browser sends { action: "stop" } over the WebSocket.
  # No CSRF, no HTTP round-trip — uses the connection that's already open.
  def receive(data)
    case data["action"]
    when "stop"
      instance = params[:instance]
      container = Container.find_by(instance_name: instance)
      return unless container

      HTTPX.post("http://#{container.wg_address}:9300/signal", json: { signal: "stop" })
      transmit({ type: "system", message: "Stop signal sent." })
    end
  end

  def unsubscribed
    stop_all_streams
  end
end
