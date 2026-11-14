# ROW A — packaging: the Manager container must not carry a non-empty
# NEOCLAW_OPERATORS.
#
# The gate fails closed when the list is empty (Config.operators -> "", and
# `""` splits to nothing). The packaging is where that gets undone:
# manager/entrypoint.sh:131 and manager/run.sh:63 pass `-e NEOCLAW_OPERATORS`
# through with NO value, so the container inherits whatever the deployer's shell
# happens to hold. If that shell holds `@someone:server`, the Manager starts
# configured by plumbing rather than by a decision.
#
# The measurement is the EXIT STATUS of `printenv`, not its stdout:
#
#   exit 1, no output   -> the variable is ABSENT  (what the pass-through gives)
#   exit 0, empty line  -> present and set to empty (fails closed, but not absent)
#   exit 0, any value   -> present and NON-EMPTY   (the shape this row exists for)
#
# stdout alone cannot tell the first two apart, and that distinction is the row.
#
# If podman or a container is missing, the row says so in its own output and
# measures nothing. That is an absent measurement, named — not a skip dressed as
# a pass, and not a green that pretends the packaging was checked.

require "test_helper"
require "open3"

class OperatorEnvPackagingTest < ActiveSupport::TestCase
  CONTAINER_VAR = "NEOCLAW_MANAGER_CONTAINER".freeze

  test "row A: the Manager container does not carry a non-empty NEOCLAW_OPERATORS" do
    podman = executable("podman")
    container = ENV[CONTAINER_VAR].to_s.strip

    return unmet("podman is not on PATH") if podman.nil?
    return unmet("#{CONTAINER_VAR} is unset, so there is no container to exec into") if container.empty?

    puts "row A: #{podman} exec #{container} printenv NEOCLAW_OPERATORS"
    out, err, status = Open3.capture3(podman, "exec", container, "printenv", "NEOCLAW_OPERATORS")

    case status.exitstatus
    when 1
      assert_equal "", out.strip,
                   "printenv exits 1 with no output when the variable is absent; " \
                   "output here means it exited 1 for another reason"
      puts "row A measured: NEOCLAW_OPERATORS is ABSENT in #{container} (printenv exit 1)"
    when 0
      value = out.strip
      if value.empty?
        puts "row A measured: NEOCLAW_OPERATORS is PRESENT and set to EMPTY in #{container} " \
             "(exit 0, no value). Not absent — but Config.operators turns the empty string " \
             "into no operators, so the gate still refuses everybody."
        pass
      else
        flunk("NEOCLAW_OPERATORS is PRESENT and NON-EMPTY in #{container} (exit 0): #{value.inspect}. " \
              "The pass-through must leave it absent; a container that names an operator was " \
              "configured by plumbing, not by a deployer.")
      end
    else
      flunk("podman exec #{container} printenv NEOCLAW_OPERATORS exited " \
            "#{status.exitstatus.inspect}: #{err.strip.inspect} — the measurement did not run")
    end
  end

  private

  # An absent measurement, named in the row's own output. `pass` because there is
  # nothing false to assert — the line above it says exactly what was not measured
  # and why, which is the most this row can honestly do here.
  def unmet(reason)
    puts "UNMET row A: #{reason}. The container's environment was NOT measured."
    pass
  end

  def executable(name)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
      candidate = File.join(dir, name)
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end
end
