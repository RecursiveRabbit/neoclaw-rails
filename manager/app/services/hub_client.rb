# Callbacks to the Hub — the Manager's only outbound communication.

class HubClient
  class << self
    def callback(event:, instance:, **extra)
      http.post(
        "#{Surface.hub_url}/callback",
        json: { event: event, instance: instance, **extra }
      )
    rescue => e
      Rails.logger.error "Hub callback failed: #{e.message}"
      AuditLog.record("HUB_CALLBACK_FAILED",
        instance_name: instance,
        detail: "#{event}: #{e.message}")
    end

    def post_message(channel:, body:)
      http.post(
        "#{Surface.hub_url}/neobot/message",
        json: { channel: channel, body: body }
      )
    rescue => e
      Rails.logger.error "Hub post_message failed: #{e.message}"
      AuditLog.record("NEOBOT_DELIVERY_FAILED", detail: "#{channel}: #{e.message}")
    end

    private

    def http
      @http ||= HTTPX.with(timeout: { operation_timeout: 10 })
    end
  end
end
