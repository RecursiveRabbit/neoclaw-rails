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

  def unsubscribed
    stop_all_streams
  end
end
