ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # No fixtures call: `fixtures` is defined by ActiveRecord::TestFixtures, and
    # this app has no database, so the generated line raised NoMethodError before
    # a single test loaded. There are no fixture files to load either —
    # test/fixtures/ holds only files/.keep — so this removes nothing from the run.

    # Add more helper methods to be used by all tests here...
  end
end
