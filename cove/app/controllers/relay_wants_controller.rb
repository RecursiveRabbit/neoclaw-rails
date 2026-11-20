class RelayWantsController < ApplicationController
  # The relay's build list, read out of the log the app itself wrote.
  # Nothing here is computed about the world; it is a reading of a file.
  def index
    @wants = WantsLog.summary
    @declared = Relay::WANTS
    @relay_template = Relay.template
    @log_exists = File.exist?(Cove.wants_file)
  end
end
