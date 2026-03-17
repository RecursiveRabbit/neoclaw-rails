class HealthController < ApplicationController
  def show
    render json: {
      status: "ok",
      hub: {
        agents_alive: Agent.alive.count,
        agents_resolving: Agent.resolving.count,
        rooms: Room.count,
        identities: Identity.count
      },
      manager: {
        containers: Container.alive.count,
        configs: AgentConfig.count,
        services: ServiceType.enabled.count
      }
    }
  end
end
