# Container views — live monitoring, freeze/rescue actions, stream viewer.

class ContainersController < AdminController
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

  # POST /containers/:id/rescue — save what we can, bring them home
  def rescue
    container = Container.find(params[:id])
    Lifecycle.rescue!(container)
    redirect_to containers_path, notice: "Rescued #{container.instance_name}."
  end

  # POST /containers/:id/refresh — hot swap to latest image
  def refresh
    container = Container.find(params[:id])
    Thread.new do
      Lifecycle.hot_swap!(container)
    rescue => e
      Rails.logger.error "hot_swap #{container.instance_name}: #{e.message}"
      AuditLog.record("SWAP_FAILED",
        instance_name: container.instance_name, detail: e.message)
    end
    redirect_to containers_path, notice: "Refreshing #{container.instance_name}..."
  end

  # POST /containers/:id/stop — kill the running claude process
  def stop
    container = Container.find(params[:id])
    HTTPX.post("http://#{container.wg_address}:9300/signal", json: { signal: "stop" })
    redirect_to stream_container_path(container), notice: "Stop signal sent."
  rescue => e
    redirect_to containers_path, alert: "Stop failed: #{e.message}"
  end

  # GET /containers/:id/stream — live Claude Code output
  def stream
    @container = Container.find(params[:id])
  end
end
