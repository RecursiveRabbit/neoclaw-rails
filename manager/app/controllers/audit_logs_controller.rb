class AuditLogsController < ApplicationController
  def index
    @logs = AuditLog.recent
  end
end
