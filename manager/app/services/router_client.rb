# RouterClient — the Manager's interface to the WG-Router.
#
# The Router owns all WireGuard and firewall state.
# The Manager tells the Router what to do via HTTP API.
# The Router is the only peer every agent shares.
#
# API: POST /agents, PUT /agents/:name/peer, DELETE /agents/:name/peer,
#      PATCH /agents/:name, DELETE /agents/:name, GET /agents/:name

class RouterClient
  class RouterError < StandardError; end

  class << self
    # Register a new agent (first spawn ever for this instance name).
    # Creates firewall rules + WG peer. Router allocates IP if none provided.
    def register(name:, pubkey:, access:, address: nil)
      body = { name: name, peer_pubkey: pubkey, access: access }
      body[:address] = "#{address}/32" if address
      resp = post("/agents", body)
      handle(resp, "register #{name}")
    end

    # Swap WG pubkey (subsequent spawns — agent was frozen, now waking).
    # Firewall rules already exist. Just swap the key.
    def activate(name:, pubkey:)
      resp = put("/agents/#{name}/peer", { peer_pubkey: pubkey })
      handle(resp, "activate #{name}")
    end

    # Freeze — remove WG peer, keep firewall rules.
    def freeze(name:)
      resp = delete("/agents/#{name}/peer")
      handle(resp, "freeze #{name}")
    end

    # Full decommission — remove firewall rules, WG peer, all state.
    def decommission(name:)
      resp = delete("/agents/#{name}")
      handle(resp, "decommission #{name}")
    end

    # Update access rules.
    def update_access(name:, access:)
      resp = patch("/agents/#{name}", { access: access })
      handle(resp, "update_access #{name}")
    end

    # Emergency block.
    def block(name:)
      resp = post("/agents/#{name}/block", {})
      handle(resp, "block #{name}")
    end

    # Check if agent is registered on the Router.
    def registered?(name)
      resp = get("/agents/#{name}")
      resp.respond_to?(:status) && resp.status == 200
    rescue
      false
    end

    # Get agent info from Router.
    def agent_info(name)
      resp = get("/agents/#{name}")
      return nil unless resp.respond_to?(:status) && resp.status == 200
      JSON.parse(resp.body, symbolize_names: true)
    rescue
      nil
    end

    # List all registered agents (for IP inventory, etc.)
    def all_agents
      resp = get("/agents")
      return {} unless resp.respond_to?(:status) && resp.status == 200
      data = JSON.parse(resp.body, symbolize_names: true)
      data[:agents] || {}
    rescue
      {}
    end

    # Router health.
    def health
      resp = get("/health")
      return nil unless resp.respond_to?(:status) && resp.status == 200
      JSON.parse(resp.body, symbolize_names: true)
    rescue
      nil
    end

    private

    def handle(resp, context)
      unless resp.respond_to?(:status)
        raise RouterError, "#{context}: #{resp.error.message}"
      end
      unless (200..299).include?(resp.status)
        body = begin; JSON.parse(resp.body); rescue; resp.body; end
        raise RouterError, "#{context}: #{resp.status} #{body}"
      end
      JSON.parse(resp.body, symbolize_names: true)
    end

    def post(path, body)
      http.post(url(path), json: body)
    end

    def put(path, body)
      http.put(url(path), json: body)
    end

    def patch(path, body)
      http.with(headers: { "content-type" => "application/json" })
          .request("PATCH", url(path), body: JSON.generate(body))
    end

    def delete(path)
      http.delete(url(path))
    end

    def get(path)
      http.get(url(path))
    end

    def url(path)
      "#{Surface.router_url}#{path}"
    end

    def http
      @http ||= HTTPX.with(timeout: { operation_timeout: 30 })
    end
  end
end
