class AuditLogsController < ApplicationController
  def index
    @logs = AuditLog.order(created_at: :desc).limit(200)
  end
end
