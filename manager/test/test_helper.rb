ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # The Manager's suite touches the filesystem and the ledger table only;
    # keep it serial so tmpdir/fixture state cannot race.
    self.use_transactional_tests = true

    fixtures :all
  end
end
