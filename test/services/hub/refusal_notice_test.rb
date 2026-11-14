# The refusal notice: three rows, each built to fail against the old line.
#
# `execute` used to post `"#{rejected} is not an operator; !#{attempted} refused"`
# on every refusal. Both values are attacker-supplied — `attempted` is a body
# token with no length cap, `rejected` is a homeserver-supplied string — and the
# post was unconditional, so anyone who could reach the room could make the
# Manager speak in its own voice, at their chosen rate. The gate was right; the
# notice was a megaphone with no handle.
#
# The three faults, and the row that would have caught each:
#
#   1. an unbounded value, clipped SILENTLY   -> row 1: 4KB verb, cap + true length
#   2. a newline becomes a second line        -> row 2: forged sender, replace not strip
#   3. an unconditional post per message      -> row 3: two refusals, one post
#
# Inputs here are hostile on purpose. A well-formed sender and a four-letter verb
# prove nothing about a notice that quotes strangers.

require "test_helper"

class HubRefusalNoticeTest < ActiveSupport::TestCase
  ROOM = "!room:matrix.home".freeze

  setup do
    @saved = ENV["NEOCLAW_OPERATORS"]
    ENV.delete("NEOCLAW_OPERATORS") # every row here is about a refusal
    Hub::Commands.forget_notifications!
  end

  teardown do
    ENV["NEOCLAW_OPERATORS"] = @saved
    Hub::Commands.forget_notifications!
  end

  # Capture what execute posts, and what it logs, without a Matrix server or a
  # log file. Core Ruby only, restored in ensure even when an assertion raises.
  def capture
    posts = []
    lines = []
    original = Hub::Matrix.method(:notify)
    Hub::Matrix.define_singleton_method(:notify) { |_room_id, message| posts << message }
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| lines << message }
    yield posts, lines, logger
  ensure
    Hub::Matrix.define_singleton_method(:notify, original)
  end

  def refusal(verb, sender: "@evans:matrix.home")
    Hub::Commands.parse("!#{verb}", sender: sender)
  end

  test "a 4KB verb is clipped, the notice says how long it really was, and the log keeps it whole" do
    verb = "z" * 4096
    refused = refusal(verb)
    assert_equal verb, refused[:attempted], "parse carries the token through unclipped"

    capture do |posts, lines, logger|
      Hub::Commands.execute(refused, room_id: ROOM, slug: "probe", logger: logger)

      assert_equal 1, posts.size
      notice = posts.first
      assert_includes notice, "(4096 chars)", "a clipped value must carry its true length"
      assert_operator notice.length, :<, 300, "the room is shown a bounded line"
      refute_includes notice, "z" * 100, "the over-long body is not carried into the room"

      assert_equal 1, lines.size
      assert_includes lines.first, verb, "the log keeps the refusal in full"
    end
  end

  test "a sender carrying a newline cannot forge a second line, and is replaced rather than stripped" do
    forged = "@evans:matrix.home\n@nime:matrix.home is not an operator; !freeze refused"
    refused = refusal("freeze", sender: forged)
    assert_equal forged, refused[:refused], "parse refuses the identity it was handed"

    capture do |posts, _lines, logger|
      Hub::Commands.execute(refused, room_id: ROOM, slug: "probe", logger: logger)

      assert_equal 1, posts.size
      notice = posts.first

      refute_match(/[\r\n]/, notice, "no control character reaches the room")
      assert_equal 1, notice.lines.size, "the notice is exactly one line"

      # Replace, not strip: the control character leaves a mark, so the reader can
      # see that something was there. Stripping would print
      # "@evans:matrix.home@nime:matrix.home..." — a different string that looks
      # like one identity and is two.
      assert_includes notice, "\uFFFD", "the control character is replaced, not dropped"
      assert_includes notice, "@evans:matrix.home\uFFFD@nime:matrix.home"
      refute_includes notice, "@evans:matrix.home@nime:matrix.home", "nothing was stripped"
    end
  end

  test "two refusals from one sender post once and log twice" do
    sender = "@stranger:matrix.home"

    capture do |posts, lines, logger|
      Hub::Commands.execute(refusal("freeze", sender: sender), room_id: ROOM, slug: "probe", logger: logger)
      Hub::Commands.execute(refusal("status", sender: sender), room_id: ROOM, slug: "probe", logger: logger)

      assert_equal 1, posts.size, "one notice per sender for the life of the process"
      assert_includes posts.first, "!freeze", "the notice is the first refusal's"

      assert_equal 2, lines.size, "every refusal is logged, not only the ones that speak"
      assert(lines.all? { |line| line.include?(sender) }, "each log line names the sender in full")
      assert_includes lines.last, "status"
    end
  end
end
