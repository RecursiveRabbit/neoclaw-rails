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
    Rails.logger.error "resolve failed: #{e.message}\n#{e.backtrace.first(10).join("\n")}"
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

  # GET /identities
  def identities
    configs = AgentConfig.order(:identity).map { |c|
      { name: c.identity, singleton: c.singleton }
    }
    render json: configs
  end

  # GET /status
  def status
    memory_used = Podman.agent_memory_usage
    memory_budget = Surface.memory_budget

    render json: {
      pods: Container.alive.count,
      capacity: {
        running: Container.active.count,
        memory_used: memory_used,
        memory_budget: memory_budget,
        memory_pct: memory_budget > 0 ? (memory_used.to_f / memory_budget * 100).round(1) : 0
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
