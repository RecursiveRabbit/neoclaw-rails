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
end
