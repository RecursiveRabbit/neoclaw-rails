require "test_helper"

# The mesh underlay is one named user-defined podman network with ONE source of
# addresses: manager/network.env. These tests hold the three rules that keep it
# that way:
#
#   1. the source file carries every mesh address, and nothing else in
#      executable code carries a literal one;
#   2. every launch that needs underlay reachability names the network
#      explicitly — rootless podman's pasta default refuses a static `--ip` and
#      cannot reach a bridge peer at all (measured; the superseded values and
#      the measurement are recorded in manager/network.env);
#   3. startup asserts the live network against the source instead of trusting
#      a host default.
#
# Docs and baton.json are exempt from the literal sweep: they cite values and
# history on purpose. Everything that runs is not.
class PodmanLaunchNetworkTest < ActiveSupport::TestCase
  REPO = File.expand_path("../../..", __dir__)
  SOURCE = "manager/network.env"
  SCRIPTS = %w[manager/entrypoint.sh manager/run.sh].freeze
  LAUNCH = '--network "${NC_MESH_NETWORK}"'.freeze

  def read(path) = File.read(File.join(REPO, path))

  def source_values
    read(SOURCE).each_line.with_object({}) do |line, acc|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      acc[key] = value.to_s.strip if key && value
    end
  end

  # Every `podman run` invocation in a script, sliced to its continuation lines.
  def launches(script)
    read(script).split(/(?:\$PODMAN|podman) run/)[1..].to_a.filter_map do |chunk|
      lines = []
      chunk.each_line do |line|
        lines << line
        break unless line.rstrip.end_with?("\\")
      end
      lines.join
    end
  end

  def all_launches
    SCRIPTS.flat_map { |s| launches(s).map { |l| [s, l] } }
  end

  # --- 1. One source ------------------------------------------------------

  test "network.env carries every mesh address, and they agree with each other" do
    v = source_values
    %w[NC_MESH_NETWORK NC_MESH_SUBNET NC_MESH_GATEWAY ROUTER_BRIDGE_IP ROUTER_ENDPOINT].each do |key|
      assert v[key].present?, "#{SOURCE} must define #{key}"
    end

    subnet, prefix = v["NC_MESH_SUBNET"].split("/")
    assert_equal "16", prefix, "the mesh underlay is described as a /16"
    octets = subnet.split(".").map(&:to_i)
    assert_equal 4, octets.length
    subnet_prefix = octets[0, 2].join(".")

    assert v["NC_MESH_GATEWAY"].start_with?("#{subnet_prefix}."),
           "gateway must live in the mesh subnet (#{v['NC_MESH_GATEWAY']} vs #{v['NC_MESH_SUBNET']})"
    assert v["ROUTER_BRIDGE_IP"].start_with?("#{subnet_prefix}."),
           "Router address must live in the mesh subnet"

    assert_equal "#{v['ROUTER_BRIDGE_IP']}:51820", v["ROUTER_ENDPOINT"],
                 "the WG endpoint must be the Router address on the WG port"
  end

  test "no executable code carries a mesh address literal" do
    offenders = Dir.glob(File.join(REPO, "{manager,infra,router,test,deploy,script,bin}/**/*"))
                   .select { |p| File.file?(p) }
                   .reject { |p| p.end_with?(".md", SOURCE) }
                   .select { |p| p.match?(/\.(sh|rb|py|yml|yaml|json|conf|service|env)\z/) }
                   .select { |p| (File.read(p) rescue "") =~ /\b10\.(?:88|89)\.\d+\.\d+/ }
                   .map { |p| p.delete_prefix("#{REPO}/") }

    assert_empty offenders,
                 "mesh addresses belong in #{SOURCE} only; these files carry a literal: #{offenders.join(', ')}"
  end

  # --- 2. Explicit network on every launch that needs it ------------------

  test "the sweep can see the launches it judges" do
    assert_operator all_launches.length, :>=, 4,
                    "expected at least 4 podman run launches across #{SCRIPTS.join(', ')}"
    assert all_launches.any? { |(_, l)| l.match?(/--ip\s/) },
           "expected at least one launch that pins a static address"
  end

  test "every launch that pins a static IP names the mesh network explicitly" do
    pinned = all_launches.select { |(_, l)| l.match?(/--ip\s/) }
    refute_empty pinned, "no static-IP launch found — the guard is looking at nothing"

    pinned.each do |(script, launch)|
      assert_includes launch, LAUNCH,
                      "#{script}: a launch pins --ip without #{LAUNCH}; rootless pasta " \
                      "refuses a static address and cannot reach the bridge"
      refute_match(/--network\s+(host|none)/, launch, "#{script}: host networking is not an underlay")
      refute_match(/--ip\s+"?10\./, launch, "#{script}: the address must come from the source, not a literal")
    end
  end

  test "the Router launch takes its address from the source" do
    router = all_launches.find { |(_, l)| l.include?("--name wg-router") }
    refute_nil router, "no Router launch found"
    assert_includes router.last, '--ip "${ROUTER_BRIDGE_IP}"'
  end

  test "Hub, Babo and the Manager join the mesh network, or they cannot reach the Router" do
    %w[wg-router neoclaw-hub neoclaw-babo].each do |name|
      launch = all_launches.find { |(_, l)| l.include?("--name #{name}") }
      refute_nil launch, "no launch for #{name}"
      assert_includes launch.last, LAUNCH, "#{name} must name the mesh network"
    end

    manager = forward_launch
    refute_nil manager, "no Manager launch found in manager/run.sh"
    assert_includes manager, LAUNCH, "the Manager dials the Router underlay too"
  end

  # manager/run.sh launches the Manager with a variable name, not a literal one.
  def forward_launch
    launches("manager/run.sh").find { |l| l.include?('--name "$CONTAINER_NAME"') }
  end

  # --- 3. Startup asserts the network, it does not trust a default ------

  test "startup creates or asserts the network and dies naming both values" do
    mesh = read("manager/mesh-network.sh")
    assert_includes mesh, "network exists", "the network must be created if absent"
    assert_includes mesh, "network create"
    assert_includes mesh, "network inspect", "the assertion reads the live network"
    assert_match(/Refusing to start on a network whose addresses we did not choose/, mesh,
                 "a mismatch must refuse to start, not fall back")
    assert_includes mesh, "want_subnet"
    assert_includes mesh, "want_gw"

    entry = read("manager/entrypoint.sh")
    assert_includes entry, '. "$NETWORK_ENV"', "entrypoint sources the single source"
    assert_includes entry, "mesh_network_ensure || die", "boot stops when the network is wrong"
  end

  test "the host launcher sources the same file, not a copy of the values" do
    run = read("manager/run.sh")
    assert_includes run, '. "$NETWORK_ENV"'
    assert_includes run, "mesh_network_ensure"
    assert_match(/Endpoint = \$\{ROUTER_ENDPOINT\}/, run,
                 "the host peer config takes the endpoint from the source")
  end
end
