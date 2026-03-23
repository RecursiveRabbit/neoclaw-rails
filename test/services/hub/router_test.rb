require "test_helper"

class Hub::RouterTest < ActiveSupport::TestCase
  test "extract_mention from m.mentions" do
    event = {
      "sender" => "@evans:matrix.home",
      "content" => {
        "body" => "@silas fix the build",
        "m.mentions" => { "user_ids" => ["@silas:matrix.home"] }
      }
    }
    assert_equal "silas", Hub::Router.send(:extract_mention, event)
  end

  test "extract_mention with no mention" do
    event = {
      "sender" => "@evans:matrix.home",
      "content" => { "body" => "just a regular message" }
    }
    assert_nil Hub::Router.send(:extract_mention, event)
  end

  test "extract_sender from Matrix event" do
    event = { "sender" => "@evans:matrix.home" }
    assert_equal "evans", Hub::Router.send(:extract_sender, event)
  end

  test "process_previous parses count and remaining body" do
    # Stub Matrix.recent_messages
    Hub::Matrix.stub(:recent_messages, [
      { sender: "evans", content: "first message" },
      { sender: "silas", content: "second message" },
      { sender: "evans", content: "third message" },
    ]) do
      result = Hub::Router.send(:process_previous,
        "@silas !previous 3 What do you think?",
        room_id: "!test:matrix.home",
        event_id: "$test123"
      )

      assert_includes result, "[Previous messages]"
      assert_includes result, "@evans: first message"
      assert_includes result, "@silas: second message"
      assert_includes result, "@evans: third message"
      assert_includes result, "What do you think?"
    end
  end

  test "process_previous defaults to 1 message" do
    Hub::Matrix.stub(:recent_messages, [
      { sender: "evans", content: "the latest" },
    ]) do
      result = Hub::Router.send(:process_previous,
        "@silas !previous",
        room_id: "!test:matrix.home",
        event_id: "$test123"
      )

      assert_includes result, "@evans: the latest"
    end
  end

  test "process_previous passes through non-matching body" do
    body = "@silas can you fix the build?"
    result = Hub::Router.send(:process_previous,
      body,
      room_id: "!test:matrix.home",
      event_id: "$test123"
    )

    assert_equal body, result
  end

  test "process_previous works without @mention prefix" do
    Hub::Matrix.stub(:recent_messages, [
      { sender: "evans", content: "fix this please" },
    ]) do
      result = Hub::Router.send(:process_previous,
        "!previous 1 What's the status?",
        room_id: "!test:matrix.home",
        event_id: "$test123"
      )

      assert_includes result, "@evans: fix this please"
      assert_includes result, "What's the status?"
    end
  end

  test "process_previous caps at 50" do
    called_with_limit = nil
    mock_messages = ->(*args, **kwargs) {
      called_with_limit = kwargs[:limit]
      []
    }

    Hub::Matrix.stub(:recent_messages, mock_messages) do
      Hub::Router.send(:process_previous,
        "!previous 999",
        room_id: "!test:matrix.home",
        event_id: "$test123"
      )
      # count clamped to 50, fetches 55 (50 + 5 buffer)
      assert_equal 55, called_with_limit
    end
  end
end
