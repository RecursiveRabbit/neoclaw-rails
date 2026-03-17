# The main view — running containers, capacity, recent activity.

class DashboardController < AdminController
  def index
    @containers = Container.active.order(state: :asc, last_message_at: :desc)
    @alive_count = Container.alive.count
    @starting_count = Container.starting.count
    @capacity = {
      running: @alive_count + @starting_count,
      soft_cap: Surface.soft_cap,
      hard_cap: Surface.hard_cap
    }
    @recent_audit = AuditLog.recent.limit(15)
    @configs = AgentConfig.order(:identity)
  end
end
