class ApplicationController < ActionController::Base
  # No global browser check — API and Relay controllers receive
  # HTTP from infrastructure, not browsers. Admin UI controllers
  # inherit from AdminController which adds the browser check.
end
