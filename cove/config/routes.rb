Rails.application.routes.draw do
  root "sheets#index"

  # Sheets: the only durable documents. A sheet is created, edited, and rendered.
  resources :sheets, only: %i[index new create edit update], param: :slug
  post "sheets/:slug/start", to: "sheets#start", as: :start_sheet

  # Pods: never stored, always queried.
  get  "pods",             to: "pods#index"
  get  "pods/:slug",       to: "pods#show",  as: :pod
  post "pods/:slug/stop",  to: "pods#stop"

  # The relay's build list, read out of the append-only log the app writes.
  get "relay-wants", to: "relay_wants#index"

  # The seam, visible. Reading the rendered file is how you check the Manager.
  get "router.conf", to: "router#show", as: :router_config
  post "router.conf/render", to: "router#render_now"
end
