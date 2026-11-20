# The seam.
#
# The router does not exist yet. When it does, it will be a dumb box that reads
# this file and nothing else — so this file is the entire contract between what
# Evans clicks and what the network will be.
#
# Three properties, and each one is enforced by the code below rather than by a
# comment in a spec:
#
#   1. TOTAL.  render/2 takes only the two document sets and emits every line
#              the intent implies. There is no patch path, no diff, no append.
#   2. PURE.   No timestamps, no hostnames of the moment, no query results.
#              Identical intent renders identical bytes, so `git diff` on this
#              file shows intent changes and nothing else.
#   3. HONEST. An agent that names a service the service book does not have is
#              rendered as `unresolved`, never silently dropped and never
#              invented. The file says what the Manager could not decide.
module RouterConfig
  FORMAT_VERSION = 1

  class << self
    # => String, the whole configuration, every time.
    def render(agents, services)
      agents = agents.sort_by(&:slug)
      services = services.sort_by(&:name)
      known = services.map(&:name)

      lines = []
      lines << "# cove router intent — the whole of it, rewritten whole on every change."
      lines << "# Read by the router and by nothing else. Do not edit: the Manager overwrites this file."
      lines << "# No timestamps: identical intent renders identical bytes, so a diff shows only intent."
      lines << "version #{FORMAT_VERSION}"
      lines << ""

      agents.each do |agent|
        allowed = agent.services.uniq.sort
        lines << %(agent "#{q(agent.slug)}"#{allowed.empty? ? "" : %( services="#{q(allowed.join(" "))}")})
      end

      unless services.empty?
        lines << ""
        services.each { |s| lines << %(service "#{q(s.name)}" address="#{q(s.address)}") }
      end

      allows = []
      unresolved = []
      agents.each do |agent|
        agent.services.uniq.sort.each do |service_name|
          if known.include?(service_name)
            allows << [agent.slug, service_name]
          else
            unresolved << [agent.slug, service_name]
          end
        end
      end

      unless allows.empty?
        lines << ""
        lines << "# permits: a pod may reach exactly what is listed here and nothing else"
        allows.sort.each { |a, s| lines << %(allow "#{q(a)}" "#{q(s)}") }
      end

      unless unresolved.empty?
        lines << ""
        lines << "# unresolved: named by a sheet, absent from the service book — the Manager cannot decide these"
        unresolved.sort.each { |a, s| lines << %(unresolved "#{q(a)}" "#{q(s)}") }
      end

      lines << ""
      lines << "# agents=#{agents.size} services=#{services.size} allows=#{allows.size} unresolved=#{unresolved.size}"
      lines.join("\n") + "\n"
    end

    # Render from what is on disk and write it. The only writer of router.conf.
    # Any mutation anywhere calls this; there is nowhere else to call.
    def write!
      agents = Sheet.all
      services = ServiceBook.all
      body = render(agents, services)
      Cove.write_atomic(Cove.router_file, body)
      body
    end

    def current
      File.exist?(Cove.router_file) ? File.read(Cove.router_file) : nil
    end

    private

    # The format is one-line-per-fact, split on whitespace outside quotes. A
    # quote inside a name would break a dumb reader, so it is refused loudly
    # rather than escaped into something the reader cannot see.
    def q(value)
      s = value.to_s
      if s.include?('"') || s.include?("\n")
        raise Cove::DocumentError, "cannot render a value containing a quote or newline: #{s.inspect}"
      end
      s
    end
  end
end
