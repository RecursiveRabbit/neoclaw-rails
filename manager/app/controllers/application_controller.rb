class ApplicationController < ActionController::Base
  include Navigation
  allow_browser versions: :modern
end
