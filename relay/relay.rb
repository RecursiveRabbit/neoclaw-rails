#!/usr/bin/env ruby
# The Relay — lives inside every agent container.
#
# Configures WireGuard, prepares git credentials, runs Claude Code,
# pipes messages, reports health, handles freeze/sunset.
#
# Claude Code is invoked per-message, not as a long-running process.
# Each message is: claude -p "message" --continue --output-format stream-json
# The first invocation (boot) has no --continue. Subsequent messages resume.
#
# This is the entire agent-side runtime. One file. No framework.

require "webrick"
require "httpx"
require "json"
require "open3"
require "fileutils"
require "securerandom"
require "shellwords"

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
    @processing = false
    @context_usage = 0.0
    @last_message_at = Time.now
    @mutex = Mutex.new
  end

  def run
    configure_wireguard
    prepare_agent
    boot_claude_code
    signal_ready
    start_health_thread
    start_server  # blocks
  end

  private

  # ==================================================================
  # Boot sequence
  # ==================================================================

  def configure_wireguard
    log "Configuring WireGuard..."
    wg_conf = build_wg_config
    File.write("/etc/wireguard/wg0.conf", wg_conf)
    system("wg-quick", "up", "wg0") or raise "WireGuard failed to start"
    log "WireGuard up. Address: #{@spawn[:network][:wg_address]}"
  end

  def build_wg_config
    net = @spawn[:network]
    conf = <<~WG
      [Interface]
      PrivateKey = #{net[:wg_private_key]}
      Address = #{net[:wg_address]}/32
    WG

    (net[:peers] || []).each do |peer|
      conf += <<~PEER

        [Peer]
        PublicKey = #{peer[:public_key]}
        Endpoint = #{peer[:endpoint]}
        AllowedIPs = #{peer[:allowed_ips]}
        PersistentKeepalive = 25
      PEER
    end

    conf
  end

  def prepare_agent
    # Set up git, SSH, Claude credentials, and permissions for the agent user.
    # The relay runs as root for WG, but Claude Code runs as 'agent'.
    log "Preparing agent environment..."
    git_conf = @spawn[:git]
    agent_home = "/home/agent"
    claude_dir = "#{agent_home}/.claude"
    FileUtils.mkdir_p(claude_dir)

    # --- Claude credentials ---
    # Copied from the host's credentials (mounted as secret or env)
    if File.exist?("/run/secrets/claude-credentials")
      FileUtils.cp("/run/secrets/claude-credentials", "#{claude_dir}/.credentials.json")
    elsif ENV["CLAUDE_CREDENTIALS"]
      File.write("#{claude_dir}/.credentials.json", ENV["CLAUDE_CREDENTIALS"])
    end
    File.chmod(0600, "#{claude_dir}/.credentials.json") if File.exist?("#{claude_dir}/.credentials.json")

    # --- Claude settings: auto-accept all permissions ---
    File.write("#{claude_dir}/settings.json", JSON.pretty_generate({
      permissions: {
        allow: [
          "Bash(*)", "Read(*)", "Write(*)", "Edit(*)",
          "Glob(*)", "Grep(*)", "WebFetch(*)", "WebSearch(*)"
        ],
        deny: []
      }
    }))

    # --- Git identity ---
    system("su", "-", "agent", "-c", "git config --global user.name '#{@identity}'")
    system("su", "-", "agent", "-c", "git config --global user.email '#{@identity}@neoclaw.local'")

    # --- SSH key for git push/pull ---
    if git_conf[:ssh_key] && !git_conf[:ssh_key].empty?
      ssh_dir = "#{agent_home}/.ssh"
      FileUtils.mkdir_p(ssh_dir)
      File.write("#{ssh_dir}/id_ed25519", git_conf[:ssh_key])
      File.chmod(0600, "#{ssh_dir}/id_ed25519")
      File.write("#{ssh_dir}/config", "Host *\n  IdentityFile #{ssh_dir}/id_ed25519\n  StrictHostKeyChecking no\n")
      system("chown", "-R", "agent:agent", ssh_dir)
      log "SSH key installed"
    end

    # Own everything
    system("chown", "-R", "agent:agent", claude_dir)
    system("chown", "-R", "agent:agent", agent_home)

    log "Agent environment ready"
  end

  def boot_claude_code
    # The boot prompt. The agent wakes up in an empty room.
    # Cloning is the first act of every life.
    git_conf = @spawn[:git]
    repo = git_conf[:repo] || "#{@identity}/workspace"
    forge_url = git_conf[:forge_url] || "http://10.0.0.3:3000"
    clone_url = "#{forge_url}/#{repo}.git"

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
    invoke_claude(boot_prompt, continue: false)
    @booted = true
    log "Agent booted"
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
  def invoke_claude(prompt, continue: true)
    @processing = true
    @last_message_at = Time.now

    cmd = [
      "claude",
      "--model", @model,
      "--output-format", "stream-json",
      "--verbose",
      "--dangerously-skip-permissions",
      "-p", prompt,
    ]
    cmd << "--continue" if continue

    log "Invoking: #{continue ? '--continue' : 'fresh'} (#{prompt.length} chars)"

    response_text = []

    # Run as agent user (uid 1000) — relay is root for WG,
    # but Claude Code must not run as root.
    # Auth comes from ~/.claude/.credentials.json (set up in prepare_agent).
    env = {
      "HOME" => "/home/agent",
      "USER" => "agent",
      "PATH" => ENV["PATH"],
    }

    Open3.popen3(env, *cmd, chdir: WORKSPACE, uid: 1000, gid: 1000, unsetenv_others: true) do |stdin, stdout, stderr, wait_thread|
      stdin.close

      stderr_thread = Thread.new do
        stderr.each_line { |line| log "claude: #{line.strip}" }
      rescue IOError
        # expected when process exits
      end

      stdout.each_line do |line|
        line = line.strip
        next if line.empty?

        # Forward raw stream-json to Manager for live UI
        post_to_manager("/containers/#{@instance_name}/output", line)

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
            # Turn complete
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

    # Hub → Relay: deliver a message to Claude Code
    server.mount_proc("/message") do |req, res|
      if req.request_method == "POST"
        data = JSON.parse(req.body, symbolize_names: true)
        sender = data[:from] || data[:sender] || "unknown"
        content = data[:content] || ""

        # Tell Hub we're typing
        post_to_hub("/agent/event", {
          instance: @instance_name,
          event: "typing"
        })

        # Invoke Claude Code with --continue (resumes conversation)
        prompt = "@#{sender}: #{content}"
        Thread.new do
          response = @mutex.synchronize { invoke_claude(prompt) }

          # Send response back to Hub
          unless response.empty?
            post_to_hub("/agent/message", {
              instance: @instance_name,
              content: response
            })
          end

          post_to_hub("/agent/event", {
            instance: @instance_name,
            event: "done_typing"
          })
        end

        res.status = 200
        res.body = '{"ok":true}'
      end
    end

    # Manager → Relay: freeze/sunset signal
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

    # Tell Claude Code to wrap up (this is a --continue invocation)
    @mutex.synchronize { invoke_claude(message) }

    # Prune and push the session transcript
    prune_and_push_session

    # Signal ready to freeze
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

      # Write pruned session to the repo
      sessions_dir = "#{WORKSPACE}/sessions/#{@channel}"
      FileUtils.mkdir_p(sessions_dir)
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      session_path = "#{sessions_dir}/#{@instance_name}-#{timestamp}.json"
      File.write(session_path, JSON.pretty_generate(pruned))

      # Git add, commit, push
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
            last_message_at: @last_message_at.iso8601
          })
        rescue => e
          log "Health report failed: #{e.message}"
        end
      end
    end
  end

  # ==================================================================
  # HTTP clients
  # ==================================================================

  def post_to_hub(path, body)
    url = "http://#{@hub_ip}:3100#{path}"
    HTTPX.post(url, json: body)
  rescue => e
    log "Hub POST #{path} failed: #{e.message}"
  end

  def post_to_manager(path, body)
    url = "http://#{@manager_ip}:9200#{path}"
    if body.is_a?(String)
      HTTPX.post(url, body: body, headers: { "Content-Type" => "application/json" })
    else
      HTTPX.post(url, json: body)
    end
  rescue => e
    log "Manager POST #{path} failed: #{e.message}"
  end

  def detect_hub_ip
    @spawn.dig(:network, :peers)&.find { |p|
      p[:allowed_ips]&.start_with?("10.0.0.1")
    }&.dig(:allowed_ips)&.split("/")&.first || "10.0.0.1"
  end

  def detect_manager_ip
    "10.0.0.2"
  end

  # ==================================================================
  # Logging
  # ==================================================================

  def log(msg)
    $stderr.puts "[relay:#{@instance_name}] #{msg}"
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
