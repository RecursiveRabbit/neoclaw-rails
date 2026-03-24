Rails.application.routes.draw do
  # =================================================================
  # Admin UI
  # =================================================================

  root "dashboard#index"

  resources :agent_configs, path: "configs" do
    member do
      post :toggle_service
    end
    resources :agent_room_configs, path: "rooms", only: [:new, :create, :edit, :update, :destroy] do
      member do
        post :toggle_service
      end
    end
  end

  resources :room_configs, path: "rooms"

  resources :containers, only: [:index, :show] do
    member do
      post :freeze
      post :rescue
      post :refresh
      post :stop
      post :send_message
      get :stream
    end
  end

  resources :cron_messages, path: "crons" do
    member do
      post :toggle
    end
  end

  resources :audit_logs, only: [:index], path: "audit"

  get  "settings", to: "settings#index", as: :settings
  patch "settings", to: "settings#update"

  # =================================================================
  # Hub → Manager API
  # =================================================================

  post "/resolve",    to: "api#resolve"
  post "/release",    to: "api#release"
  get  "/status",     to: "api#status"
  get  "/identities", to: "api#identities"

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
