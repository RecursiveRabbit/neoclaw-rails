require "shellwords"

# A sheet is a row (cove.md §2). This class *is* the sheet: desired state and history.
# It never carries current state — no `status`, no `running`, no `last_seen`. Whether the
# pod exists is a podman query made by whoever needs the answer, at the moment they need it.
#
# It used to be a YAML file per agent in state/agents/. Evans, 2026-11-25: "Everything
# about Cove lives in a relational database. There are no data files." The public API is
# deliberately unchanged, so every caller — Launch, Recover, RouterConfig, the controllers
# — kept working across the change: what moved is where the row lives, not how it is asked
# for.
#
# Law 2 (the renderer refuses unknown attributes): unknown keys were carried through
# untouched rather than dropped, so a sheet written by a newer Manager does not lose fields
# this build has never heard of. A column set cannot do that for keys it has no column for,
# so they live in `extra` and are written back out on save.
module Cove
  class Sheet < ApplicationRecord
    self.table_name = "cove_sheets"

    # A sheet is an agent unless it says otherwise. `kind` decides one thing only:
    # which address the allocator may hand it. It is not a capability and not a type —
    # a service-kind sheet is still a pod this Manager launches, peers and permits.
    KIND_AGENT   = "agent"
    KIND_SERVICE = "service"

    COLUMNS = %w[name kind harness model repo image command listen pod_ip pubkey wg_port].freeze
    LISTS   = %w[tools services].freeze

    class << self
      def arrayify(value)
        case value
        when Array  then value.map { |v| v.to_s.strip }.reject(&:empty?).uniq
        when String then value.split(/[,\s]+/).map(&:strip).reject(&:empty?).uniq
        when nil    then []
        else [value.to_s]
        end
      end

      def find(slug)
        return nil unless Cove.valid_slug?(slug)

        find_by(slug: slug.to_s)
      end

      # NOT overridden. Active Record's own `all` is a relation, and every class-level
      # query method delegates to it — so overriding it and calling `order` or `unscoped`
      # from inside recurses until the stack ends (measured twice: 9,694 levels, then a
      # broken ORDER preprocessor). Callers that need an order ask for one.

      def create!(attrs)
        sheet = new
        sheet.assign(attrs)
        sheet.save!
        sheet
      end

      # One-time import of the files this build used to keep. Idempotent in the only way
      # that matters: it does nothing at all if the table already holds a sheet, so a
      # second boot cannot duplicate or overwrite. The files are left where they are.
      def import_legacy!
        return 0 if count.positive?

        dir = Cove.agents_dir
        return 0 unless Dir.exist?(dir)

        imported = 0
        Dir.glob(dir.join("*.yml").to_s).sort.each do |path|
          raw = Cove.yaml_load(path)
          next unless raw.is_a?(Hash)

          sheet = new
          sheet.slug = File.basename(path, ".yml")
          sheet.assign(raw)
          sheet.save!
          imported += 1
        end
        imported
      end
    end

    # --- attributes ---------------------------------------------------------
    # The readers coerce, because a column is not a document: a sheet's `listen` used to
    # default at read time and a caller must not have to know whether the row was written
    # before or after that decision.

    def name     = self[:name].to_s
    def kind     = self[:kind].to_s.empty? ? KIND_AGENT : self[:kind].to_s
    def service? = kind == KIND_SERVICE
    def harness  = self[:harness].to_s
    def model    = self[:model].to_s
    def repo     = self[:repo].to_s
    def image    = self[:image].to_s
    def command  = self[:command].to_s
    def pod_ip   = self[:pod_ip].to_s
    def pubkey   = self[:pubkey].to_s
    def wg_port  = self[:wg_port].to_s

    # A service-kind sheet publishes one port. Defaulting it is a decision, not a guess at
    # the service's nature: every HTTP-ish thing in this town listens on 3000, and a service
    # with no port cannot be permitted at all.
    def listen = self[:listen].to_s.empty? ? "3000" : self[:listen].to_s

    def tools    = self.class.arrayify(read_list(:tools))
    def services = self.class.arrayify(read_list(:services))

    def pod_name = "cove-#{slug}"

    def command_argv
      return [] if command.strip.empty?

      # A sheet's command is a line, not a shell string. Split it the way a shell would for
      # words and quotes, then hand it to podman as argv. It is never passed to sh -c.
      Shellwords.split(command)
    rescue ArgumentError => e
      raise Cove::DocumentError, "#{slug}: command cannot be split: #{e.message}"
    end

    # The single writer of every column, and the only place the coercions happen. Callers
    # pass a hash with string keys — that is what a controller's params are and what the
    # launcher builds — and unknown keys go to `extra` rather than being dropped.
    def assign(attrs)
      h = (attrs || {}).to_h.transform_keys(&:to_s)

      COLUMNS.each { |k| self[k] = h[k].to_s.strip if h.key?(k) }
      LISTS.each   { |k| write_list(k, self.class.arrayify(h[k])) if h.key?(k) }

      self.name   = "unnamed" if name.empty?
      self.kind   = KIND_SERVICE if kind == KIND_SERVICE # normalise through the reader's rule
      self.image  = "localhost/cove-agent:latest" if image.empty?
      # An unknown kind is kept as written and treated as an agent: guessing "service" for a
      # word this build has never heard of would hand out an address that is not the
      # caller's to take.
      self[:kind] = h.key?("kind") && h["kind"].to_s.strip == KIND_SERVICE ? KIND_SERVICE : KIND_AGENT

      known = COLUMNS + LISTS + %w[slug created_at updated_at extra]
      extras = h.reject { |k, _| known.include?(k) }
      self.extra = (JSON.parse(self[:extra].to_s.empty? ? "{}" : self[:extra]) rescue {}).merge(extras).to_json

      self
    end

    def as_document
      doc = COLUMNS.each_with_object({}) { |k, out| out[k] = public_send(k) }
      doc["slug"] = slug
      doc["tools"] = tools
      doc["services"] = services
      doc.merge(extras_hash)
    end

    private

    def extras_hash
      JSON.parse(self[:extra].to_s.empty? ? "{}" : self[:extra])
    rescue JSON::ParserError
      {}
    end

    def read_list(name)
      raw = self[name]
      return [] if raw.to_s.empty?

      parsed = (JSON.parse(raw) rescue nil)
      parsed.is_a?(Array) ? parsed : raw
    end

    def write_list(name, list) = self[name] = list.to_json
  end
end
