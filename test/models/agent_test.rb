require "test_helper"

class AgentTest < ActiveSupport::TestCase
  setup do
    @identity = Identity.create!(name: "silas")
    @room = Room.create!(matrix_room_id: "!abc:localhost", name: "general")
  end

  test "instance_name must be unique" do
    @room.agents.create!(identity: @identity, instance_name: "silas-general")
    dup = @room.agents.build(identity: @identity, instance_name: "silas-general")
    assert_not dup.valid?
  end

  test "alive scope" do
    alive = @room.agents.create!(
      identity: @identity, instance_name: "silas-general",
      state: "alive", wg_address: "10.0.1.1")
    @room.agents.create!(
      identity: Identity.create!(name: "kael"),
      instance_name: "kael-general", state: "resolving")

    assert_equal [alive], Agent.alive.to_a
  end

  test "idle scope" do
    old = @room.agents.create!(
      identity: @identity, instance_name: "silas-general",
      state: "alive", wg_address: "10.0.1.1",
      last_message_at: 20.minutes.ago)
    recent = @room.agents.create!(
      identity: Identity.create!(name: "kael"),
      instance_name: "kael-general", state: "alive",
      wg_address: "10.0.1.2",
      last_message_at: 1.minute.ago)

    idle = Agent.idle
    assert_includes idle, old
    assert_not_includes idle, recent
  end

  test "alive?" do
    agent = Agent.new(state: "alive")
    assert agent.alive?

    agent.state = "resolving"
    assert_not agent.alive?
  end
end
