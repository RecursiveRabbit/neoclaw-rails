require "test_helper"

class OfficeStateTest < ActiveSupport::TestCase
  def setup
    @old_boot = ENV["NC_BOOT_ID"] # unused, kept for symmetry
    Container.delete_all
    CredentialCheckout.delete_all
    OfficeState.inventory_source = -> { [] }
  end

  def teardown
    OfficeState.inventory_source = nil
    Container.delete_all
    CredentialCheckout.delete_all
  end

  def record(name, state)
    Container.create!(instance_name: name, identity: name.split("-").first,
                      channel: "general", state: state, wg_address: "10.1.0.9")
  end

  def state_for(name)
    OfficeState.as_api[:agents].find { |a| a[:handle] == name }
  end

  test "an unreadable inventory is unknown, never dead" do
    record("a-one", "alive")
    OfficeState.inventory_source = -> { raise Errno::ENOENT, "/run/podman/podman.sock" }

    api = OfficeState.as_api
    row = api[:agents].find { |a| a[:handle] == "a-one" }
    assert_equal "unknown", row[:state]
    assert_equal "error", row[:provenance][:podman]
    assert_match(/unreadable/, row[:provenance][:note])
    assert api[:inventory_error]
    assert_equal "unavailable", api[:backend]
  end

  test "an inventory error does not turn a graceful stand-down into dead" do
    record("a-one", "inactive")
    AuditLog.record("SESSION_PROCESSED", instance_name: "a-one", identity: "a",
                    detail: { ended_reason: "idle" }.to_json)
    OfficeState.inventory_source = -> { raise IOError, "socket gone" }

    row = state_for("a-one")
    assert_equal "unknown", row[:state]
    assert_equal "error", row[:provenance][:podman]
  end

  test "inventory error clears on the next successful read" do
    record("a-one", "alive")
    OfficeState.inventory_source = -> { raise IOError, "socket gone" }
    OfficeState.as_api
    assert OfficeState.inventory_error?

    OfficeState.inventory_source = -> { [{ name: "a-one", state: "running" }] }
    api = OfficeState.as_api
    refute api[:inventory_error]
    assert_equal "podman", api[:backend]
    assert_equal "alive", api[:agents].first[:state]
  end

  test "state is a closed lowercase set" do
    record("a-one", "alive")
    OfficeState.inventory_source = -> { [{ name: "a-one", state: "running", ip: "10.1.0.9" }] }

    api = OfficeState.as_api
    assert_equal %w[alive frozen starting dead unknown], api[:states]
    api[:agents].each do |agent|
      assert_includes OfficeState::STATES, agent[:state]
      assert_equal agent[:state], agent[:state].downcase
    end
  end

  test "podman running + record alive is alive" do
    record("a-one", "alive")
    OfficeState.inventory_source = -> { [{ name: "a-one", state: "running", ip: "10.1.0.9" }] }
    row = state_for("a-one")
    assert_equal "alive", row[:state]
    assert_equal "running", row[:provenance][:podman]
  end

  test "record starting stays starting" do
    record("a-one", "starting")
    OfficeState.inventory_source = -> { [{ name: "a-one", state: "running" }] }
    assert_equal "starting", state_for("a-one")[:state]
  end

  test "podman paused is frozen" do
    record("a-one", "alive")
    OfficeState.inventory_source = -> { [{ name: "a-one", state: "paused" }] }
    assert_equal "frozen", state_for("a-one")[:state]
  end

  test "record without a pod and no stand-down on record is dead" do
    record("a-one", "alive")
    OfficeState.inventory_source = -> { [] }
    row = state_for("a-one")
    assert_equal "dead", row[:state]
    assert_match(/no graceful stand-down/, row[:provenance][:note])
  end

  test "a successful stand-down with no pod reads frozen, not dead" do
    record("a-one", "inactive")
    AuditLog.record("SESSION_PROCESSED", instance_name: "a-one", identity: "a",
                    detail: { ended_reason: "idle" }.to_json)
    AuditLog.record("TEARDOWN", instance_name: "a-one", identity: "a",
                    detail: "Clean teardown")
    OfficeState.inventory_source = -> { [] }

    row = state_for("a-one")
    assert_equal "frozen", row[:state]
    assert_equal "idle", row[:provenance][:ended_reason]
    assert_match(/work preserved/, row[:provenance][:note])
  end

  test "context-limit ending also reads frozen" do
    record("a-one", "inactive")
    AuditLog.record("SESSION_PROCESSED", instance_name: "a-one", identity: "a",
                    detail: { ended_reason: "context_limit" }.to_json)
    OfficeState.inventory_source = -> { [] }
    assert_equal "frozen", state_for("a-one")[:state]
  end

  test "a crash ending reads dead, not frozen" do
    record("a-one", "inactive")
    AuditLog.record("SESSION_PROCESSED", instance_name: "a-one", identity: "a",
                    detail: { ended_reason: "crash" }.to_json)
    OfficeState.inventory_source = -> { [] }
    assert_equal "dead", state_for("a-one")[:state]
  end

  test "stand-down in flight is unknown and names the transition" do
    record("a-one", "freezing")
    OfficeState.inventory_source = -> { [{ name: "a-one", state: "running" }] }
    row = state_for("a-one")
    assert_equal "unknown", row[:state]
    assert_match(/stand-down in progress/, row[:provenance][:note])
  end

  test "no record and no pod is unknown, not invented" do
    OfficeState.inventory_source = -> { [{ name: "ghost", state: "exited" }] }
    row = state_for("ghost")
    assert_equal "dead", row[:state]
  end

  test "podman running but record disagrees is unknown with provenance" do
    record("a-one", "inactive")
    OfficeState.inventory_source = -> { [{ name: "a-one", state: "running" }] }
    row = state_for("a-one")
    assert_equal "unknown", row[:state]
    assert_match(/disagrees/, row[:provenance][:note])
  end

  test "an unrecognised podman state is never reported as alive" do
    record("a-one", "alive")
    OfficeState.inventory_source = -> { [{ name: "a-one", state: "weird" }] }
    assert_equal "dead", state_for("a-one")[:state]
  end

  test "live credentials are listed by id and scope, never by value" do
    record("a-one", "alive")
    OfficeState.inventory_source = -> { [{ name: "a-one", state: "running" }] }
    row = CredentialCheckout.issue!(scope: "ssh-key", instance_name: "a-one",
                                    revoke_handle: "file:/tmp/x")
    listed = state_for("a-one")[:live_credentials]
    assert_equal 1, listed.size
    assert_equal row.id, listed.first[:id]
    assert_equal "ssh-key", listed.first[:scope]
    refute listed.first.key?(:revoke_handle)
  end
end
