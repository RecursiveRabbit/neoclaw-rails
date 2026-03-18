# Podman interface — the Manager's one path to creating containers.
#
# Talks to podman via the mounted socket. Every container is the same
# stock image with a spawn.json mounted as a secret.

class Podman
  class << self
    def run(instance_name:, spawn_path:)
      # spawn_path is the Manager-internal path (e.g. /spawn/silas-test.json).
      # podman --remote executes on the HOST, so we translate to the host path.
      host_spawn_path = spawn_path.sub(Surface.spawn_dir, Surface.host_spawn_dir)

      args = [
        "podman", "--remote", "--url", "unix://#{Surface.podman_socket}",
        "run", "-d",
        "--name", instance_name,
        "--hostname", instance_name,
        "--network", Surface.agent_network,
        "-v", "#{host_spawn_path}:/run/secrets/spawn.json:ro",
        "-v", "#{Surface.host_claude_credentials}:/run/secrets/claude-credentials:ro",
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

    def run_cmd(args)
      IO.popen(args, err: [:child, :out]) { |io| io.read }
    end
  end
end
