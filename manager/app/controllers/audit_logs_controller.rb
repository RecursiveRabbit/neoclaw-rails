class AuditLogsController < AdminController
  def index
    @logs = AuditLog.recent
  end
end
