# Hub → Manager API.
# POST /resolve  — spawn or find an agent
# POST /release  — freeze/tear down an agent
# GET  /status   — capacity and container info

class ApiController < ApplicationController
  skip_forgery_protection

  # POST /resolve
  def resolve
    identity = params[:identity]
    channel  = params[:channel]

    unless identity && channel
      render json: { error: "missing identity or channel" }, status: :bad_request
      return
    end

    result = Spawner.resolve(identity: identity, channel: channel)
    render json: result
  rescue => e
    Rails.logger.error "resolve failed: #{e.message}"
    render json: { error: e.message }, status: :service_unavailable
  end

  # POST /release
  def release
    instance = params[:instance]
    unless instance
      render json: { error: "missing instance" }, status: :bad_request
      return
    end

    Lifecycle.release(instance)
    render json: { ok: true }
  end

  # GET /status
  def status
    render json: {
      pods: Container.alive.count,
      capacity: {
        running: Container.active.count,
        soft_cap: Surface.soft_cap,
        hard_cap: Surface.hard_cap
      },
      containers: Container.active.order(:instance_name).map { |c|
        {
          instance: c.instance_name,
          identity: c.identity,
          channel: c.channel,
          state: c.state,
          context_pct: c.context_percent,
          uptime: helpers.distance_of_time_in_words(c.created_at, Time.current)
        }
      }
    }
  end
end
