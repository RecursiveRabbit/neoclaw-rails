require "open3"
require "json"
require "timeout"

# Podman is one of exactly two data sources in this build, and the only one
# that can *change* the world.
#
# Split by tense (the pass's D3):
#   podman  — does it exist, start it, stop it   (actuation + existence)
#   relay   — what is happening inside it        (observation)
#
# Nothing here is stored. Every call is made against the world as it is at the
# moment of the call, and its answer is thrown away when the page is done with
# it. There is no cache to go stale, because there is no cache.
module Podman
  NETWORK = ENV.fetch("COVE_NETWORK", "cove-net")
  TIMEOUT = Integer(ENV.fetch("COVE_PODMAN_TIMEOUT", "30"))
  LABEL = "cove.managed=1"

  Result = Struct.new(:ok, :argv, :stdout, :stderr, :error, keyword_init: true) do
    def ok? = !!ok
    def message = ok? ? stdout.strip : (error || stderr).to_s.strip
    def to_s = ok? ? "ok" : "failed: #{message}"
  end

  class << self
    def available?
      run("podman", "version", "--format", "{{.Client.Version}}").ok?
    end

    # Every pod this Manager ever launched, as the world reports it now.
    def managed
      r = run("podman", "ps", "--filter", "label=#{LABEL}", "--format", "json")
      raise Cove::DocumentError, "podman ps failed: #{r.message}" unless r.ok?
      JSON.parse(r.stdout.presence || "[]")
    rescue JSON::ParserError => e
      raise Cove::DocumentError, "podman ps returned unparseable JSON: #{e.message}"
    end

    def find(pod_name)
      r = run("podman", "container", "inspect", "--type", "container", pod_name)
      return nil unless r.ok?
      parsed = JSON.parse(r.stdout)
      parsed.is_a?(Array) ? parsed.first : parsed
    rescue JSON::ParserError
      nil
    end

    # The button. Real podman, argv array, no shell.
    def start(sheet)
      ensure_network!
      argv = ["podman", "run", "-d",
              "--name", sheet.pod_name,
              "--label", LABEL,
              "--label", "cove.agent=#{sheet.slug}",
              "--network", NETWORK,
              "--hostname", sheet.slug,
              "-e", "COVE_AGENT=#{sheet.slug}",
              "-e", "COVE_SERVICES=#{sheet.services.join(",")}",
              sheet.image]
      argv += sheet.command_argv
      run(*argv)
    end

    def stop(pod_name)
      run("podman", "stop", "--time", "10", pod_name)
    end

    def remove(pod_name)
      run("podman", "rm", "--force", pod_name)
    end

    def ensure_network!
      return if run("podman", "network", "exists", NETWORK).ok?
      run("podman", "network", "create", NETWORK)
    end

    # A single argv call with a deadline. Deliberately not `sh -c`: sheet
    # fields come from a web form, and an interpolated shell string would make
    # Evans' text editor a code path.
    def run(*argv)
      out = err = nil
      status = nil
      begin
        Timeout.timeout(TIMEOUT) do
          out, err, status = Open3.capture3(*argv)
        end
        Result.new(ok: status.success?, argv: argv, stdout: out, stderr: err)
      rescue Timeout::Error
        Result.new(ok: false, argv: argv, stdout: out.to_s, stderr: err.to_s,
                   error: "podman did not answer within #{TIMEOUT}s")
      rescue Errno::ENOENT => e
        Result.new(ok: false, argv: argv, stdout: "", stderr: "",
                   error: "podman is not on PATH inside this pod (#{e.message})")
      end
    end
  end
end
