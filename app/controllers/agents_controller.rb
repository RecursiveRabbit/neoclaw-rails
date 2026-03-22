# Relay → Hub endpoints.
# Agent containers send responses back through here.
#
# POST /agent/message  — agent has a response to puppet into Matrix
# POST /agent/event    — agent lifecycle events (typing, presence)
# POST /diagnostic     — agent error/debug info

class AgentsController < ApplicationController
  # POST /agent/message
  # Relay sends: { instance: "margaux-security", content: "...", identity: "margaux", channel: "security" }
  def message
    instance = params[:instance]
    content  = params[:content]

    route = resolve_route(instance)
    unless route
      render json: { error: "unknown agent" }, status: :not_found
      return
    end

    msgtype = params[:msgtype] || "m.text"
    Hub::Matrix.puppet(route[:identity], route[:room_id], content, msgtype: msgtype)
    render json: { ok: true }
  end

  # POST /agent/event
  # Relay sends: { instance: "margaux-security", event: "typing", identity: "margaux", channel: "security" }
  def event
    instance   = params[:instance]
    event_type = params[:event]

    route = resolve_route(instance)
    unless route
      render json: { error: "unknown agent" }, status: :not_found
      return
    end

    case event_type
    when "typing"
      Hub::Matrix.set_typing(route[:identity], route[:room_id], true)
    when "done_typing"
      Hub::Matrix.set_typing(route[:identity], route[:room_id], false)
    when "online"
      Hub::Matrix.set_presence(route[:identity], "online")
    when "idle"
      Hub::Matrix.set_presence(route[:identity], "unavailable")
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

  private

  # Find the route from cache, or rebuild it from the relay's identity/channel.
  # The relay always sends identity and channel so we can recover after Hub restart.
  def resolve_route(instance)
    route = Hub::RouteCache.get(instance)
    return route if route

    # Route cache miss — relay sent identity + channel, reconstruct.
    identity = params[:identity]
    channel  = params[:channel]
    return nil unless identity && channel

    # Find the room_id for this channel from the Manager status
    # (the Manager knows which container is running and its IP).
    status = Hub::ManagerClient.status
    return nil unless status

    container = status[:containers]&.find { |c| c[:instance] == instance }
    return nil unless container

    ip = container[:ip] || container[:wg_address]
    return nil unless ip

    # Find the room_id for this channel from our cache.
    room_id = Hub::Rooms.room_id_for_slug(channel)
    return nil unless room_id

    # Re-cache the route
    Hub::RouteCache.set(instance, ip: ip, identity: identity, room_id: room_id, slug: channel)
    Hub::RouteCache.get(instance)
  end
end
