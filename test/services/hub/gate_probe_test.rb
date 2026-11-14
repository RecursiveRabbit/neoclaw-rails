# The operator gate, end to end: parse -> execute.
#
# commands_test.rb stops at `parse`. That is where the decision is made, and it is
# not where anything happens: `execute` is the only caller that turns a decision
# into an effect — a refusal posted to the room, or a handler run. A gate that is
# right in `parse` and wrong in `execute` passes every row there and fails in the
# room, so these rows walk the same three states through both halves.
#
# The three states, and why each one needs its own row:
#
#   (a) NEOCLAW_OPERATORS unset      -> every registered verb refuses, and the
#                                       refusal names the identity it compared
#   (b) a bare localpart configured  -> matches nobody, and warns EXACTLY ONCE at
#                                       boot (not per message: the accessor is
#                                       called on every incoming message, so a
#                                       warning there would grow with traffic)
#   (c) a full Matrix ID configured  -> the command executes, and a look-alike on
#                                       another server still does not
#
# The printed `probe (x)` lines are the record, and they are deliberately part of
# the deliverable: `bin/rails test` is not verbose, so a green run otherwise shows
# a count and no names. One line per state, in the log, carrying what was compared.
#
# What this does NOT prove: that any Manager pod runs this code. No pod runs this
# Manager. This is a runner, and the claim stops where the evidence stops.

require "test_helper"

