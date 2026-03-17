# Base controller for admin UI views — browser-facing only.

class AdminController < ApplicationController
  include Navigation
  allow_browser versions: :modern
end
