# Room configuration — services and defaults that apply to every
# agent spawned in a room.

class RoomConfigsController < AdminController
  before_action :set_room, only: [:show, :edit, :update, :destroy]

  def index
    @rooms = RoomConfig.order(:channel)
  end

  def show
    @services = ServiceType.enabled.order(:name)
    @overrides = AgentRoomConfig.where(channel: @room.channel)
      .includes(:agent_config).order("agent_configs.identity")
  end

  def new
    @room = RoomConfig.new
    @services = ServiceType.enabled.order(:name)
  end

  def create
    @room = RoomConfig.new(room_params)
    if @room.save
      AuditLog.record("ROOM_CREATE", detail: "Room ##{@room.channel}: #{@room.extra_services&.join(', ')}")
      redirect_to @room, notice: "##{@room.channel} configured."
    else
      @services = ServiceType.enabled.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @services = ServiceType.enabled.order(:name)
  end

  def update
    if @room.update(room_params)
      AuditLog.record("ROOM_UPDATE", detail: "Room ##{@room.channel}: #{@room.extra_services&.join(', ')}")
      redirect_to @room, notice: "##{@room.channel} updated."
    else
      @services = ServiceType.enabled.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    channel = @room.channel
    @room.destroy!
    AuditLog.record("ROOM_DELETE", detail: "Room ##{channel}")
    redirect_to room_configs_path, notice: "##{channel} removed."
  end

  private

  def set_room
    @room = RoomConfig.find(params[:id])
  end

  def room_params
    params.require(:room_config).permit(
      :channel, :model_default, :notes,
      extra_services: []
    ).tap do |p|
      p[:extra_services]&.reject!(&:blank?)
    end
  end
end
