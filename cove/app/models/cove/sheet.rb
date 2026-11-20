require "yaml"
require "shellwords"

# An agent is a configuration sheet (cove.md §2). This class *is* the sheet:
# desired state and history. It never carries current state — no `status`,
# no `running`, no `last_seen`. Whether the pod exists is a podman query made
# by whoever needs the answer, at the moment they need it.
#
# Law 2 (the renderer refuses unknown attributes): unknown keys in the file are
# carried through untouched rather than dropped, so a sheet edited by hand —
# or by a newer Manager — does not lose fields this build has never heard of.
module Cove
  class Sheet
    # A sheet is an agent unless it says otherwise. `kind` decides one thing only:
    # which pool the address comes from. It is not a capability and not a type —
    # a service-kind sheet is still a pod this Manager launches, peers and permits.
    KIND_AGENT   = "agent"
    KIND_SERVICE = "service"

    attr_reader :data, :slug

    def initialize(data = {}, slug: nil)
      @data = normalise(data)
      @slug = slug || Cove.slugify(@data["name"])
    end

    def normalise(raw)
      h = (raw || {}).to_h.transform_keys(&:to_s)
      out = h.dup                       # unknown keys survive, by law
      out["name"] = h["name"].to_s.strip
      out["name"] = "unnamed" if out["name"].empty?
      %w[harness model repo image command].each { |k| out[k] = h[k].to_s.strip }
      out["image"] = "localhost/cove-agent:latest" if out["image"].to_s.empty?
      out["tools"]    = self.class.arrayify(h["tools"])
      out["services"] = self.class.arrayify(h["services"])
      # An unknown kind is kept as written and treated as an agent: guessing
      # "service" for a word this build has never heard of would hand out an
      # address out of a pool that is not the caller's to take.
      out["kind"] = h["kind"].to_s.strip == KIND_SERVICE ? KIND_SERVICE : KIND_AGENT
      # pod_ip and pubkey are HISTORY, not current state (§2 law 1): they record
      # what the last launch did, and neither says a pod is running. pod_ip
      # survives destroy because an address is the sheet's; pubkey does not,
      # because an identity is the pod's and a reborn pod must not inherit one.
      out["pod_ip"] = h["pod_ip"].to_s.strip
      out["pubkey"] = h["pubkey"].to_s.strip
      out["listen"] = h["listen"].to_s.strip
      out["created_at"] = (h["created_at"] || Time.now.utc.iso8601).to_s
      out["updated_at"] = (h["updated_at"] || Time.now.utc.iso8601).to_s
      out
    end

    def self.arrayify(value)
      case value
      when Array  then value.map { |v| v.to_s.strip }.reject(&:empty?).uniq
      when String then value.split(/[,\s]+/).map(&:strip).reject(&:empty?).uniq
      when nil    then []
      else [value.to_s]
      end
    end

    # --- identity -----------------------------------------------------------
    # The slug comes from the filename on load, and from the name only at
    # creation. It is never re-derived on edit: renaming an agent must not
    # orphan its pod or silently move its file.

    def self.slug_for(path) = File.basename(path.to_s, ".yml")

    def self.load(path)
      new(Cove.yaml_load(path), slug: slug_for(path))
    end

    def self.find(slug)
      return nil unless Cove.valid_slug?(slug)
      path = Cove.agents_dir.join("#{slug}.yml")
      File.exist?(path) ? load(path) : nil
    end

    def self.all
      Dir.glob(Cove.agents_dir.join("*.yml").to_s).sort.map { |p| load(p) }
    end

    def self.create!(attrs)
      sheet = new(attrs)
      sheet.save!
      sheet
    end

    # --- attributes ---------------------------------------------------------

    def name     = @data["name"]
    def kind     = @data["kind"] || KIND_AGENT
    def service? = kind == KIND_SERVICE
    def harness  = @data["harness"]
    def model    = @data["model"]
    def repo     = @data["repo"]
    def image    = @data["image"]
    def command  = @data["command"]
    def tools    = @data["tools"]
    def services = @data["services"]
    def pod_ip   = @data["pod_ip"].to_s
    def pubkey   = @data["pubkey"].to_s
    # A service-kind sheet publishes one port. Defaulting it is a decision, not a
    # guess at the service's nature: every HTTP-ish thing in this town listens on
    # 3000, and a service with no port cannot be permitted at all.
    def listen   = @data["listen"].to_s.empty? ? "3000" : @data["listen"].to_s
    def created_at = @data["created_at"]
    def updated_at = @data["updated_at"]

    def file_path = Cove.agents_dir.join("#{slug}.yml")
    def pod_name  = "cove-#{slug}"

    def command_argv
      return [] if command.to_s.strip.empty?
      # A sheet's command is a line, not a shell string. Split it the way a
      # shell would for words and quotes, then hand it to podman as argv.
      # It is never passed to sh -c.
      Shellwords.split(command)
    rescue ArgumentError => e
      raise Cove::DocumentError, "#{file_path}: command cannot be split: #{e.message}"
    end

    def assign(attrs)
      updates = {}
      %w[name kind harness model repo image command listen pod_ip pubkey].each do |k|
        updates[k] = attrs[k] if attrs.key?(k)
      end
      %w[tools services].each do |k|
        updates[k] = self.class.arrayify(attrs[k]) if attrs.key?(k)
      end
      updates["updated_at"] = Time.now.utc.iso8601
      new_data = @data.merge(updates)
      new_data["created_at"] = @data["created_at"]
      @data = normalise(new_data)
      self
    end

    def save!
      Cove.write_atomic(file_path, serialise)
      self
    end

    def serialise
      "# sheet: #{slug}\n" + YAML.dump(@data).sub(/\A---\s*\n/, "").sub(/\n\z/, "\n")
    end
  end
end
