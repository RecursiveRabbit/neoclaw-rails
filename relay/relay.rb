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
require "base64"

WORKSPACE   = "/workspace"
IDENTITY_DIR = "/identity"
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
    @boot_state = @spawn[:boot_state] || "fresh"
    @context_limit = detect_context_limit
    @hub_ip = detect_hub_ip
    @manager_ip = detect_manager_ip
    @running = true
    @booted = false
    @booting = false
    @processing = false
    @context_usage = 0.0
    @last_message_at = Time.now
    @message_count = 0
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
    narrate "Launching #{@instance_name}..."
    Thread.new do
      begin
        boot_claude_code
      rescue => e
        log "Boot failed: #{e.message}"
        log e.backtrace.first(5).join("\n")
        narrate "#{@instance_name} failed to start."
      ensure
        @booting = false
      end
    end
  end

  def boot_clone_url
    git_conf = @spawn[:git] || {}
    forge = @spawn.dig(:services, :forgejo) || {}
    repo = forge[:workspace_repo] || git_conf[:repo] || "#{@identity}/workspace"

    # Preferred path: explicit SSH clone URL for context repo.
    explicit = forge[:workspace_clone_url].to_s
    return explicit unless explicit.empty?

    # Fallback: HTTP clone URL
    forge_url = git_conf[:forge_url] || forge[:forge_url] || "http://#{detect_hub_ip}:3000"
    forge_user = forge[:forge_user]
    if forge_user && !forge_user.empty?
      uri = URI.parse(forge_url)
      uri.user = forge_user
      "#{uri}/#{repo}.git"
    else
      "#{forge_url}/#{repo}.git"
    end
  end

  BATON_PATH_TEMPLATE = "#{WORKSPACE}/sessions/%s/baton.json"
  IDENTITY_BATON_PATH_TEMPLATE = "#{IDENTITY_DIR}/sessions/%s/baton.json"

  def boot_claude_code
    if File.exist?(File.join(WORKSPACE, ".git"))
      # Hot swap — workspace and session preserved from previous pod.
      log "Hot swap detected — workspace exists, resuming session"
      narrate "Agent resuming session..."
      swap_prompt = [
        "You were hot-swapped to a new container image.",
        "Your workspace and conversation history are intact.",
        "New capabilities may be available (check MCP tools).",
        "Continue where you left off.",
      ].join("\n")
      response = @mutex.synchronize { invoke_claude(swap_prompt, continue: true) }
    else
      # Cold boot — three prompts based on boot state.
      clone_url = boot_clone_url
      baton_path = @spawn[:channel_repo] ?
        IDENTITY_BATON_PATH_TEMPLATE % @channel :
        BATON_PATH_TEMPLATE % @channel

      channel_repo = @spawn[:channel_repo]

      if channel_repo
        # Two repos: personal identity repo + shared project repo
        preamble = [
          "You have just been instantiated as #{@identity} in channel ##{@channel}.",
          "Your text output IS your voice in the channel — when you write text, it appears as a message from you. Do not use Matrix, SSH, or any other tool to reply. Just speak.",
          "",
          "Clone your personal repo first:",
          "  git clone #{clone_url} #{IDENTITY_DIR}",
          "Read #{IDENTITY_DIR}/identity.json to learn who you are.",
          "",
          "Then clone the project repo:",
          "  git clone #{channel_repo[:channel_repo_url]} #{WORKSPACE}",
          "#{IDENTITY_DIR} is your personal repo — identity, baton, sessions.",
          "#{WORKSPACE} is the shared project — all agents in ##{@channel} collaborate here.",
          "Do your work in #{WORKSPACE}. Push both repos before you go.",
        ]
      else
        # Single repo: personal workspace only
        preamble = [
          "You have just been instantiated as #{@identity} in channel ##{@channel}.",
          "Your text output IS your voice in the channel — when you write text, it appears as a message from you. Do not use Matrix, SSH, or any other tool to reply. Just speak.",
          "Your workspace is empty. Clone your repo:",
          "  git clone #{clone_url} #{WORKSPACE}",
          "Then read #{WORKSPACE}/identity.json to learn who you are.",
          "Push your work before you go.",
        ]
      end

      case @boot_state
      when "fresh"
        narrate "Agent orienting (first time in ##{@channel})..."
        boot_prompt = preamble + [
          "This is your first time in ##{@channel}. Orient yourself, then respond in the channel — someone is waiting.",
        ]
      when "resume"
        narrate "Agent resuming in ##{@channel}..."
        boot_prompt = preamble + [
          "You are resuming a previous session in ##{@channel}.",
          "Read #{baton_path} — you left it for yourself.",
          "Orient yourself, then respond in the channel — someone is waiting.",
        ]
      when "baton"
        narrate "Agent picking up baton in ##{@channel}..."
        boot_prompt = preamble + [
          "Your previous session in ##{@channel} hit the context limit.",
          "Read #{baton_path} — you left it for yourself. The previous session is too large to resume.",
          "Orient yourself, then respond in the channel — someone is waiting.",
        ]
      end

      log "Cold boot (#{@boot_state}) — cloning workspace"
      response = @mutex.synchronize { invoke_claude(boot_prompt.join("\n"), continue: false) }
    end

    # Deliver the agent's first words — this used to be thrown away.
    unless response.nil? || response.empty?
      post_to_hub("/agent/message", {
        instance: @instance_name,
        content: response
      })
    end

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

  # Run claude -p with a prompt. Streams output to Matrix as it arrives.
  # If continue: true, resumes the previous conversation.
  # Caller must hold @mutex.
  # If stream_to_hub is true, sends each assistant message to Matrix immediately.
  def invoke_claude(prompt, continue: true, stream_to_hub: false)
    @processing = true
    @last_message_at = Time.now

    # Forward the prompt to the stream so the transcript makes sense
    forward_output(JSON.generate({ type: "prompt", content: prompt }))

    # Typing indicator: re-send every 20s while claude runs.
    # Matrix expires typing after 30s, so 20s keeps it alive.
    typing_thread = start_typing_keepalive

    cmd = [
      "claude",
      "--model", @model,
      "--output-format", "stream-json",
      "--verbose",
      "--dangerously-skip-permissions",
    ]

    # Always pass MCP config — on fresh and continue invocations.
    # MCP server processes can die mid-session (crash, OOM, idle timeout).
    # Passing --mcp-config on --continue ensures dead servers get restarted.
    mcp_config = File.join(Dir.home, ".claude", "mcp.json")
    cmd.push("--mcp-config", mcp_config) if File.exist?(mcp_config)

    cmd.push("-p", prompt)
    cmd << "--continue" if continue

    log "Invoking: #{continue ? '--continue' : 'fresh'} (#{prompt.length} chars)"

    response_text = []

    # No uid switching needed — entrypoint.sh already dropped to agent user.
    # No unsetenv_others — inherit the normal agent environment.
    Open3.popen3(*cmd, chdir: File.exist?(WORKSPACE) ? WORKSPACE : Dir.home) do |stdin, stdout, stderr, wait_thread|
      @claude_pid = wait_thread.pid
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

            # Send each assistant message to Matrix as it arrives
            if stream_to_hub && !text_parts.empty?
              text = text_parts.join("\n")
              post_to_hub("/agent/message", {
                instance: @instance_name,
                content: text
              })
            end

            # Track context usage
            if event.dig(:message, :usage)
              input_t = event.dig(:message, :usage, :input_tokens) || 0
              output_t = event.dig(:message, :usage, :output_tokens) || 0
              @context_usage = (input_t + output_t).to_f / @context_limit
            end

          when "result"
            if event[:usage]
              input_t = event.dig(:usage, :input_tokens) || 0
              output_t = event.dig(:usage, :output_tokens) || 0
              @context_usage = (input_t + output_t).to_f / @context_limit
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
    typing_thread&.kill
    post_to_hub("/agent/event", { instance: @instance_name, event: "done_typing" })

    full_response = response_text.join("\n")
    log "Response: #{full_response.length} chars"
    full_response
  end

  def start_typing_keepalive
    Thread.new do
      loop do
        sleep 20
        if claude_running?
          post_to_hub("/agent/event", { instance: @instance_name, event: "typing" })
        else
          break
        end
      end
      # Claude died without invoke_claude returning — clean up
      unless @processing == false
        @processing = false
        post_to_hub("/agent/event", { instance: @instance_name, event: "done_typing" })
        narrate "Agent process exited unexpectedly."
        log "Typing watchdog: claude process gone, cleared typing"
      end
    rescue => e
      log "Typing watchdog error: #{e.message}"
    end
  end

  def claude_running?
    Dir.glob("/proc/*/cmdline").any? do |f|
      File.read(f).include?("claude") rescue false
    end
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
        attachments = data[:attachments] || []
        @message_count += 1

        # Save attachments to disk so Claude can read them
        log "Message from #{sender}: #{attachments.size} attachment(s)" if attachments.any?
        saved_paths = save_attachments(attachments)

        # Build prompt with attachment references
        prompt = "@#{sender}: #{content}"
        unless saved_paths.empty?
          file_list = saved_paths.map { |p| "  #{p}" }.join("\n")
          prompt += "\n\n[Attached files — use the Read tool to view them]\n#{file_list}"
        end

        Thread.new do
          # stream_to_hub: true sends each assistant message to Matrix
          # as it arrives instead of buffering until the end.
          @mutex.synchronize { invoke_claude(prompt, stream_to_hub: true) }
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
        message_count: @message_count,
        context_usage: @context_usage,
        processing: @processing,
        booting: @booting,
        booted: @booted
      })
    end

    trap("INT") { cleanup_mcp_processes; server.shutdown }
    trap("TERM") { cleanup_mcp_processes; server.shutdown }

    log "Relay listening on port #{RELAY_PORT}"
    server.start
  end

  # ==================================================================
  # Lifecycle — freeze, sunset
  # ==================================================================

  def handle_signal(signal)
    baton_path = @spawn[:channel_repo] ?
      IDENTITY_BATON_PATH_TEMPLATE % @channel :
      BATON_PATH_TEMPLATE % @channel
    case signal.to_s
    when "freeze"
      narrate "Agent entering idle status..."
      handle_freeze("Push your work and commit. You're going idle. Write your baton to #{baton_path} — another instance of you will pick up from it.")
    when "sunset"
      narrate "Context limit reached, sunsetting agent..."
      handle_freeze("Your context window is nearly full. Write your baton to #{baton_path} with current state and push everything. A fresh instance picks up next.")
    when "stop"
      handle_stop
    when "update_baton"
      handle_update_baton(baton_path)
    end
  end

  def handle_update_baton(baton_path)
    log "Baton update requested"
    @mutex.synchronize do
      invoke_claude(
        "Write your current state to #{baton_path} — what you're working on, " \
        "what's done, what's unresolved, what the next instance should know. " \
        "Commit and push. Then continue what you were doing."
      )
    end
    log "Baton updated"
  end

  def handle_stop
    log "Stop signal received — killing claude process"
    if @claude_pid
      Process.kill("TERM", @claude_pid) rescue nil
      sleep 2
      Process.kill("KILL", @claude_pid) rescue nil
      log "Claude process #{@claude_pid} terminated"
    end
    @processing = false
    cleanup_mcp_processes
    post_to_hub("/agent/event", { instance: @instance_name, event: "done_typing" })
  end

  # Kill orphaned MCP server processes. Claude Code spawns Python MCP
  # servers as children, but they outlive Claude when it exits. Left
  # alone they accumulate — one set per invocation that crashed or
  # was stopped. Tini reaps zombies but doesn't kill orphans.
  def cleanup_mcp_processes
    killed = 0
    Dir.glob("/proc/*/cmdline").each do |f|
      begin
        cmdline = File.read(f).tr("\0", " ")
        next unless cmdline.include?("/opt/mcp/") || cmdline.include?("/opt/mcp-env/")
        pid = f.split("/")[2].to_i
        next if pid == Process.pid
        Process.kill("TERM", pid)
        killed += 1
      rescue Errno::ENOENT, Errno::ESRCH, Errno::EACCES
        # Process already gone or not ours
      end
    end
    log "Cleaned up #{killed} orphaned MCP processes" if killed > 0
  end

  def handle_freeze(message)
    log "Handling freeze/sunset..."

    @mutex.synchronize { invoke_claude(message) }

    prune_and_push_session
    cleanup_mcp_processes

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

      # Sessions are personal state — save in the identity repo when
      # there's a channel repo, otherwise in the workspace.
      save_root = @spawn[:channel_repo] && Dir.exist?(IDENTITY_DIR) ? IDENTITY_DIR : WORKSPACE
      sessions_dir = "#{save_root}/sessions/#{@channel}"
      FileUtils.mkdir_p(sessions_dir)
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      session_path = "#{sessions_dir}/#{@instance_name}-#{timestamp}.json"
      File.write(session_path, JSON.pretty_generate(pruned))

      Dir.chdir(save_root) do
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

  # Save base64-encoded attachments to disk. Returns array of file paths.
  def save_attachments(attachments)
    return [] if attachments.nil? || attachments.empty?

    dir = File.join(WORKSPACE, "attachments")
    FileUtils.mkdir_p(dir)

    attachments.filter_map do |att|
      filename = att[:filename] || "attachment"
      data = att[:data]
      next unless data

      # Sanitize filename
      safe_name = "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{filename.gsub(/[^\w.\-]/, '_')}"
      path = File.join(dir, safe_name)

      File.open(path, "wb") { |f| f.write(Base64.decode64(data)) }
      log "Saved attachment: #{path} (#{File.size(path)} bytes)"
      path
    end
  rescue => e
    log "Failed to save attachments: #{e.message}"
    []
  end

  # Send a narration message to Matrix via the Hub.
  # Appears as m.notice (dimmed/italic) — system speech, not the agent's voice.
  def narrate(message)
    post_to_hub("/agent/message", {
      instance: @instance_name,
      content: message,
      msgtype: "m.notice"
    })
  rescue => e
    log "Narration failed: #{e.message}"
  end

  def post_to_hub(path, body)
    # Always include identity and channel so the Hub can puppet
    # even if its route cache was cleared by a restart.
    body[:identity] ||= @identity
    body[:channel] ||= @channel
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

  # Context window size for the active model. Used to compute context_usage
  # as a 0.0–1.0 ratio for health reports. Reads from spawn.json if set,
  # otherwise looks up by model name.
  MODEL_CONTEXT_LIMITS = {
    "claude-opus-4-6"     => 200_000,
    "claude-sonnet-4-6"   => 200_000,
    "claude-haiku-4-5"    => 200_000,
  }.freeze

  def detect_context_limit
    # Explicit override in spawn.json takes priority
    limit = @spawn[:context_limit]
    return limit if limit.is_a?(Integer) && limit > 0

    MODEL_CONTEXT_LIMITS[@model] || 200_000
  end

  def detect_hub_ip
    @spawn.dig(:network, :hub_ip) || "10.0.0.2"
  end

  def detect_manager_ip
    @spawn.dig(:network, :manager_ip) || "10.0.0.3"
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
