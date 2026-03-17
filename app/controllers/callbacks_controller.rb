# Manager → Hub callbacks.
# The Manager notifies the Hub when agents are released or events occur.

class CallbacksController < ApplicationController
  # POST /callback
  def create
    event_type = params[:event]
    instance = params[:instance]

    Rails.logger.info "Manager callback: #{event_type} #{instance}"

    case event_type
    when "released"
      handle_released(instance, params)
    when "sunset_warning"
      handle_sunset_warning(instance, params)
    when "crash"
      handle_crash(instance, params)
    end

    render json: { received: true }
  end

  private

  def handle_released(instance, data)
    agent = Agent.find_by(instance_name: instance)
    return unless agent

    reason = data[:reason] || "idle"
    Hub::Matrix.set_typing(agent.identity.name, agent.room.matrix_room_id, false)
    Hub::Matrix.set_presence(agent.identity.name, "unavailable")
    Hub::Matrix.notify(agent.room.matrix_room_id,
      "#{instance} session ended (#{reason}).")
    agent.destroy!
  end

  def handle_sunset_warning(instance, data)
    agent = Agent.alive.find_by(instance_name: instance)
    return unless agent

    usage = data[:context_usage] || 0
    Hub::Matrix.notify(agent.room.matrix_room_id,
      "#{instance} approaching context limit (#{(usage.to_f * 100).round}%). " \
      "Direct final priorities.")
  end

  def handle_crash(instance, data)
    agent = Agent.find_by(instance_name: instance)
    return unless agent

    Hub::Matrix.set_typing(agent.identity.name, agent.room.matrix_room_id, false)
    Hub::Matrix.set_presence(agent.identity.name, "unavailable")
    Hub::Matrix.notify(agent.room.matrix_room_id,
      "#{instance} crashed. Session preserved.")
    agent.destroy!
  end
end
