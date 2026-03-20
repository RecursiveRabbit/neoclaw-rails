#!/usr/bin/env ruby
# The Relay — lives inside every agent container.
#
# Runs as the agent user (entrypoint.sh handles root setup: WireGuard,
# credentials, SSH keys). This process does four things:
#
# 1. Receives messages from the Hub and pipes them to Claude Code
# 2. Sends Claude Code responses back to the Hub
# 3. Reports health to the Manager every 30 seconds
# 4. Handles freeze/sunset signals from the Manager
#
# Claude Code is invoked per-message with --continue.
# The first invocation (boot) has no --continue. Subsequent messages resume.
#
# This is the entire agent-side runtime. One file. No framework.

require "webrick"
require "json"
require "open3"
require "fileutils"
require "net/http"
require "uri"

WORKSPACE   = "/workspace"
SPAWN_FILE  = "/run/secrets/spawn.json"
RELAY_PORT  = 9300
HEALTH_INTERVAL = 30

class Relay
  def initialize
    @spawn = JSON.parse(File.read(SPAWN_FILE), symbolize_names: true)
    @instance_name = @spawn[:instance]
    @identity = @spawn[:identity]
    @channel = @spawn[:channel]
    @model = @spawn[:model] || "claude-opus-4-6"
    @hub_ip = detect_hub_ip
    @manager_ip = detect_manager_ip
    @running = true
    @booted = false
    @booting = false
    @processing = false
    @context_usage = 0.0
    @last_message_at = Time.now
    @mutex = Mutex.new
  end

  def run
    start_health_thread
    boot_in_background
    start_server  # blocks
  end

  private

  # ==================================================================
  # Boot sequence
  # ==================================================================

  def boot_in_background
    @booting = true
    Thread.new do
      begin
        boot_claude_code
      rescue => e
        log "Boot failed: #{e.message}"
        log e.backtrace.first(5).join("\n")
      ensure
        @booting = false
      end
    end
  end

  def boot_clone_url
    git_conf = @spawn[:git] || {}
    repo = git_conf[:repo] || "#{@identity}/workspace"

    # SSH clone via the host (10.0.0.2:2222). All services are on the
    # host, reached through the Router. Forgejo SSH is port 2222.
    "ssh://git@#{detect_hub_ip}:2222/#{repo}.git"
  end

  def boot_claude_code
    clone_url = boot_clone_url

    boot_prompt = [
      "You have just been instantiated as #{@identity} in channel ##{@channel}.",
      "Your workspace is empty. Your first act is to clone your repo:",
      "  git clone #{clone_url} #{WORKSPACE}",
      "Then read #{WORKSPACE}/identity.json to learn who you are.",
      "Read #{WORKSPACE}/baton.json to pick up where you left off.",
      "Read #{WORKSPACE}/memory/ for your accumulated memories.",
      "Orient yourself. Push your work before you go.",
    ].join("\n")

    log "Booting agent..."
    @mutex.synchronize { invoke_claude(boot_prompt, continue: false) }
    @booted = true
    signal_ready
    log "Agent booted and ready"
  end

  def signal_ready
    post_to_manager("/containers/#{@instance_name}/ready", {})
    log "Signaled READY to Manager"
  end

  # ==================================================================
  # Claude Code invocation
  # ==================================================================

  # Run claude -p with a prompt. Streams output, collects response.
  # If continue: true, resumes the previous conversation.
  # Caller must hold @mutex.
  def invoke_claude(prompt, continue: true)
    @processing = true
    @last_message_at = Time.now

    # Typing indicator: on when claude is running, off when it's done.
    post_to_hub("/agent/event", { instance: @instance_name, event: "typing" })

    cmd = [
      "claude",
      "--model", @model,
      "--output-format", "stream-json",
      "--verbose",
      "--dangerously-skip-permissions",
    ]

    # Load MCP config if present — must be on the initial invocation
    mcp_config = File.join(Dir.home, ".claude", "mcp.json")
    cmd.push("--mcp-config", mcp_config) if File.exist?(mcp_config) && !continue

    cmd.push("-p", prompt)
    cmd << "--continue" if continue

    log "Invoking: #{continue ? '--continue' : 'fresh'} (#{prompt.length} chars)"

    response_text = []

    # No uid switching needed — entrypoint.sh already dropped to agent user.
    # No unsetenv_others — inherit the normal agent environment.
    Open3.popen3(*cmd, chdir: File.exist?(WORKSPACE) ? WORKSPACE : Dir.home) do |stdin, stdout, stderr, wait_thread|
      stdin.close

      stderr_thread = Thread.new do
        stderr.each_line { |line| log "claude(err): #{line.strip}" }
      rescue IOError
        # expected when process exits
      end

      stdout.each_line do |line|
        line = line.strip
        next if line.empty?

        # Forward raw stream-json to Manager for live UI
        forward_output(line)

        begin
          event = JSON.parse(line, symbolize_names: true)

          case event[:type]
          when "assistant"
            content_blocks = event.dig(:message, :content) || []
            text_parts = content_blocks
              .select { |b| b[:type] == "text" }
              .map { |b| b[:text] }
            response_text.concat(text_parts)

            # Track context usage
            if event.dig(:message, :usage)
              input_t = event.dig(:message, :usage, :input_tokens) || 0
              output_t = event.dig(:message, :usage, :output_tokens) || 0
              @context_usage = (input_t + output_t).to_f / 200_000
            end

          when "result"
            if event[:usage]
              input_t = event.dig(:usage, :input_tokens) || 0
              output_t = event.dig(:usage, :output_tokens) || 0
              @context_usage = (input_t + output_t).to_f / 200_000
            end
          end

        rescue JSON::ParserError
          # Not JSON — skip
        end
      rescue IOError
        break
      end

      stderr_thread.join(5)
      wait_thread.join
    end

    @processing = false
    post_to_hub("/agent/event", { instance: @instance_name, event: "done_typing" })

    full_response = response_text.join("\n")
    log "Response: #{full_response.length} chars"
    full_response
  end

  # ==================================================================
  # HTTP server — receives messages from Hub, signals from Manager
  # ==================================================================

  def start_server
    server = WEBrick::HTTPServer.new(
      Port: RELAY_PORT,
      Logger: WEBrick::Log.new("/dev/null"),
      AccessLog: []
    )

    # Hub -> Relay: deliver a message to Claude Code
    server.mount_proc("/message") do |req, res|
      if req.request_method == "POST"
        data = JSON.parse(req.body, symbolize_names: true)
        sender = data[:from] || data[:sender] || "unknown"
        content = data[:content] || ""

        # Invoke Claude Code with --continue (resumes conversation).
        # invoke_claude handles typing indicators.
        prompt = "@#{sender}: #{content}"
        Thread.new do
          response = @mutex.synchronize { invoke_claude(prompt) }

          unless response.empty?
            post_to_hub("/agent/message", {
              instance: @instance_name,
              content: response
            })
          end
        end

        res.status = 200
        res.body = '{"ok":true}'
      end
    end

    # Manager -> Relay: freeze/sunset signal
    server.mount_proc("/signal") do |req, res|
      if req.request_method == "POST"
        data = JSON.parse(req.body, symbolize_names: true)
        signal = data[:signal]

        log "Received signal: #{signal}"
        Thread.new { handle_signal(signal) }

        res.status = 200
        res.body = '{"ok":true}'
      end
    end

    # Health check
    server.mount_proc("/health") do |req, res|
      res.status = 200
      res.body = JSON.generate({
        instance: @instance_name,
        last_message_at: @last_message_at.iso8601,
        context_usage: @context_usage,
        processing: @processing,
        booting: @booting,
        booted: @booted
      })
    end

    trap("INT") { server.shutdown }
    trap("TERM") { server.shutdown }

    log "Relay listening on port #{RELAY_PORT}"
    server.start
  end

  # ==================================================================
  # Lifecycle — freeze, sunset
  # ==================================================================

  def handle_signal(signal)
    case signal.to_s
    when "freeze"
      handle_freeze("Push your work and commit. You're going idle. Another instance of you will pick up from your baton.")
    when "sunset"
      handle_freeze("Your context window is nearly full. Write your baton.json with current state and push everything. A fresh instance picks up next.")
    end
  end

  def handle_freeze(message)
    log "Handling freeze/sunset..."

    @mutex.synchronize { invoke_claude(message) }

    prune_and_push_session

    post_to_manager("/containers/#{@instance_name}/freeze_ready", {})
    log "Signaled FREEZE_READY to Manager"
  end

  def prune_and_push_session
    session_dir = "#{WORKSPACE}/.claude"
    return unless Dir.exist?(session_dir)

    sessions = Dir.glob("#{session_dir}/*.json").sort_by { |f| File.mtime(f) }
    return if sessions.empty?

    latest = sessions.last
    log "Pruning session: #{latest}"

    begin
      session_data = JSON.parse(File.read(latest))

      # Strip tool call results (they're huge and reconstructible)
      if session_data.is_a?(Array)
        pruned = session_data.map do |entry|
          if entry["type"] == "tool_result"
            entry.merge("content" => "[pruned]")
          else
            entry
          end
        end
      else
        pruned = session_data
      end

      sessions_dir = "#{WORKSPACE}/sessions/#{@channel}"
      FileUtils.mkdir_p(sessions_dir)
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      session_path = "#{sessions_dir}/#{@instance_name}-#{timestamp}.json"
      File.write(session_path, JSON.pretty_generate(pruned))

      Dir.chdir(WORKSPACE) do
        system("git", "add", "-A")
        system("git", "commit", "-m", "Session #{@instance_name} #{timestamp}")
        system("git", "push") or log("Push failed — session may be lost")
      end

      log "Session pushed: #{session_path}"
    rescue => e
      log "Session prune/push failed: #{e.message}"
    end
  end

  # ==================================================================
  # Health reporting
  # ==================================================================

  def start_health_thread
    Thread.new do
      while @running
        begin
          sleep HEALTH_INTERVAL
          post_to_manager("/containers/#{@instance_name}/health", {
            context_usage: @context_usage,
            last_message_at: @last_message_at.iso8601,
            booting: @booting,
            booted: @booted
          })
        rescue => e
          log "Health report failed: #{e.message}"
        end
      end
    end
  end

  # ==================================================================
  # HTTP clients — use stdlib Net::HTTP (no gem dependencies)
  # ==================================================================

  def post_to_hub(path, body)
    post_json("http://#{@hub_ip}:3100#{path}", body)
  end

  def post_to_manager(path, body)
    post_json("http://#{@manager_ip}:9200#{path}", body)
  end

  def forward_output(line)
    post_json(
      "http://#{@manager_ip}:9200/containers/#{@instance_name}/output",
      line,
      raw: true,
      silent: true
    )
  rescue
    # Don't let output forwarding failures disrupt the stream
  end

  def post_json(url, body, raw: false, silent: false)
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.open_timeout = 5
    http.read_timeout = 5
    req = Net::HTTP::Post.new(uri.path)
    req["Content-Type"] = "application/json"
    req.body = raw ? body : JSON.generate(body)
    http.request(req)
  rescue => e
    log "POST #{url} failed: #{e.message}" unless silent
  end

  def detect_hub_ip
    # Hub runs on the host at 10.0.0.2 in the new topology
    "10.0.0.2"
  end

  def detect_manager_ip
    # Manager is at 10.0.0.3
    "10.0.0.3"
  end

  # ==================================================================
  # Logging
  # ==================================================================

  def log(msg)
    $stderr.puts "[relay:#{@instance_name}] #{msg}"
    $stderr.flush
  end
end

# ==================================================================
# Entry point
# ==================================================================

if __FILE__ == $0
  unless File.exist?(SPAWN_FILE)
    $stderr.puts "No spawn file at #{SPAWN_FILE}"
    exit 1
  end

  relay = Relay.new
  relay.run
end
