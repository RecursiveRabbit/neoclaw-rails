#!/usr/bin/env ruby
# The Relay — lives inside every agent container.
#
# Reads spawn.json, configures WireGuard, starts Claude Code,
# pipes messages, reports health, handles freeze/sunset.
#
# This is the entire agent-side runtime. One file. No framework.

require "webrick"
require "httpx"
require "json"
require "open3"
require "fileutils"
require "securerandom"

WORKSPACE   = "/workspace"
SPAWN_FILE  = "/run/secrets/spawn.json"
RELAY_PORT  = 9300
HEALTH_INTERVAL = 30

class Relay
  attr_reader :spawn, :claude_process, :instance_name, :identity

  def initialize
    @spawn = JSON.parse(File.read(SPAWN_FILE), symbolize_names: true)
    @instance_name = @spawn[:instance]
    @identity = @spawn[:identity]
    @channel = @spawn[:channel]
    @model = @spawn[:model] || "claude-opus-4-6"
    @hub_ip = detect_hub_ip
    @manager_ip = detect_manager_ip
    @message_queue = Queue.new
    @running = true
    @context_usage = 0.0
    @last_message_at = Time.now
  end

  def run
    configure_wireguard
    clone_repo
    start_claude_code
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

  def clone_repo
    log "Cloning repo..."
    git_conf = @spawn[:git]

    # Write SSH key
    ssh_key_path = "/tmp/agent_ssh_key"
    File.write(ssh_key_path, git_conf[:ssh_key])
    File.chmod(0600, ssh_key_path)

    # Configure SSH to use the key
    ssh_config = "Host *\n  IdentityFile #{ssh_key_path}\n  StrictHostKeyChecking no\n"
    FileUtils.mkdir_p("#{Dir.home}/.ssh")
    File.write("#{Dir.home}/.ssh/config", ssh_config)

    # Clone
    forge_url = git_conf[:forge_url] || "ssh://git@#{@spawn[:network][:peers]&.first&.dig(:allowed_ips)&.split('/')&.first}"
    repo_url = "git@#{URI.parse(forge_url).host}:#{git_conf[:repo] || "#{@identity}/workspace"}.git"

    if Dir.exist?(WORKSPACE)
      system("git", "-C", WORKSPACE, "pull", "--ff-only") or
        log("Pull failed — starting fresh")
    end

    unless Dir.exist?("#{WORKSPACE}/.git")
      FileUtils.rm_rf(WORKSPACE)
      system("git", "clone", repo_url, WORKSPACE) or raise "Clone failed"
    end

    log "Repo ready at #{WORKSPACE}"
  end

  def start_claude_code
    log "Starting Claude Code..."

    # Build the system prompt that tells the agent who they are
    boot_prompt = [
      "You have just been instantiated as #{@identity} in channel ##{@channel}.",
      "Your workspace is #{WORKSPACE}.",
      "Read #{WORKSPACE}/identity.json to learn who you are.",
      "Read #{WORKSPACE}/baton.json to pick up where you left off.",
      "Read #{WORKSPACE}/memory/ for your accumulated memories.",
      "Orient yourself, then signal ready.",
    ].join(" ")

    cmd = [
      "claude",
      "--model", @model,
      "--output-format", "stream-json",
      "--verbose",
      "--dangerously-skip-permissions",
    ]

    @claude_stdin, @claude_stdout, @claude_stderr, @claude_process = Open3.popen3(
      { "ANTHROPIC_MODEL" => @model },
      *cmd,
      chdir: WORKSPACE
    )

    # Send the boot prompt
    send_to_claude(boot_prompt)

    # Start the output reader thread
    start_output_reader
    start_stderr_reader

    log "Claude Code started (PID #{@claude_process.pid})"
  end

  def signal_ready
    # The agent has booted — tell the Manager
    post_to_manager("/containers/#{@instance_name}/ready", {})
    log "Signaled READY to Manager"
  end

  # ==================================================================
  # Claude Code I/O
  # ==================================================================

  def send_to_claude(text)
    return unless @claude_stdin && !@claude_stdin.closed?
    @claude_stdin.puts(text)
    @claude_stdin.flush
    @last_message_at = Time.now
  rescue IOError => e
    log "Claude stdin error: #{e.message}"
  end

  def start_output_reader
    Thread.new do
      @claude_stdout.each_line do |line|
        line = line.strip
        next if line.empty?

        # Forward to Manager for streaming UI
        post_to_manager("/containers/#{@instance_name}/output", line)

        # Parse for responses to send back to Hub
        begin
          event = JSON.parse(line, symbolize_names: true)
          handle_claude_event(event)
        rescue JSON::ParserError
          # Not JSON — ignore
        end
      rescue IOError
        break
      end
      log "Claude stdout closed"
      @running = false
    end
  end

  def start_stderr_reader
    Thread.new do
      @claude_stderr.each_line do |line|
        log "Claude stderr: #{line.strip}"
      rescue IOError
        break
      end
    end
  end

  def handle_claude_event(event)
    case event[:type]
    when "assistant"
      # Extract text content and send to Hub
      content_blocks = event.dig(:message, :content) || []
      text_parts = content_blocks
        .select { |b| b[:type] == "text" }
        .map { |b| b[:text] }

      unless text_parts.empty?
        full_text = text_parts.join("\n")
        post_to_hub("/agent/message", {
          instance: @instance_name,
          content: full_text
        })
      end

      # Track context usage from the usage block
      if event.dig(:message, :usage)
        input = event.dig(:message, :usage, :input_tokens) || 0
        output = event.dig(:message, :usage, :output_tokens) || 0
        # Rough estimate: assume 200k context window
        @context_usage = (input + output).to_f / 200_000
      end

    when "result"
      # Conversation turn complete
      post_to_hub("/agent/event", {
        instance: @instance_name,
        event: "done_typing"
      })
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

        # Feed to Claude Code
        prompt = "@#{sender}: #{content}"
        send_to_claude(prompt)

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
        claude_code_alive: @claude_process&.alive? || false
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

    # Tell Claude Code to wrap up
    send_to_claude(message)

    # Wait for Claude Code to finish (up to 60 seconds)
    deadline = Time.now + 60
    while @claude_process&.alive? && Time.now < deadline
      sleep 2
    end

    # If Claude Code is still running, send a harder nudge
    if @claude_process&.alive?
      send_to_claude("/exit")
      sleep 5
    end

    # Prune and push the session transcript
    prune_and_push_session

    # Signal ready to freeze
    post_to_manager("/containers/#{@instance_name}/freeze_ready", {})
    log "Signaled FREEZE_READY to Manager"
  end

  def prune_and_push_session
    session_dir = "#{WORKSPACE}/.claude"
    return unless Dir.exist?(session_dir)

    # Find the most recent session file
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

  # ==================================================================
  # HTTP clients
  # ==================================================================

  def post_to_hub(path, body)
    url = "http://#{@hub_ip}:3000#{path}"
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
    # Hub is always at 10.0.0.1 per the network spec
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
