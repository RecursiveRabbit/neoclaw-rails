class CronMessagesController < AdminController
  before_action :set_message, only: [:show, :edit, :update, :destroy, :toggle]

  def index
    @messages = CronMessage.order(:channel, :schedule)
  end

  def show
  end

  def new
    @message = CronMessage.new
  end

  def create
    @message = CronMessage.new(message_params)
    if @message.save
      AuditLog.record("CRON_CREATE", detail: @message.description)
      redirect_to @message, notice: "Cron message created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @message.update(message_params)
      AuditLog.record("CRON_UPDATE", detail: @message.description)
      redirect_to @message, notice: "Cron message updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    desc = @message.description
    @message.destroy!
    AuditLog.record("CRON_DELETE", detail: desc)
    redirect_to cron_messages_path, notice: "Cron message deleted."
  end

  def toggle
    @message.update!(enabled: !@message.enabled)
    state = @message.enabled? ? "enabled" : "disabled"
    AuditLog.record("CRON_TOGGLE", detail: "#{@message.description} — #{state}")
    redirect_to cron_messages_path, notice: "#{@message.description} #{state}."
  end

  private

  def set_message
    @message = CronMessage.find(params[:id])
  end

  def message_params
    params.require(:cron_message).permit(:channel, :schedule, :body, :enabled, :notes)
  end
end
