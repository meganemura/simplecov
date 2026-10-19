# frozen_string_literal: true

require_relative "../simplecov"
require_relative "affected/sidecar"
require_relative "affected/recorder"
require_relative "affected/capture"
require_relative "affected/merge"
require_relative "affected/parts"
require_relative "affected/hooks"
require_relative "affected/rspec"
require_relative "affected/minitest"

module SimpleCov
  #
  # Test selection on top of `track_tests`, loaded by
  # `require "simplecov/affected"` before `SimpleCov.start`. It names each
  # recorded context by a stable test id instead of `file:line`, charges the
  # code test files run as they load to those files' tests, records outcomes,
  # times, and data-file reads, and keeps all of it in
  # `coverage/.affected.json`. The `affected` setting decides whether a run
  # also narrows to the tests a change can affect.
  #
  module Affected
    extend self

    attr_reader :recorder

    # Once per process tree, once tracking has a tracker: a forked worker
    # inherits the recorder, its hooks, and its open boot segment.
    def start
      return if @recorder || SimpleCov.test_tracker.nil? || SimpleCov.affected.equal?(:off)

      recorder = @recorder = Recorder.new(SimpleCov.root, SimpleCov.coverage_path)
      File.singleton_class.prepend(ReadHook)
      Kernel.prepend(LoadHook)
      recorder.start
      RSpec.install(TestTracker.rspec_module)
      install_minitest
    end

    def install_minitest
      Minitest.install(::Minitest::Test) if @recorder && defined?(::Minitest::Test)
    end

    def capture(result)
      recorder = @recorder
      return unless recorder

      recorder.stop_reading
      captured = Capture.call(recorder, result, SimpleCov.root, run: SimpleCov.run_id.to_s)
      Parts.write(SimpleCov.coverage_path, SimpleCov.run_id, Process.pid, captured) if captured
    end

    def finish
      Parts.finish(SimpleCov.coverage_path, SimpleCov.run_id, SimpleCov.root, timeout: SimpleCov.merge_timeout)
    end
  end
end

SimpleCov.singleton_class.prepend(SimpleCov::Affected::Lifecycle)
SimpleCov::TestTracker.singleton_class.prepend(SimpleCov::Affected::TrackerHooks)
SimpleCov::Affected.start
