# state.rb — persistent agent registry
#
# Tracks registered agents, their IPs, access rules, and WG state.
# Persists to JSON on a mounted volume so the Router survives restarts.

require "json"
require "fileutils"

class State
  def initialize(path)
    @path = path
    @agents = {}
    load!
  end

  def load!
    if File.exist?(@path)
      data = JSON.parse(File.read(@path))
      @agents = data["agents"] || {}
    end
  rescue JSON::ParserError => e
    $stderr.puts "WARN: corrupt state file, starting fresh: #{e.message}"
    @agents = {}
  end

  def save!
    FileUtils.mkdir_p(File.dirname(@path))
    tmp = "#{@path}.tmp"
    File.write(tmp, JSON.pretty_generate("agents" => @agents))
    File.rename(tmp, @path)
  end

  def get(name)
    @agents[name]&.dup
  end

  def all
    @agents.dup
  end

  def registered?(name)
    @agents.key?(name)
  end

  def register(name, ip:, access:, peer_pubkey:)
    @agents[name] = {
      "ip" => ip,
      "access" => access,
      "peer_pubkey" => peer_pubkey,
      "active" => true,
      "blocked" => false,
      "registered_at" => Time.now.utc.iso8601,
      "last_peer_update" => Time.now.utc.iso8601
    }
    save!
  end

  def update_access(name, access:)
    return nil unless @agents[name]
    @agents[name]["access"] = access
    save!
    @agents[name].dup
  end

  def update_peer(name, peer_pubkey:)
    return nil unless @agents[name]
    @agents[name]["peer_pubkey"] = peer_pubkey
    @agents[name]["active"] = true
    @agents[name]["last_peer_update"] = Time.now.utc.iso8601
    save!
    @agents[name].dup
  end

  def deactivate(name)
    return nil unless @agents[name]
    @agents[name]["active"] = false
    @agents[name]["peer_pubkey"] = nil
    save!
    @agents[name].dup
  end

  def block(name)
    return nil unless @agents[name]
    @agents[name]["blocked"] = true
    save!
    @agents[name].dup
  end

  def unblock(name)
    return nil unless @agents[name]
    @agents[name]["blocked"] = false
    save!
    @agents[name].dup
  end

  def remove(name)
    agent = @agents.delete(name)
    save! if agent
    agent
  end
end
