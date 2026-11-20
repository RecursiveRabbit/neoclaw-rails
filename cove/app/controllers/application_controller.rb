class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception

  # No flash, no session state, no cache: every message the user needs is in the
  # URL of the page he is on, so a reload cannot show him a notice about
  # something that is no longer true.
  def notice
    params[:notice].presence
  end
  helper_method :notice

  def alert
    params[:alert].presence
  end
  helper_method :alert

  private

  def sheet_attrs
    attrs = {}
    %w[name harness model repo image command].each do |k|
      attrs[k] = params[k] if params.key?(k)
    end
    attrs["tools"] = Sheet.arrayify(params[:tools]) if params.key?(:tools)
    if params.key?(:services)
      # Checkbox group: an unticked box sends nothing, so "absent" means
      # "none allowed", which is a decision and not a missing value.
      attrs["services"] = Sheet.arrayify(params[:services])
    end
    attrs
  end
end
