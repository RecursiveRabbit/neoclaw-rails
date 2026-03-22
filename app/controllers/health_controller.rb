class HealthController < ApplicationController
  def show
    manager_status = Hub::ManagerClient.status

    render json: {
      status: "ok",
      hub: {
        routes: Hub::RouteCache.count,
        resolving: Hub::RouteCache.resolving_count,
        rooms: Hub::Rooms.count,
        identities: Hub::Identities.count
      },
      manager: manager_status || "unreachable"
    }
  end
end
