# Podman interface — the Manager's one path to creating containers.
#
# Talks to podman via the mounted socket. Every container is the same
# stock image with a spawn.json mounted as a secret.
#
# When a pod with the same name already exists (normal — agents get
# frozen and re-spawned), we rescue the workspace before removing it.
# The agent put effort into that context. We keep it.

class Podman
  class << self
    def run(instance_name:, spawn_path:)
      # spawn_path is the Manager-internal path (e.g. /spawn/silas-test.json).
      # podman --remote executes on the HOST, so we translate to the host path.
      host_spawn_path = spawn_path.sub(Surface.spawn_dir, Surface.host_spawn_dir)

      # A previous pod with this name may still exist (frozen, stopped,
      # or crashed). Rescue its workspace before removing it.
      rescue_and_remove(instance_name)

      args = [
        "podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
        "run", "-d",
        "--name", instance_name,
        "--hostname", instance_name,
        "--network", Surface.agent_network,
        "-v", "#{host_spawn_path}:/run/secrets/spawn.json:ro",
        "-v", "#{Surface.host_claude_dir}:/run/secrets/claude:ro",
        "--memory", "2g",
        "--cpus", "2",
        "--cap-add", "NET_ADMIN",
        Surface.agent_image
      ]

      output = run_cmd(args)
      container_id = output.strip
      raise "podman run failed: #{output}" if container_id.empty?

      container_id
    end

    def rm(container_id)
      run_cmd(["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
               "rm", "-f", container_id])
    end

    def cp(container_id, container_path)
      dir = Dir.mktmpdir
      host_path = File.join(dir, "recovered")
      run_cmd(["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
               "cp", "#{container_id}:#{container_path}", host_path])
      File.exist?(host_path) ? File.read(host_path) : nil
    rescue => e
      Rails.logger.error "podman cp failed: #{e.message}"
      nil
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    def inventory
      output = run_cmd(["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
                        "ps", "--format", "{{.Names}}\t{{.ID}}\t{{.Status}}"])
      output.lines.filter_map { |line|
        name, id, status = line.strip.split("\t")
        next unless name
        { name: name, id: id, status: status }
      }
    end

    private

    RESCUE_DIR = "/rescued"

    # Rescue the workspace from an existing pod, then remove it.
    # The agent's work matters. We copy it out before clearing the way.
    def rescue_and_remove(instance_name)
      # Check if the pod exists at all (running or stopped)
      inspect = run_cmd(["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
                         "inspect", "--format", "{{.State.Status}}", instance_name]).strip
      return if inspect.empty? || inspect.include?("no such")

      # Rescue workspace and session data
      timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
      rescue_path = File.join(Surface.host_rescue_dir, instance_name, timestamp)

      rescued = rescue_from_pod(instance_name, rescue_path)

      if rescued
        AuditLog.record("SESSION_RESCUED",
          instance_name: instance_name,
          detail: "Rescued to #{rescue_path} before re-spawn")

        HubClient.callback(
          event: "session_rescued",
          instance: instance_name,
          rescue_path: rescue_path
        )
      end

      # Now it's safe to remove
      run_cmd(["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
               "rm", "-f", instance_name])
    rescue => e
      # If rescue fails, still remove — we can't block spawns forever.
      # But log what happened so someone can investigate.
      Rails.logger.error "rescue_and_remove #{instance_name}: #{e.message}"
      run_cmd(["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
               "rm", "-f", instance_name]) rescue nil
    end

    # Copy workspace and .claude session out of a pod.
    # Returns true if anything was rescued.
    def rescue_from_pod(instance_name, rescue_path)
      rescued_anything = false

      ["/workspace", "/home/agent/.claude"].each do |container_path|
        subdir = container_path == "/workspace" ? "workspace" : "claude"
        host_dest = File.join(rescue_path, subdir)

        output = run_cmd(["podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
                          "cp", "#{instance_name}:#{container_path}/.", host_dest])

        # podman cp returns empty on success, error text on failure
        if output.strip.empty? || !output.include?("error")
          rescued_anything = true
          Rails.logger.info "Rescued #{container_path} from #{instance_name}"
        end
      end

      rescued_anything
    rescue => e
      Rails.logger.error "rescue_from_pod #{instance_name}: #{e.message}"
      false
    end

    def run_cmd(args)
      IO.popen(args, err: [:child, :out]) { |io| io.read }
    end
  end
end