class HubGateProbeTest < ActiveSupport::TestCase
  SENDER = "@evans:matrix.home".freeze
  # A name that exists in the organisation and is not the operator above. The
  # empty-set row uses it so that "refuses everybody" is two identities and not
  # one identity twice.
  SECOND_SENDER = "@nime:matrix.home".freeze
  ROOM = "!room:matrix.home".freeze

  setup do
    @saved = ENV["NEOCLAW_OPERATORS"]
    # The refusal notice is once-per-sender for the life of the process, so a row
    # that asserts the post has to start from a known state.
    Hub::Commands.forget_notifications!
  end

  teardown do
    ENV["NEOCLAW_OPERATORS"] = @saved
    Hub::Commands.forget_notifications!
  end

  # Capture what `execute` posts, without a Matrix server. Hand-rolled rather than
  # Minitest's `stub` so this file needs nothing beyond core Ruby, and the restore
  # runs even when an assertion raises inside the block.
  def capture_posts
    sent = []
    original = Hub::Matrix.method(:notify)
    Hub::Matrix.define_singleton_method(:notify) { |_room_id, message| sent << message }
    yield sent
  ensure
    Hub::Matrix.define_singleton_method(:notify, original)
  end

  # A logger that keeps its lines. OperatorContract takes one for exactly this:
  # the words are testable without reading a log file.
  def recording_logger(lines)
    logger = Object.new
    logger.define_singleton_method(:warn) { |message| lines << message }
    logger
  end

  test "probe (a): an unconfigured hub refuses every registered verb through execute, and names the sender" do
    # producing line: manager/entrypoint.sh:131 / manager/run.sh:63 — `-e NEOCLAW_OPERATORS`
    # with no value. Unset on the host means the container gets no list at all.
    ENV.delete("NEOCLAW_OPERATORS")
    assert_empty Hub::Config.operators

    verbs = Hub::Commands::REGISTRY.keys.sort
    refute_empty verbs, "no verbs are registered, so this probe would pass vacuously"

    # Two senders, because "everybody" measured as one sender is trivially true: an
    # empty Set answers no to whichever single name you try, and one name cannot
    # tell that apart from a gate that would have said yes to the next one.
    senders = [SENDER, SECOND_SENDER]

    refusals = senders.map do |sender|
      verbs.map { |name| Hub::Commands.parse("!#{name}", sender: sender) }
    end

    senders.each_with_index do |sender, s|
      verbs.each_with_index do |name, i|
        assert_equal({ refused: sender, attempted: name }, refusals[s][i],
                     "!#{name} from #{sender} was not refused on a hub with no operators configured")
      end
    end

    # The decision is not the effect, and it is not one decision. Walk one refusal
    # from EACH sender through execute and read what would land in the room.
    posts = []
    senders.each_with_index do |sender, s|
      capture_posts do |sent|
        Hub::Commands.execute(refusals[s].first, room_id: ROOM, slug: "probe")
        posts.concat(sent)
      end
      assert_equal({ refused: sender, attempted: verbs.first }, refusals[s].first)
    end

    assert_equal senders.size, posts.size, "each refused sender gets exactly one notice"
    # Exactly this sentence, and nothing else, for each sender. `assert_includes`
    # measures "at least", so a fourth clause — an extra identity, a trailing hint —
    # would pass it; the room is shown this whole notice or the row is wrong. Pinned
    # to the verb that was actually refused rather than to a literal, because row (a)
    # refuses the first registered verb, whatever it is.
    senders.each_with_index do |sender, s|
      assert_equal "#{sender} is not an operator; !#{verbs.first} refused", posts[s]
    end

    puts "probe (a) unconfigured: #{verbs.size} verbs x #{senders.size} senders refused " \
         "(#{verbs.join(', ')}); senders=#{senders.join(', ')}; posted=#{posts.inspect}"
  end

  test "probe (b): a configured bare localpart matches nobody and warns exactly once, not per message" do
    # The deployed shape this was written for: a deployer writes `evans`, expecting
    # it to mean the operator. It cannot match a sender, because a sender is always
    # a full id. It fails closed — and it has to fail OUT LOUD at boot, once.
    ENV["NEOCLAW_OPERATORS"] = "evans"

    refused = Hub::Commands.parse("!freeze crew-1", sender: SENDER)
    assert_equal({ refused: SENDER, attempted: "freeze" }, refused,
                 "a bare localpart must not match the operator whose localpart it shares")

    lines = []
    reported = Hub::OperatorContract.report(entries: Hub::Config.operators, logger: recording_logger(lines))

    assert_equal false, reported, "the report says the list was not usable"
    assert_equal 1, lines.size, "one warning for one bad entry"

    warning = lines.first
    assert_includes warning, '"evans"', "the warning names the entry"
    assert_includes warning, "@localpart:server", "the warning names the required spelling"

    # The gate is per-message; the warning is not. Ten more messages must not add
    # ten more warnings: that is the difference between a boot check and a log
    # that grows with the traffic it is warning about.
    3.times { Hub::Commands.parse("!status", sender: SENDER) }
    assert_equal 1, lines.size, "the warning does not repeat per message"

    puts "probe (b) bare localpart: configured=evans; sender=#{SENDER}; " \
         "refused; warnings=#{lines.size}; message=#{warning.inspect}"
  end

  test "probe (c): a full Matrix ID executes the command, and a look-alike on another server still does not" do
    ENV["NEOCLAW_OPERATORS"] = SENDER

    ran = []
    Hub::Commands.register("probe-ack") do |args, room_id:, slug:|
      ran << { args: args, room_id: room_id, slug: slug }
      "ack #{args}"
    end

    begin
      command = Hub::Commands.parse("!probe-ack crew-1", sender: SENDER)
      assert_equal "probe-ack", command[:name], "a configured full id is admitted"
      assert_equal "crew-1", command[:args]

      posts = []
      capture_posts { |sent| Hub::Commands.execute(command, room_id: ROOM, slug: "probe"); posts = sent }

      assert_equal 1, ran.size, "the handler ran exactly once"
      assert_equal "crew-1", ran.first[:args], "the handler received the argument"
      assert_equal ROOM, ran.first[:room_id]
      assert_equal ["ack crew-1"], posts, "the handler's answer is what lands in the room"

      # The bypass the gate exists for: same localpart, different server.
      look_alike = Hub::Commands.parse("!probe-ack crew-1", sender: "@evans:evil.example")
      assert_equal({ refused: "@evans:evil.example", attempted: "probe-ack" }, look_alike)
      assert_empty ran.drop(1), "the look-alike reached no handler"

      puts "probe (c) configured: list=#{SENDER}; executed=probe-ack crew-1; " \
           "posts=#{posts.inspect}; look-alike @evans:evil.example refused"
    ensure
      Hub::Commands::REGISTRY.delete("probe-ack")
    end
  end
end
