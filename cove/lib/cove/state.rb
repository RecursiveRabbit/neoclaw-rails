require "pathname"
require "yaml"
require "securerandom"

# Cove — the small namespace everything in the Manager lives in.
#
# The whole durable state of this system is a handful of text files. These
# methods are the only places that know where they are.
module Cove
  # The attributes a sheet knows by name. Everything else in the file is carried
  # through untouched (law 2) — this list is what the *Manager* has an opinion
  # about, not what a sheet may contain.
  SHEET_KEYS = %w[name kind harness model repo image command tools services listen pod_ip pubkey].freeze

  class << self
    # COVE_STATE lets the app be pointed at a throwaway directory (tests, a
    # scratch instance) without touching the real sheets.
    def state_dir
      @state_dir ||= Pathname.new(ENV.fetch("COVE_STATE") { Rails.root.join("state").to_s })
    end

    def state_dir=(path)
      @state_dir = Pathname.new(path.to_s)
    end

    def agents_dir = state_dir.join("agents")
    def services_file = state_dir.join("services.yml")
    def router_file = state_dir.join("router.conf")
    def wants_file = state_dir.join("relay-wants.jsonl")
    # How this process becomes able to touch the host's network. It is `sudo -E`
    # and not plain `sudo`, measured the hard way: sudo resets the environment, and
    # CONTAINER_HOST is the only thing telling podman to talk to the host's store
    # instead of opening its own (which, inside a container, cannot even configure
    # storage). A deployment that runs the Manager as root already sets COVE_SUDO="".
    def sudo_prefix = (@sudo_prefix ||= ENV.fetch("COVE_SUDO", "sudo -E").split.freeze)

    def plan_file = state_dir.join("plan.yml")
    def keys_dir = state_dir.join("keys")

    # Write a file whole, atomically, in the same directory: temp file, fsync,
    # rename, fsync the directory. A reader either sees the old file or the new
    # one, never half of either. This is the only write path in the system, used
    # by the sheet writer and the router renderer alike.
    def write_atomic(path, content)
      path = Pathname.new(path.to_s)
      path.dirname.mkpath
      tmp = path.dirname.join(".#{path.basename}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp")
      begin
        File.open(tmp, "wb") do |f|
          f.write(content)
          f.flush
          f.fsync
        end
        File.rename(tmp.to_s, path.to_s)
        begin
          dir = File.open(path.dirname.to_s)
          dir.fsync
          dir.close
        rescue StandardError
          # Directory fsync is not available on every filesystem; the rename is
          # the part that matters for atomicity.
        end
      ensure
        File.unlink(tmp.to_s) if File.exist?(tmp.to_s)
      end
      path
    end

    def yaml_load(path)
      return nil unless File.exist?(path)
      YAML.safe_load(File.read(path), permitted_classes: [Symbol, Time], aliases: false) || {}
    rescue Psych::SyntaxError => e
      raise Cove::DocumentError, "#{path}: #{e.message}"
    end

    # A slug is derived from a name once, at creation, and then it is the
    # identity: file name, pod name, URL. Never re-derived on edit, or renaming
    # an agent would orphan its pod.
    def slugify(name)
      s = name.to_s.strip.downcase
      s = s.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
      s = "agent-#{SecureRandom.hex(2)}" if s.empty?
      s
    end

    def valid_slug?(slug)
      slug.to_s.match?(/\A[a-z0-9][a-z0-9-]{0,38}[a-z0-9]\z/)
    end
  end

  class DocumentError < StandardError; end
end
