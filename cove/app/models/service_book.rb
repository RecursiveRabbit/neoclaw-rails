# The services on this host, as *data*. A service is a name and an address.
#
# Nothing in this build may know more than that. The moment the Manager starts
# to care what a service does — its API, its token scheme, its port semantics —
# the assignment has slipped (the commission's discipline paragraph). The list
# lives in state/services.yml, which Evans can edit with any editor.
class ServiceBook
  Entry = Struct.new(:name, :address, keyword_init: true)

  def self.all
    doc = Cove.yaml_load(Cove.services_file) || {}
    rows = doc["services"] || []
    raise Cove::DocumentError, "#{Cove.services_file}: 'services' must be a list" unless rows.is_a?(Array)

    rows.map do |row|
      row = row.to_h.transform_keys(&:to_s)
      Entry.new(name: row["name"].to_s.strip, address: row["address"].to_s.strip)
    end.reject { |e| e.name.empty? }.sort_by(&:name)
  end

  def self.names = all.map(&:name)
end
