# Hub seeds — Identities and Listeners only.
# Service types and agent configs live in the Manager's seeds.

identities = [
  { name: "hopper",   singleton: true  },
  { name: "silas",    singleton: false },
  { name: "margaux",  singleton: false },
  { name: "kael",     singleton: false },
  { name: "wren",     singleton: false },
  { name: "ember",    singleton: false },
  { name: "parallax", singleton: false },
  { name: "fletcher", singleton: false },
  { name: "census",   singleton: false },
  { name: "voss",     singleton: false },
]

identities.each do |attrs|
  Identity.find_or_create_by!(name: attrs[:name]) do |i|
    i.singleton = attrs[:singleton]
  end
  puts "  identity: #{attrs[:name]}#{attrs[:singleton] ? ' (singleton)' : ''}"
end

# Hopper listens on #general — unaddressed messages route to Hopper.
hopper = Identity.find_by!(name: "hopper")
Listener.find_or_create_by!(identity: hopper, channel_slug: "general")

puts "Seeded #{Identity.count} identities, #{Listener.count} listeners."
