# Agent configuration CRUD — the admin UI for identity settings.
# Checkboxes for services, model selection, timeout sliders.

class AgentConfigsController < ApplicationController
  before_action :set_config, only: [:show, :edit, :update, :destroy]

  def index
    @configs = AgentConfig.order(:identity)
  end

  def show
    @services = ServiceType.enabled.order(:name)
  end

  def new
    @config = AgentConfig.new
    @services = ServiceType.enabled.order(:name)
  end

  def create
    @config = AgentConfig.new(config_params)
    if @config.save
      AuditLog.record("CONFIG_CREATE", identity: @config.identity,
        detail: "Created config: #{@config.base_services.join(', ')}")
      redirect_to @config, notice: "#{@config.identity} configured."
    else
      @services = ServiceType.enabled.order(:name)
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @services = ServiceType.enabled.order(:name)
  end

  def update
    if @config.update(config_params)
      AuditLog.record("CONFIG_UPDATE", identity: @config.identity,
        detail: "Updated: #{@config.base_services.join(', ')}")
      redirect_to @config, notice: "#{@config.identity} updated."
    else
      @services = ServiceType.enabled.order(:name)
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    identity = @config.identity
    @config.destroy!
    AuditLog.record("CONFIG_DELETE", identity: identity)
    redirect_to agent_configs_path, notice: "#{identity} removed."
  end

  private

  def set_config
    @config = AgentConfig.find(params[:id])
  end

  def config_params
    params.require(:agent_config).permit(
      :identity, :repo, :model, :singleton, :idle_timeout, :notes,
      base_services: []
    ).tap do |p|
      # Clean empty strings from checkbox arrays
      p[:base_services]&.reject!(&:blank?)
    end
  end
end
