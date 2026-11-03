# frozen_string_literal: true

require "json"
require "fileutils"
require "open3"

# PodLifecycle — the Manager's podman control path.
#
# New-design Manager surface (spec §7): inventory and state inspection,
# start/stop/replace, exec for explicit lifecycle operations, logs and
# health evidence, and copying workspaces/sessions out for rescue.
#
# Everything here is argv-array exec of the podman CLI against the local
# socket — no shell, no Relay HTTP server, no pod-side agent. The Manager
# does not need a window into the pod beyond what podman already provides;
# this module is the narrow proof of that surface.

module PodLifecycle
  PODMAN = ENV.fetch("NEOCLAW_PODMAN", "podman")

  module_function

  # --- inventory / state -------------------------------------------------
  # Returns an Array of Hashes: name, id, state, status, started_at.
  def inventory(podman_args: [])
    out = run!(*podman_args, "ps", "-a", "--format", "{{json .}}")
    out.lines.map { |l| JSON.parse(l) }.map do |c|
      { "name" => [c["Names"], c["Name"]].flatten.compact.first,
        "id" => c["Id"] || c["ID"],
        "state" => c["State"],
        "status" => c["Status"],
        "image" => c["Image"],
        "started_at" => c["StartedAt"] }
    end
  end

  def exists?(name, podman_args: [])
    run(*podman_args, "container", "exists", name)
  end

  def running?(name, podman_args: [])
    return false unless exists?(name, podman_args:)
    out = run!(*podman_args, "inspect", name, "--format", "{{.State.Running}}")
    out.strip == "true"
  end

  # --- control -----------------------------------------------------------
  def start(name, podman_args: [])
    run!(*podman_args, "start", name)
    running?(name, podman_args:)
  end

  def stop(name, timeout: 30, podman_args: [])
    run!(*podman_args, "stop", "-t", timeout.to_s, name)
    !running?(name, podman_args:)
  end

  def replace(name, build_context:, image_tag:, podman_args: [])
    stop(name, podman_args:) if exists?(name, podman_args:)
    run!(*podman_args, "rm", name) if exists?(name, podman_args:)
    run!(*podman_args, "build", "-t", image_tag, build_context)
    run!(*podman_args, "run", "-d", "--name", name, image_tag)
    running?(name, podman_args:)
  end

  # --- inspection / evidence ----------------------------------------------
  def inspect(name, podman_args: [])
    JSON.parse(run!(*podman_args, "inspect", name)).first
  end

  def logs(name, tail: 100, podman_args: [])
    run!(*podman_args, "logs", "--tail", tail.to_s, name)
  end

  def exec(name, argv, podman_args: [])
    run!(*podman_args, "exec", name, *argv)
  end

  # --- rescue path (no Relay) ----------------------------------------------
  # Copies the pod's workspace/session volume content out to a host dir.
  def rescue_copy(name, container_path:, to:, podman_args: [])
    FileUtils.mkdir_p(to)
    run!(*podman_args, "cp", "#{name}:#{container_path}/.", to)
    Dir.glob("#{to}/**/*").select { |f| File.file?(f) }.map do |f|
      { "path" => f, "bytes" => File.size(f) }
    end
  end

  # --- helpers -------------------------------------------------------------
  def run(*argv)
    _out, _err, status = Open3.capture3(PODMAN, *argv)
    status.success?
  end

  def run!(*argv)
    out, err, status = Open3.capture3(PODMAN, *argv)
    raise "podman #{argv.join(' ')} failed (#{status.exitstatus}): #{err.strip}" unless status.success?

    out
  end
end

