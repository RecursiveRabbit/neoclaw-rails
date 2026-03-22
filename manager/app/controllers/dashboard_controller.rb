# The main view — running containers, capacity, recent activity.

class DashboardController < AdminController
  def index
    @containers = Container.active.order(state: :asc, last_message_at: :desc)
    @alive_count = Container.alive.count
    @starting_count = Container.starting.count
    memory_used = Podman.agent_memory_usage
    memory_budget = Surface.memory_budget
    @capacity = {
      running: @alive_count + @starting_count,
      memory_used: memory_used,
      memory_budget: memory_budget,
      memory_pct: memory_budget > 0 ? (memory_used.to_f / memory_budget * 100).round(1) : 0
    }
    @recent_audit = AuditLog.recent.limit(15)
    @configs = AgentConfig.order(:identity)
  end
end
