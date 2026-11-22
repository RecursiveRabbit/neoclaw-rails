Rails.application.routes.draw do
  # Everything is `Cove::`: a monorepo that already holds a router, and will hold
  # a relay, cannot have top-level constants named Sheet, Podman, Relay wandering
  # the global namespace. The name that reads well in a stack trace is also the
  # one that cannot collide with something else in this repo.
  scope module: :cove do
    root "sheets#index"

    # Sheets: the only durable documents. A sheet is created, edited, and rendered.
    resources :sheets, only: %i[index new create edit update], param: :slug
    post "sheets/:slug/start", to: "sheets#start", as: :start_sheet
    post "sheets/:slug/permits", to: "sheets#permits", as: :sheet_permits

    # Pods: never stored, always queried.
    get  "pods",             to: "pods#index"
    # The teardown row goes before the :slug routes so the literal is never read as
    # a slug by a future reader, and so `destroy_all` can never be a pod that exists.
    post "pods/destroy_all", to: "pods#destroy_all", as: :destroy_all_pods
    get  "pods/:slug",       to: "pods#show",  as: :pod
    post "pods/:slug/stop",  to: "pods#stop"

    # The relay's build list, read out of the append-only log the app writes.
    get "relay-wants", to: "relay_wants#index"

    # The seam, visible. Reading the rendered file is how you check the Manager.
    get "router.conf", to: "router#show", as: :router_config
    post "router.conf/render", to: "router#render_now"
  end
end
