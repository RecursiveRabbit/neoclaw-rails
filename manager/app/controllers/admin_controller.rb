# Base controller for admin UI views — browser-facing only.
# Protected by ADMIN_TOKEN generated at startup.

class AdminController < ApplicationController
  include Navigation
  before_action :require_auth

  private

  def require_auth
    return if session[:authenticated]
    return if params[:controller] == "sessions"

    render plain: "Unauthorized. Use the link from run.sh.", status: :unauthorized
  end
end
