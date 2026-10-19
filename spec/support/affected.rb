# frozen_string_literal: true

require "simplecov/affected"

# Requiring Affected prepends its lifecycle hooks into SimpleCov for the rest
# of this worker. They stay inert without a recorder, and `:off` keeps any
# other spec that starts test tracking from creating one, which would wire
# Affected into this very suite's RSpec configuration.
SimpleCov.affected(:off)

module AffectedHelpers
  # Runs the example with a live recorder, and puts the process back the way
  # it was afterwards.
  def with_recorder(root, coverage_path = File.join(root, "coverage"))
    recorder = SimpleCov::Affected::Recorder.new(root, coverage_path)
    SimpleCov::Affected.instance_variable_set(:@recorder, recorder)
    yield recorder
  ensure
    SimpleCov::Affected.instance_variable_set(:@recorder, nil)
  end
end
