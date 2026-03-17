class HealthController < ApplicationController
  def show
    manager_status = Hub::ManagerClient.status

    render json: {
      status: "ok",
      hub: {
        agents_alive: Agent.alive.count,
        agents_resolving: Agent.resolving.count,
        rooms: Room.count,
        identities: Identity.count
      },
      manager: manager_status || "unreachable"
    }
  end
end
