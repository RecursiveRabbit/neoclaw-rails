# Agent+Room overrides — specific service additions for one identity
# in one room. Nested under agent configs.

class AgentRoomConfigsController < AdminController
  before_action :set_agent_config
  before_action :set_override, only: [:edit, :update, :destroy, :toggle_service]

  def new
    @override = @agent_config.agent_room_configs.build
    @services = ServiceType.enabled.order(:name)
  end

  def create
    @override = @agent_config.agent_room_configs.build(override_params)
    if @override.save
      AuditLog.record("ROOM_OVERRIDE_CREATE", identity: @agent_config.identity,
        detail: "##{@override.channel}: +#{@override.extra_services&.join(', ')}")
      redirect_to @agent_config, notice: "Room override for ##{@override.channel} added."
    else
      @services = ServiceType.enabled.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @services = ServiceType.enabled.order(:name)
  end

  def update
    if @override.update(override_params)
      AuditLog.record("ROOM_OVERRIDE_UPDATE", identity: @agent_config.identity,
        detail: "##{@override.channel}: +#{@override.extra_services&.join(', ')}")
      redirect_to @agent_config, notice: "Room override updated."
    else
      @services = ServiceType.enabled.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    channel = @override.channel
    @override.destroy!
    AuditLog.record("ROOM_OVERRIDE_DELETE", identity: @agent_config.identity,
      detail: "##{channel}")
    redirect_to @agent_config, notice: "Room override for ##{channel} removed."
  end

  # POST /configs/:agent_config_id/rooms/:id/toggle_service
  def toggle_service
    service_name = params[:service]
    services = @override.extra_services || []
    if services.include?(service_name)
      services.delete(service_name)
    else
      services << service_name
    end
    @override.update!(extra_services: services)
    redirect_to @agent_config
  end

  private

  def set_agent_config
    @agent_config = AgentConfig.find(params[:agent_config_id])
  end

  def set_override
    @override = @agent_config.agent_room_configs.find(params[:id])
  end

  def override_params
    params.require(:agent_room_config).permit(
      :channel, :model_override, :notes,
      extra_services: []
    ).tap do |p|
      p[:extra_services]&.reject!(&:blank?)
    end
  end
end
