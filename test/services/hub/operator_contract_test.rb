require "test_helper"

# The words, not the gate. The gate's own rows are in commands_test.rb and this file
# must never be read as covering them: nothing here admits or refuses a command.
class HubOperatorContractTest < ActiveSupport::TestCase
  # An instance helper, not a class method: a bare `entries(...)` inside a test block
  # resolves against the instance, and `def self.entries` would be invisible there
  # (learned from CI, run 43478908670 - six NoMethodErrors and two passing tests).
  def entries(*ids)
    ids.to_set
  end

  test "an empty list is one problem, and it is the unconfigured one" do
    problems = Hub::OperatorContract.problems(Set.new)

    assert_equal 1, problems.size
    assert_equal :unconfigured, problems.first[:kind]
  end

  test "a full Matrix ID is no problem at all" do
    assert_empty Hub::OperatorContract.problems(entries("@evans:matrix.home"))
  end

  test "a server may carry a port" do
    assert_empty Hub::OperatorContract.problems(entries("@evans:matrix.home:8448"))
  end

  test "bare localparts are unmatchable, and both are named" do
    problems = Hub::OperatorContract.problems(entries("evans", "hopper"))

    assert_equal 1, problems.size
    assert_equal :unmatchable, problems.first[:kind]
    assert_equal %w[evans hopper], problems.first[:entries].sort
  end

  test "a mixed list names only the entries that cannot match" do
    problems = Hub::OperatorContract.problems(entries("@evans:matrix.home", "hopper"))

    assert_equal ["hopper"], problems.first[:entries].sort
  end

  test "the two faults are worded differently, because the fix is different" do
    unconfigured = Hub::OperatorContract.message({ kind: :unconfigured })
    unmatchable = Hub::OperatorContract.message({ kind: :unmatchable, entries: ["evans"] })

    assert_match(/unset or empty/, unconfigured)
    assert_match(/NEOCLAW_OPERATORS=@evans:matrix\.home/, unconfigured)
    assert_match(/cannot match any sender/, unmatchable)
    assert_match(/"evans"/, unmatchable)
    refute_equal unconfigured, unmatchable
  end

  test "singular and plural are both spelled as words" do
    one = Hub::OperatorContract.message({ kind: :unmatchable, entries: ["evans"] })
    two = Hub::OperatorContract.message({ kind: :unmatchable, entries: %w[evans hopper] })

    assert_match(/1 entry that/, one)
    assert_match(/2 entries that/, two)
  end

  test "a bare localpart is one problem, named" do
    problems = Hub::OperatorContract.problems(entries("evans"))

    assert_equal 1, problems.size
    assert_equal ["evans"], problems.first[:entries]
  end

  test "report logs one warning per problem and returns whether the list was usable" do
    logged = []
    logger = Struct.new(:sink) do
      def warn(message)
        sink << message
      end
    end.new(logged)

    refute Hub::OperatorContract.report(entries: entries("evans"), logger: logger)
    assert_equal 1, logged.size

    assert Hub::OperatorContract.report(entries: entries("@evans:matrix.home"), logger: logger)
    assert_equal 1, logged.size, "a usable list must add no warning"
  end

  # The wiring, not the words. Every row above calls `report`; none of them touches
  # the initializer that calls it at boot, so "warns at boot" was proven for the
  # module and unproven for the wiring.
  #
  # How the boot is observed, and why not the two obvious ways. The hook list is not
  # readable: `Rails.application.config.after_initialize` called without a block RUNS
  # the hooks, and inside a booted suite it raises from ActiveSupport's own runner
  # ("undefined method 'call' for nil", run 43597828749 / job 132456010050). Booting a
  # second process from here does not terminate (run 43598275411, cancelled), because
  # this app is not built to be booted and thrown away. What is left is the artefact
  # boot already wrote: the suite boots the app once, before any test, and that boot's
  # warning went into this process's own log file.
  #
  # Covered: that boot really runs the contract, with the list unset — the state CI
  # boots in. Not covered: the words for each state (the rows above) or the boot with
  # a bad-but-present list (not observed here, and not claimable from one boot).
  test "the initializer ran at boot and warned into this process's own log" do
    if ENV["NEOCLAW_OPERATORS"].to_s.strip.empty?
      logs = Dir[Rails.root.join("log", "*.log")]
      refute_empty logs, "no log file under log/ — the boot log is not where this row looks, so nothing was measured"

      contents = logs.map { |path| File.read(path) }.join("\n")
      assert_includes contents, "NEOCLAW_OPERATORS is unset or empty",
                      "boot did not run config/initializers/operator_contract.rb"
    else
      skip "NEOCLAW_OPERATORS is set here, so this row's state (unset at boot) is not the state CI booted in"
    end
  end
end
