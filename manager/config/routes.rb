Rails.application.routes.draw do
  # =================================================================
  # Admin UI
  # =================================================================

  root "dashboard#index"

  resources :agent_configs, path: "configs" do
    member do
      post :toggle_service
    end
  end

  resources :containers, only: [:index, :show] do
    member do
      post :freeze
      post :kill
      get :stream
    end
  end

  resources :audit_logs, only: [:index], path: "audit"

  # =================================================================
  # Hub → Manager API
  # =================================================================

  post "/resolve", to: "api#resolve"
  post "/release", to: "api#release"
  get  "/status",  to: "api#status"

  # =================================================================
  # Relay → Manager
  # =================================================================

  post "/containers/:instance/health",       to: "relay#health"
  post "/containers/:instance/output",       to: "relay#output"
  post "/containers/:instance/ready",        to: "relay#ready"
  post "/containers/:instance/freeze_ready", to: "relay#freeze_ready"

  # =================================================================
  # Health
  # =================================================================

  get "/health", to: "health#show"
  get "up" => "rails/health#show", as: :rails_health_check
end
