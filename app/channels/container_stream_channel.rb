# ActionCable channel for live Claude Code output streaming.
#
# The Relay pipes Claude's stream-json output to the Manager via
# POST /containers/:id/output. The Manager broadcasts each chunk
# to any browser subscribed to this channel.
#
# Client subscribes: { channel: "ContainerStreamChannel", instance: "silas-general" }
# Server broadcasts: { type: "thinking", content: "..." }
#                    { type: "tool_use", name: "Read", input: {...} }
#                    { type: "text", content: "..." }

class ContainerStreamChannel < ApplicationCable::Channel
  def subscribed
    instance = params[:instance]
    stream_from "container_stream_#{instance}"
  end

  def unsubscribed
    stop_all_streams
  end
end
