module Cove
  class RouterController < ApplicationController
    # The suite drives this one; see the note on SheetsController's forgery skip.
    skip_forgery_protection only: %i[render_now]
    # The seam, rendered. What you see here is the file on disk, not a preview:
    # a preview would be a second copy of the truth.
    def show
      @body = RouterConfig.current
      @path = Cove.router_file.to_s
    end

    def render_now
      RouterConfig.write!(Plan.network_map)
      Launch.recommission!
      redirect_to router_config_path, notice: "router.conf re-rendered whole from state/"
    rescue Cove::DocumentError => e
      redirect_to router_config_path, alert: "render failed: #{e.message}"
    end
  end
end
