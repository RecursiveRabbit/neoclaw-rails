# Container views — live monitoring, freeze/kill actions.

class ContainersController < ApplicationController
  def index
    @containers = Container.order(state: :asc, created_at: :desc)
  end

  def show
    @container = Container.find(params[:id])
  end

  # POST /containers/:id/freeze
  def freeze
    container = Container.find(params[:id])
    # TODO: actual freeze via Lifecycle service
    container.update!(state: "freezing")
    AuditLog.record("FREEZE_MANUAL", instance_name: container.instance_name,
      identity: container.identity, detail: "Manual freeze from dashboard")
    redirect_to containers_path, notice: "Freezing #{container.instance_name}..."
  end

  # POST /containers/:id/kill
  def kill
    container = Container.find(params[:id])
    # TODO: actual kill via Lifecycle service
    container.update!(state: "dead")
    AuditLog.record("KILL", instance_name: container.instance_name,
      identity: container.identity, detail: "Manual kill from dashboard")
    redirect_to containers_path, notice: "Killed #{container.instance_name}."
  end

  # GET /containers/:id/stream — live Claude Code output
  def stream
    @container = Container.find(params[:id])
  end
end
