# Manager → Hub callbacks.
# The Manager notifies the Hub when agents are released or events occur.

class CallbacksController < ApplicationController
  # POST /callback
  def create
    event_type = params[:event]
    instance = params[:instance]

    Rails.logger.info "Manager callback: #{event_type} #{instance}"

    case event_type
    when "ready"
      handle_ready(instance)
    when "released"
      handle_released(instance, params)
    when "sunset_warning"
      handle_sunset_warning(instance, params)
    when "crash"
      handle_crash(instance)
    end

    render json: { received: true }
  end

  private

  def handle_ready(instance)
    route = Hub::RouteCache.get(instance)
    return unless route

    Hub::RouteCache.clear_resolving(instance)
    Hub::Matrix.set_typing(route[:identity], route[:room_id], false)
    Hub::Matrix.set_presence(route[:identity], "online")
  end

  def handle_released(instance, data)
    route = Hub::RouteCache.get(instance)
    return unless route

    reason = data[:reason] || "idle"
    Hub::Matrix.set_typing(route[:identity], route[:room_id], false)
    Hub::Matrix.set_presence(route[:identity], "unavailable")
    Hub::Matrix.notify(route[:room_id], "#{instance} session ended (#{reason}).")
    Hub::RouteCache.delete(instance)
  end

  def handle_sunset_warning(instance, data)
    route = Hub::RouteCache.get(instance)
    return unless route

    usage = data[:context_usage] || 0
    Hub::Matrix.notify(route[:room_id],
      "#{instance} approaching context limit (#{(usage.to_f * 100).round}%). " \
      "Direct final priorities.")
  end

  def handle_crash(instance)
    route = Hub::RouteCache.get(instance)
    return unless route

    Hub::Matrix.set_typing(route[:identity], route[:room_id], false)
    Hub::Matrix.set_presence(route[:identity], "unavailable")
    Hub::Matrix.notify(route[:room_id], "#{instance} crashed. Session preserved.")
    Hub::RouteCache.delete(instance)
  end
end
