# Neobot — scheduled message delivery from the Manager.
# The Manager's CronScheduler posts here; we puppet it into Matrix.

class NeobotController < ApplicationController
  # POST /neobot/message
  # Manager's CronScheduler sends scheduled messages here.
  def message
    channel = params[:channel]
    body = params[:body]

    unless channel && body
      render json: { error: "missing channel or body" }, status: :bad_request
      return
    end

    room_id = Hub::Rooms.room_id_for_slug(channel)
    unless room_id
      render json: { error: "unknown channel: #{channel}" }, status: :not_found
      return
    end

    Hub::Matrix.notify(room_id, body)
    render json: { ok: true }
  end
end
