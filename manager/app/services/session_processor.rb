# Session processing pipeline.
#
# Two paths, one goal: no session is lost, every session has metadata.
#
# Normal path (freeze/sunset):
#   The relay already prunes and pushes. We record structured metadata
#   in the audit log and write a sidecar .meta.json via podman exec.
#
# Crash path:
#   The relay didn't run. Lifecycle.rescue! copied raw files out.
#   We process the session locally: strip tool results, detect baton
#   staleness, write metadata. No git push (credentials died with the pod).
#
# Metadata tracks: ended_reason, context_usage, duration, timestamps,
# baton_stale flag. Everything needed to understand what happened.

class SessionProcessor
  class << self
    # Called on normal freeze/sunset — pod is still alive.
    # The relay already pruned and pushed the session.
    # We add structured metadata.
    def process(container, ended_reason:)
      metadata = build_metadata(container, ended_reason: ended_reason)

      # Write metadata sidecar inside the pod (relay already pushed the session).
      # The sidecar lands next to the session file. Next git push picks it up.
      write_metadata_to_pod(container, metadata)

      AuditLog.record("SESSION_PROCESSED",
        instance_name: container.instance_name,
        identity: container.identity,
        detail: metadata.to_json)

      Rails.logger.info "SessionProcessor: #{container.instance_name} (#{ended_reason})"
      metadata
    rescue => e
      Rails.logger.error "SessionProcessor: #{container.instance_name} failed: #{e.message}"
      # Never block teardown — metadata is best-effort
      nil
    end

    # Called on crash/rescue — pod may be dead.
    # Raw files were rescued to rescue_path by Lifecycle.rescue!
    # We process the session locally since the relay never ran.
    def process_crash(container, rescue_path:)
      metadata = build_metadata(container, ended_reason: "crash")

      # Find the raw Claude session file in the rescue
      claude_dir = File.join(rescue_path, "claude")
      session_files = Dir.glob(File.join(claude_dir, "*.json")).sort_by { |f| File.mtime(f) } rescue []

      if session_files.any?
        latest = session_files.last
        metadata[:baton_stale] = baton_stale?(container, rescue_path, latest)

        processed_path = process_session_file(latest, container, rescue_path)
        metadata[:session_path] = processed_path if processed_path

        Rails.logger.info "SessionProcessor: crash session processed for #{container.instance_name}"
      else
        Rails.logger.warn "SessionProcessor: no session files found for #{container.instance_name}"
      end

      # Write metadata alongside the rescue
      meta_path = File.join(rescue_path, "session.meta.json")
      File.write(meta_path, JSON.pretty_generate(metadata))

      AuditLog.record("SESSION_PROCESSED",
        instance_name: container.instance_name,
        identity: container.identity,
        detail: metadata.to_json)

      metadata
    rescue => e
      Rails.logger.error "SessionProcessor: crash processing failed for #{container.instance_name}: #{e.message}"
      nil
    end

    private

    def build_metadata(container, ended_reason:)
      {
        instance_name: container.instance_name,
        identity: container.identity,
        channel: container.channel,
        ended_reason: ended_reason,
        context_usage: container.context_usage,
        duration_seconds: container.uptime.to_i,
        message_count: count_messages(container),
        last_message_at: container.last_message_at&.iso8601,
        started_at: container.created_at&.iso8601,
        ended_at: Time.current.iso8601
      }
    end

    # Approximate message count from the stream buffer.
    def count_messages(container)
      StreamBuffer.history(container.instance_name).size
    rescue
      0
    end

    # Write a metadata sidecar into the still-running pod via podman cp.
    # The file goes next to the session archive in sessions/<channel>/.
    def write_metadata_to_pod(container, metadata)
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      meta_filename = "#{container.instance_name}-#{timestamp}.meta.json"
      sessions_dir = "/workspace/sessions/#{container.channel}"

      # Write to temp file, podman cp in (avoids shell escaping issues)
      Dir.mktmpdir do |tmpdir|
        local_path = File.join(tmpdir, meta_filename)
        File.write(local_path, JSON.pretty_generate(metadata))

        # Ensure dir exists in pod
        podman_exec(container, "mkdir", "-p", sessions_dir)

        # Copy metadata file into pod
        podman_cmd("cp", local_path, "#{container.instance_name}:#{sessions_dir}/#{meta_filename}")

        # Fix ownership
        podman_exec(container, "chown", "agent:agent", "#{sessions_dir}/#{meta_filename}")

        # Commit and push via the agent user
        podman_exec_as_agent(container,
          "cd /workspace && git add sessions/ && git commit -m 'Session metadata #{timestamp}' && git push")
      end
    rescue => e
      Rails.logger.warn "SessionProcessor: metadata write to pod failed: #{e.message}"
    end

    def podman_exec(container, *args)
      cmd = ["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
             "exec", container.instance_name] + args
      IO.popen(cmd, err: [:child, :out]) { |io| io.read }
    end

    def podman_exec_as_agent(container, shell_cmd)
      cmd = ["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
             "exec", "-u", "agent", container.instance_name,
             "bash", "-c", shell_cmd]
      IO.popen(cmd, err: [:child, :out]) { |io| io.read }
    end

    def podman_cmd(*args)
      cmd = ["podman", "--remote", "--url", "unix://#{Surface.podman_socket}"] + args
      IO.popen(cmd, err: [:child, :out]) { |io| io.read }
    end

    # Process a raw Claude session file — strip tool results, save processed version.
    def process_session_file(session_path, container, rescue_path)
      data = JSON.parse(File.read(session_path))

      # Strip tool results (they're huge and reconstructible)
      if data.is_a?(Array)
        data = data.map do |entry|
          if entry["type"] == "tool_result"
            entry.merge("content" => "[pruned]")
          else
            entry
          end
        end
      end

      # Save processed session to the rescue dir
      sessions_dir = File.join(rescue_path, "sessions", container.channel)
      FileUtils.mkdir_p(sessions_dir)
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      output_path = File.join(sessions_dir, "#{container.instance_name}-#{timestamp}.json")
      File.write(output_path, JSON.pretty_generate(data))

      output_path
    rescue => e
      Rails.logger.error "SessionProcessor: process_session_file failed: #{e.message}"
      nil
    end

    # Is the baton stale? If the baton file is older than the session,
    # the agent crashed after doing work but before updating the baton.
    # The next instance should know the baton may be incomplete.
    def baton_stale?(container, rescue_path, session_path)
      baton_path = File.join(rescue_path, "workspace", "sessions", container.channel, "baton.json")
      return false unless File.exist?(baton_path) && File.exist?(session_path)

      File.mtime(baton_path) < File.mtime(session_path)
    rescue
      false
    end
  end
end
