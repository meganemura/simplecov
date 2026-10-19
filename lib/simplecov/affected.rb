# frozen_string_literal: true

require_relative "../simplecov"
require_relative "affected/sidecar"
require_relative "affected/recorder"
require_relative "affected/capture"
require_relative "affected/merge"
require_relative "affected/parts"
require_relative "affected/plan"
require_relative "affected/audit"
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
  # also narrows to the tests a change can affect (`:select`), or runs them
  # all and writes down what narrowing would have left out (`:audit`).
  #
  module Affected
    extend self

    attr_reader :recorder, :plan

    # Once per process tree, once tracking has a tracker: a forked worker
    # inherits the recorder, its hooks, its open boot segment, and the plan.
    # The plan comes first, before reads are hooked.
    def start
      mode = SimpleCov.affected
      return if @recorder || SimpleCov.test_tracker.nil? || mode.equal?(:off)

      @mode = mode
      plan = @plan = Plan.load(SimpleCov.root, SimpleCov.coverage_path) unless mode.equal?(:all)
      $stderr.puts "SimpleCov affected: #{plan.summary}" if plan && mode.equal?(:select) # rubocop:disable Style/StderrPuts
      recorder = @recorder = Recorder.new(SimpleCov.root, SimpleCov.coverage_path)
      File.singleton_class.prepend(ReadHook)
      LoadHook.install
      recorder.start
      RSpec.install(TestTracker.rspec_module, narrow: narrowing?)
      install_minitest
    end

    def install_minitest
      Minitest.install(::Minitest::Test, narrow: narrowing?) if @recorder && defined?(::Minitest::Test)
    end

    # Only `:select` leaves tests out, and only when the plan names some.
    def narrowing?
      plan = @plan
      !!(plan && @mode.equal?(:select) && !plan.full)
    end

    # Whether this run runs the test, asked by the runners' filters. A test
    # left out narrows its file: the file still defines the ids it skipped,
    # so the recording keeps their records.
    def run?(id)
      plan = @plan
      return true if plan.nil? || plan.reason(id)

      @recorder&.narrowed(id.split("::", 2).first.to_s)
      false
    end

    # Before SimpleCov collects this process's coverage, which first compiles
    # the templates no test rendered (`cover_views`): that is SimpleCov's own
    # work, so it reads into no context and runs in no segment, rather than
    # in the last test's.
    def settle
      @recorder&.stop_reading
      SimpleCov.test_tracker&.close
    end

    def capture(result)
      recorder = @recorder
      return unless recorder

      recorder.stop_reading
      captured = Capture.call(recorder, result, SimpleCov.root, run: SimpleCov.run_id.to_s, globals: SimpleCov.affected_globals)
      Parts.write(SimpleCov.coverage_path, SimpleCov.run_id, Process.pid, captured) if captured
    end

    def finish
      run = Parts.finish(SimpleCov.coverage_path, SimpleCov.run_id, SimpleCov.root, timeout: SimpleCov.merge_timeout)
      plan = @plan
      Audit.write(SimpleCov.coverage_path, plan, run) if plan && @mode.equal?(:audit)
    end
  end
end

SimpleCov.singleton_class.prepend(SimpleCov::Affected::Lifecycle)
SimpleCov::TestTracker.singleton_class.prepend(SimpleCov::Affected::TrackerHooks)
SimpleCov::TestTracker.prepend(SimpleCov::Affected::TrackerAside)
Process.singleton_class.prepend(SimpleCov::Affected::ForkHook)
SimpleCov::Affected.start
