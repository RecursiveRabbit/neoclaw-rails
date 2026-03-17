require "test_helper"

class Hub::RouterTest < ActiveSupport::TestCase
  test "parse_mention with @mention" do
    target, message = Hub::Router.send(:parse_mention, "@silas fix the build")
    assert_equal "silas", target
    assert_equal "fix the build", message
  end

  test "parse_mention with Matrix pill" do
    formatted = '<a href="https://matrix.to/#/@silas:matrix.home">Silas</a>: fix it'
    target, _message = Hub::Router.send(:parse_mention, "Silas: fix it", formatted)
    assert_equal "silas", target
  end

  test "parse_mention with no mention" do
    target, message = Hub::Router.send(:parse_mention, "just a regular message")
    assert_nil target
    assert_equal "just a regular message", message
  end

  test "extract_sender from Matrix event" do
    event = { "sender" => "@evans:matrix.home" }
    assert_equal "evans", Hub::Router.send(:extract_sender, event)
  end

  test "route ignores appservice self-messages" do
    room = Room.create!(matrix_room_id: "!abc:localhost", name: "general")
    event = {
      "type" => "m.room.message",
      "sender" => "@neoclaw:matrix.home",
      "content" => { "body" => "hello" }
    }

    # Should return nil (ignored), not raise
    result = Hub::Router.route(event, room: room)
    assert_nil result
  end
end
