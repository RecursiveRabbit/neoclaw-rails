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
#   exit 1, no output   -> the variable is ABSENT  (the bare `-e` form)   PASS
#   exit 0, empty line  -> present and set to empty (the `-e VAR=` form)  PASS
#   exit 0, any value   -> present and NON-EMPTY                          FAIL
#
# Absent and present-and-empty both pass: both leave Config.operators empty and
# the gate refusing everybody, so failing either would be a false red. A VALUE
# is the only form that configures an owner by plumbing, and that is what this
# row exists to catch. The row prints which of the three forms it saw, so the
# badge is not the only place the answer lives.
#
# What this row does NOT prove: that the launch scripts use the bare form. That
# is a different row (the argument list, not the container).
#
# When it cannot measure, it SKIPS — which appears in the summary line as
# `1 skips`, a number that tells the truth — unless a container was named and
# podman is missing, which is a FAIL: the intent to measure was declared, the
# tool was absent, and nothing was measured.

require "test_helper"
require "open3"

class OperatorEnvPackagingTest < ActiveSupport::TestCase
  CONTAINER_VAR = "NEOCLAW_MANAGER_CONTAINER".freeze

  test "row A: the Manager container does not carry a non-empty NEOCLAW_OPERATORS" do
    container = ENV[CONTAINER_VAR].to_s.strip
    podman = executable("podman")

    # Intent first. Naming a container is the strongest statement that someone
    # meant this to be measured, so a missing tool is red rather than a skip.
    if podman.nil? && !container.empty?
      flunk("#{CONTAINER_VAR}=#{container.inspect} names a container to measure, but podman is not on " \
            "PATH — the container's environment was NOT measured, and a declared measurement that " \
            "cannot run is a failure, not an absence.")
    end
    if podman.nil?
      skip("UNMET row A: podman is not on PATH. The container's environment was NOT measured.")
    end
    if container.empty?
      skip("UNMET row A: #{CONTAINER_VAR} is unset, so there is no container to exec into. " \
           "The container's environment was NOT measured.")
    end

    puts "row A: #{podman} exec #{container} printenv NEOCLAW_OPERATORS"
    out, err, status = Open3.capture3(podman, "exec", container, "printenv", "NEOCLAW_OPERATORS")

    case status.exitstatus
    when 1
      assert_equal "", out.strip,
                   "printenv exits 1 with no output when the variable is absent; " \
                   "output here means it exited 1 for another reason"
      puts "row A measured: NEOCLAW_OPERATORS is ABSENT in #{container} (printenv exit 1) — the bare -e form"
    when 0
      value = out.strip
      if value.empty?
        puts "row A measured: NEOCLAW_OPERATORS is PRESENT and set to EMPTY in #{container} " \
             "(exit 0, no value) — the `-e VAR=` form. Config.operators turns the empty string " \
             "into no operators, so the gate still refuses everybody."
        pass
      else
        flunk("NEOCLAW_OPERATORS is PRESENT and NON-EMPTY in #{container} (exit 0): #{value.inspect}. " \
              "The pass-through must leave it absent or empty; a container that names an operator was " \
              "configured by plumbing, not by a deployer.")
      end
    else
      flunk("podman exec #{container} printenv NEOCLAW_OPERATORS exited " \
            "#{status.exitstatus.inspect}: #{err.strip.inspect} — the measurement did not run")
    end
  end

  private

  def executable(name)
    ENV["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
      candidate = File.join(dir, name)
      return candidate if File.file?(candidate) && File.executable?(candidate)
    end
    nil
  end
end
