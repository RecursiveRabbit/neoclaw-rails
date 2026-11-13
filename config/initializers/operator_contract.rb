# Names a misconfigured operator list at boot, before anyone types a command into a
# bot that will ignore them.
#
# Warns only. The gate fails closed either way and the process must start, so the
# operator can read the log and see which of the two faults they have:
#
#   "is unset or empty"             - nobody configured an operator
#   "cannot match any sender"       - somebody configured a bare localpart
#
# Rows that prove this lives at test/services/hub/operator_contract_test.rb;
# the contract itself is documented in docs/HUB-ENVIRONMENT.md.
Rails.application.config.after_initialize do
  Hub::OperatorContract.report
end
