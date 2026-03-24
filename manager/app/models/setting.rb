# Key-value settings store. Each row is one tunable.
# DB value > ENV override > hardcoded default. Three-tier fallback.
#
# Adding a new setting: add one entry to DEFAULTS. No migration needed.
# It appears in the admin UI automatically and works immediately with
# its default value.

class Setting < ApplicationRecord
  validates :key, presence: true, uniqueness: true
  validates :value_type, inclusion: { in: %w[string integer float text json] }

  DEFAULTS = {
    # --- Resources ---
    "resources.memory_budget" => {
      value: (15 * 1024 * 1024 * 1024).to_s, type: "integer", group: "resources",
      desc: "Total RAM budget for agent pods (bytes). Default 15 GB."
    },
    "resources.container_memory" => {
      value: "2g", type: "string", group: "resources",
      desc: "Per-container memory limit (podman --memory format: 2g, 512m, etc.)"
    },
    "resources.container_cpus" => {
      value: "2", type: "integer", group: "resources",
      desc: "Per-container CPU limit"
    },

    # --- Watchdog ---
    "watchdog.health_stale_threshold" => {
      value: "120", type: "integer", group: "watchdog",
      desc: "Seconds before a pod is considered silent (4 missed health reports at 30s interval)"
    },
    "watchdog.check_interval" => {
      value: "60", type: "integer", group: "watchdog",
      desc: "Seconds between watchdog sweeps"
    },
    "watchdog.boot_grace_period" => {
      value: "300", type: "integer", group: "watchdog",
      desc: "Seconds to wait before checking newly spawned pods"
    },

    # --- Relay ---
    "relay.default_model" => {
      value: "claude-opus-4-6", type: "string", group: "relay",
      desc: "Default model when agent config has none"
    },
    "relay.health_interval" => {
      value: "30", type: "integer", group: "relay",
      desc: "Seconds between relay health reports to Manager"
    },
    "relay.typing_interval" => {
      value: "20", type: "integer", group: "relay",
      desc: "Seconds between typing keepalive signals to Hub"
    },
    "relay.http_timeout" => {
      value: "5", type: "integer", group: "relay",
      desc: "HTTP timeout for relay outbound requests (seconds)"
    },

    # --- System Prompts ---
    # Empty = use built-in logic in relay.rb. Non-empty = template override.
    # Variables: {{IDENTITY}}, {{CHANNEL}}, {{CLONE_URL}}, {{WORKSPACE}},
    #            {{IDENTITY_DIR}}, {{BATON_PATH}}, {{CHANNEL_REPO_URL}}
    "prompts.fresh_boot" => {
      value: "", type: "text", group: "prompts",
      desc: "Boot prompt for fresh spawns. Leave empty for built-in. Variables: {{IDENTITY}}, {{CHANNEL}}, {{CLONE_URL}}, {{WORKSPACE}}, {{IDENTITY_DIR}}, {{CHANNEL_REPO_URL}}"
    },
    "prompts.resume_boot" => {
      value: "", type: "text", group: "prompts",
      desc: "Boot prompt for resumed sessions. Same variables plus {{BATON_PATH}}"
    },
    "prompts.baton_boot" => {
      value: "", type: "text", group: "prompts",
      desc: "Boot prompt for baton handoffs (context limit reached). Same variables plus {{BATON_PATH}}"
    },
    "prompts.hot_swap" => {
      value: "", type: "text", group: "prompts",
      desc: "Prompt for hot-swapped pods with preserved workspace"
    },

    # --- Models ---
    "models.context_limits" => {
      value: '{"claude-opus-4-6":200000,"claude-sonnet-4-6":200000,"claude-haiku-4-5":200000}',
      type: "json", group: "models",
      desc: "Context window sizes per model name (tokens)"
    },
  }.freeze

  # Read a setting. DB first, then ENV, then hardcoded default.
  # Handles missing table gracefully (during migrations or first boot).
  def self.get(key)
    record = (table_exists? && find_by(key: key)) rescue nil
    if record
      return cast(record.value, record.value_type)
    end

    # ENV: "watchdog.check_interval" -> "NEOCLAW_WATCHDOG_CHECK_INTERVAL"
    env_key = "NEOCLAW_#{key.tr('.', '_').upcase}"
    env_val = ENV[env_key]
    if env_val
      meta = DEFAULTS[key]
      return cast(env_val, meta&.dig(:type) || "string")
    end

    # Hardcoded default
    meta = DEFAULTS[key]
    return cast(meta[:value], meta[:type]) if meta

    nil
  end

  # All settings for a group as a hash (short_key => typed_value).
  def self.group(name)
    DEFAULTS.select { |_k, v| v[:group] == name }.to_h do |key, _meta|
      [key.split(".").last, get(key)]
    end
  end

  # Write a setting (upsert).
  def self.set(key, value)
    meta = DEFAULTS[key]
    record = find_or_initialize_by(key: key)
    record.value = value.to_s
    record.value_type = meta&.dig(:type) || "string"
    record.group = meta&.dig(:group) || key.split(".").first
    record.description = meta&.dig(:desc) || ""
    record.save!
    record
  end

  private_class_method def self.cast(value, type)
    case type
    when "integer" then value.to_i
    when "float"   then value.to_f
    when "json"    then JSON.parse(value)
    when "text"    then value.to_s
    else value.to_s
    end
  rescue JSON::ParserError
    value.to_s
  end
end
