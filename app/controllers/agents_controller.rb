# Relay → Hub endpoints.
# Agent containers send responses back through here.
#
# POST /agent/message  — agent has a response to puppet into Matrix
# POST /agent/event    — agent lifecycle events (typing, presence)
# POST /diagnostic     — agent error/debug info

class AgentsController < ApplicationController
  skip_forgery_protection

  # POST /agent/message
  # Relay sends: { instance: "margaux-security", content: "Here's what I found..." }
  def message
    instance = params[:instance]
    content  = params[:content]

    agent = Agent.alive.find_by(instance_name: instance)
    unless agent
      render json: { error: "unknown agent" }, status: :not_found
      return
    end

    Hub::Matrix.puppet(
      agent.identity.name,
      agent.room.matrix_room_id,
      content
    )

    agent.touch(:last_message_at)
    render json: { ok: true }
  end

  # POST /agent/event
  # Relay sends: { instance: "margaux-security", event: "typing" }
  def event
    instance   = params[:instance]
    event_type = params[:event]

    agent = Agent.alive.find_by(instance_name: instance)
    unless agent
      render json: { error: "unknown agent" }, status: :not_found
      return
    end

    case event_type
    when "typing"
      Hub::Matrix.set_typing(agent.identity.name, agent.room.matrix_room_id, true)
    when "done_typing"
      Hub::Matrix.set_typing(agent.identity.name, agent.room.matrix_room_id, false)
    when "online"
      Hub::Matrix.set_presence(agent.identity.name, "online")
    when "idle"
      Hub::Matrix.set_presence(agent.identity.name, "unavailable")
    end

    render json: { ok: true }
  end

  # POST /diagnostic
  # Agent debug/error info — log it, don't route it.
  def diagnostic
    instance = params[:instance]
    level    = params[:level] || "info"
    message  = params[:message]

    Rails.logger.tagged("agent:#{instance}") do
      case level
      when "error" then Rails.logger.error(message)
      when "warn"  then Rails.logger.warn(message)
      else Rails.logger.info(message)
      end
    end

    head :ok
  end
end
