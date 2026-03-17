class HealthController < ApplicationController
  def show
    render json: {
      status: "ok",
      containers: Container.alive.count,
      starting: Container.starting.count,
      configs: AgentConfig.count,
      services: ServiceType.enabled.count
    }
  end
end
