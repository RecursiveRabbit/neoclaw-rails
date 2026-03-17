require "test_helper"

class RoomTest < ActiveSupport::TestCase
  test "matrix_room_id is required" do
    assert_not Room.new(matrix_room_id: "").valid?
  end

  test "slug derived from name" do
    room = Room.create!(matrix_room_id: "!abc:localhost", name: "#Infrastructure")
    assert_equal "infrastructure", room.slug
  end

  test "slug strips special chars" do
    room = Room.create!(matrix_room_id: "!abc:localhost", name: "# Art & Design! ")
    assert_equal "art-design", room.slug
  end

  test "slug defaults to general" do
    room = Room.create!(matrix_room_id: "!abc:localhost", name: "###")
    assert_equal "general", room.slug
  end

  test "agent_for finds alive agent" do
    identity = Identity.create!(name: "silas")
    room = Room.create!(matrix_room_id: "!abc:localhost", name: "general")
    agent = room.agents.create!(
      identity: identity,
      instance_name: "silas-general",
      state: "alive",
      wg_address: "10.0.1.1"
    )

    assert_equal agent, room.agent_for(identity)
  end

  test "agent_for ignores resolving agents" do
    identity = Identity.create!(name: "silas")
    room = Room.create!(matrix_room_id: "!abc:localhost", name: "general")
    room.agents.create!(
      identity: identity,
      instance_name: "silas-general",
      state: "resolving"
    )

    assert_nil room.agent_for(identity)
  end
end
