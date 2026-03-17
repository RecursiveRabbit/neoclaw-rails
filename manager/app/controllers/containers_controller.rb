# Container views — live monitoring, freeze/kill actions, stream viewer.

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
    Lifecycle.freeze!(container)
    redirect_to containers_path, notice: "Freezing #{container.instance_name}..."
  end

  # POST /containers/:id/kill
  def kill
    container = Container.find(params[:id])
    Lifecycle.force_kill!(container)
    redirect_to containers_path, notice: "Killed #{container.instance_name}."
  end

  # GET /containers/:id/stream — live Claude Code output
  def stream
    @container = Container.find(params[:id])
  end
end
