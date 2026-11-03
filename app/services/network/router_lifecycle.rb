# frozen_string_literal: true

require "tmpdir"
require_relative "renderer"

module Network
  # Manager-side Router lifecycle. The Manager replaces the Router from
  # desired state — there is no Router API and no registration protocol.
  #
  # An ordinary roll renders the same state into a fresh config directory
  # and starts a new container with it. The Router's IP, WireGuard key,
  # and peer set come out identical because they are read from the same
  # Manager-held state. The old container is removed after the new one
  # applies its instructions.
  class RouterLifecycle
    class Error < StandardError; end

    def initialize(state, runner: nil)
      @state = state
      @run = runner || method(:system!)
    end

    # Renders desired state for the Router into a fresh directory.
    # Caller mounts it read-only at /etc/neoclaw.
    def render_config_dir(base_dir = nil)
      base_dir ||= Dir.mktmpdir("neoclaw-router-")
      Renderer.new(@state).render_router_config(base_dir)
      base_dir
    end

    # The roll itself is exercised by the container runtime
    # (test/slice/network/run.sh for the slice). This module exists so the
    # Manager's desired state is the single input; both the initial run and
    # the replacement consume exactly render_config_dir's output.
    def roll!(image:, name: "neoclaw-router", extra_run_args: [], base_dir: nil)
      dir = render_config_dir(base_dir)
      args = ["podman", "run", "-d", "--name", name,
              "--replace",
              "--cap-add", "NET_ADMIN",
              "--sysctl", "net.ipv4.ip_forward=1",
              "-v", "#{dir}:/etc/neoclaw:ro",
              *extra_run_args, image]
      out = @run.call(args)
      [out, dir]
    end

    private

    def system!(argv)
      require "open3"
      out, err, st = Open3.capture3(*argv.map(&:to_s))
      raise Error, "command failed: #{argv.join(' ')}\n#{err}" unless st.success?
      out
    end
  end
end
