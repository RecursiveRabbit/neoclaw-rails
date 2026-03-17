# Hub → Manager API endpoint.
# POST /resolve  — spawn or find an agent
# POST /release  — freeze/tear down an agent

class ResolveController < ApplicationController
  skip_forgery_protection

  # POST /resolve
  # Hub says: "I need margaux-art"
  # Manager says: { ip: "10.0.1.14" }
  def create
    identity = params[:identity]
    channel = params[:channel]
    instance_name = "#{identity}-#{channel}"

    # Already running?
    existing = Container.alive.find_by(instance_name: instance_name)
    if existing
      render json: { ip: existing.wg_address }
      return
    end

    # TODO: full spawn flow via Spawner service
    # For now, return the interface contract
    render json: { error: "spawn not yet implemented" }, status: :service_unavailable
  end

  # POST /release
  def release
    instance = params[:instance]
    container = Container.find_by(instance_name: instance)

    unless container
      render json: { error: "unknown instance" }, status: :not_found
      return
    end

    # TODO: full teardown via Lifecycle service
    container.update!(state: "dead")
    AuditLog.record("RELEASE", instance_name: instance,
      identity: container.identity, detail: "Released by Hub")

    render json: { ok: true }
  end
end
