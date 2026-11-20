require "json"
require "net/http"
require "uri"

# The relay is the Manager's second and last data source: the only place facts
# about the *inside* of a pod may come from.
#
# The relay does not exist yet (cove.md §7). That is not a problem for this
# build and it is not a fallback either: every question below is asked, every
# ask that gets no answer is written down, and the written-down asks are the
# relay's API. The blind-answer law applies to this client before it applies to
# any relay: no verdict is ever synthesised from an absence of facts.
#
# This module is the one place a "relay" appears in code, and it appears as an
# address and a query — never as a model of what a relay is.
module Relay
  # What the Manager wants to know, declared by need, in the order a human
  # reads a pod page. Each one is a single question with a factual answer.
  WANTS = {
    "process_state"  => "is the agent process alive inside the pod, and since when",
    "last_token_age" => "seconds since the model last emitted a token",
    "resources"      => "cpu and memory of the agent process inside the pod",
    "repo_head"      => "the agent repo's HEAD commit, and whether its tree is dirty"
  }.freeze

  DEFAULT_TEMPLATE = "http://%{agent}:9180".freeze
  OPEN_TIMEOUT = Float(ENV.fetch("COVE_RELAY_CONNECT_TIMEOUT", "1.5"))
  READ_TIMEOUT = Float(ENV.fetch("COVE_RELAY_READ_TIMEOUT", "2.5"))

  Facts = Struct.new(:agent, :want, :seen, :reason, :payload, :asked_at, keyword_init: true) do
    def seen? = !!seen
    # A fact the UI may render. Absent when the relay could not answer — the
    # page shows the reason instead, and never a dash that reads like a zero.
    def value = seen? ? payload["value"] : nil
    def detail = seen? ? payload["detail"] : nil
  end

  class << self
    def template
      ENV.fetch("COVE_RELAY_URL_TEMPLATE", DEFAULT_TEMPLATE)
    end

    def url_for(agent_slug)
      template.gsub("%{agent}", agent_slug.to_s)
    end

    # Ask the relay one question. Returns Facts, always — with seen: false and
    # a reason when nothing could answer, and records the want in that case.
    def ask(agent_slug, want, params = {})
      raise ArgumentError, "undeclared want: #{want}" unless WANTS.key?(want.to_s)

      base = url_for(agent_slug)
      uri = begin
        u = URI.parse(base)
        raise URI::InvalidURIError, "no host" if u.host.nil? || u.host.empty?
        u
      rescue URI::InvalidURIError => e
        return blind(agent_slug, want, "relay address is unusable (#{base}): #{e.message}")
      end

      query = URI.encode_www_form({ "want" => want }.merge(params))
      path = [uri.path.to_s.empty? ? "/facts" : uri.path, query].join("?")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      response = http.start { |h| h.get(path) }
      unless response.is_a?(Net::HTTPSuccess)
        return blind(agent_slug, want, "relay answered HTTP #{response.code}")
      end

      payload = JSON.parse(response.body)
      unless payload.is_a?(Hash) && payload.key?("value")
        # An answer without a value is not an answer. Never coerce one.
        return blind(agent_slug, want, "relay replied without a value")
      end

      Facts.new(agent: agent_slug, want: want, seen: true, reason: nil,
                payload: payload, asked_at: Time.now.utc.iso8601)
    rescue Net::OpenTimeout, Net::ReadTimeout
      blind(agent_slug, want, "relay did not answer within #{READ_TIMEOUT}s (#{base})")
    rescue Errno::ECONNREFUSED
      blind(agent_slug, want, "nothing listening at #{base}")
    rescue SocketError, Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
      blind(agent_slug, want, "relay address unreachable (#{base}): #{e.class}")
    rescue JSON::ParserError
      blind(agent_slug, want, "relay reply was not JSON")
    rescue StandardError => e
      blind(agent_slug, want, "relay ask failed: #{e.class}: #{e.message}")
    end

    def blind(agent_slug, want, reason)
      WantsLog.record(want: want, agent: agent_slug, reason: reason)
      Facts.new(agent: agent_slug, want: want, seen: false, reason: reason,
                payload: nil, asked_at: Time.now.utc.iso8601)
    end

    # Everything the pod page shows, in one pass. Each ask is independent: one
    # silent relay does not hide four facts, and four silences do not read as
    # one. (Same reason the relay reports facts, not verdicts.)
    def panel(agent_slug)
      WANTS.keys.map { |want| ask(agent_slug, want) }
    end
  end
end
