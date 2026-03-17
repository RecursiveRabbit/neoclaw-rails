# The main view — running containers, context usage, system health.

class DashboardController < ApplicationController
  def index
    @containers = Container.order(state: :asc, last_message_at: :desc)
    @alive_count = Container.alive.count
    @total_context = Container.alive.average(:context_usage)&.round(1) || 0
    @recent_audit = AuditLog.recent.limit(20)
    @agent_configs = AgentConfig.order(:identity)
  end
end
