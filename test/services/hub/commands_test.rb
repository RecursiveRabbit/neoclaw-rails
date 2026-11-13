# The bot's operator gate.
#
# Evans, 2026-11-12: *"No fallbacks. Fallbacks are an illegal concept. If something
# about that system is failing I need to know, not have some agent smooth it
# over."* Two fallbacks lived in this gate and both are gone: an unconfigured hub
# admitted two hardcoded owners, and the comparison ran on the localpart, so
# `@evans:any.federated.server` read as `evans` and passed.
#
# Four rows: the gate's three states, and the shape the old deployment produced (a
# bare localpart in the environment), because that one fails closed and has to
# fail visibly rather than quietly matching nobody.

require "test_helper"

class HubCommandsTest < ActiveSupport::TestCase
  setup do
    @saved = ENV["NEOCLAW_OPERATORS"]
  end

  teardown do
    ENV["NEOCLAW_OPERATORS"] = @saved
  end

  test "an unconfigured hub refuses every operator command, and names the identity" do
    # producing line: manager/entrypoint.sh:131 and manager/run.sh:63 — `-e NEOCLAW_OPERATORS`
    # with no value. With the variable unset on the host, neither shell sets it in the
    # container, so the delete below is the deployment's own state and not a made one.
    ENV.delete("NEOCLAW_OPERATORS")
    assert_empty Hub::Config.operators

    refused = Hub::Commands.parse("!freeze crew-1", sender: "@evans:matrix.home")

    assert_equal({ refused: "@evans:matrix.home", attempted: "freeze" }, refused)
    assert_nil Hub::Commands.parse("hello there", sender: "@evans:matrix.home"),
               "a message that is not a command is still just a message"
  end

  test "a configured sender passes on its exact identity" do
    # producing line: manager/entrypoint.sh:131 / manager/run.sh:63 — the same
    # pass-through, with the variable set on the host by whoever deploys.
    ENV["NEOCLAW_OPERATORS"] = "@evans:matrix.home"

    command = Hub::Commands.parse("!freeze crew-1", sender: "@evans:matrix.home")

    assert_equal "freeze", command[:name]
    assert_equal "crew-1", command[:args]
    assert_equal "@evans:matrix.home", command[:sender]
  end

  test "a look-alike on another server is refused, and the refusal names it" do
    # producing line: as above — a configured deployment, a sender from elsewhere.
    ENV["NEOCLAW_OPERATORS"] = "@evans:matrix.home"

    refused = Hub::Commands.parse("!freeze crew-1", sender: "@evans:evil.example")

    assert_equal "@evans:evil.example", refused[:refused]
    refute refused.key?(:name), "a refusal is not a command"
  end

  test "a bare localpart in the environment matches nobody, which is the safe direction" do
    # producing line: manager/entrypoint.sh:131 / manager/run.sh:63 — the pass-through
    # set to `evans,hopper`, the shape the shell used to inject itself. Nothing produces
    # it now except a deployer writing it, which is why it is still worth a row: it must
    # not quietly match, and the refusal shows the operator the id that was compared, so
    # the misconfiguration names itself instead of looking like a refusal.
    ENV["NEOCLAW_OPERATORS"] = "evans,hopper"

    refused = Hub::Commands.parse("!freeze crew-1", sender: "@evans:matrix.home")

    assert_equal "@evans:matrix.home", refused[:refused]
  end
end
