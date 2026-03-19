# Zeitwerk expects wireguard.rb to define Wireguard.
# Our class is WireGuard. Override the inflection.
Rails.autoloaders.main.inflector.inflect("wireguard" => "WireGuard")
