# frozen_string_literal: true

module SimpleCov
  module Affected
    # Prepended to File's singleton class: a project file a test opens for
    # reading through the File API (YAML.load_file, ERB templates, fixture
    # loaders all reach these) is a file the test depends on.
    module ReadHook
      WRITING = /[wa+]/

      def self.note(path, mode)
        writing = mode.is_a?(String) ? WRITING.match?(mode) : mode.is_a?(Integer) && mode.anybits?(File::WRONLY | File::RDWR)
        Affected.recorder&.read(path) if !writing && (path.is_a?(String) || path.respond_to?(:to_path))
      end

      def open(path = nil, *args, **kwargs, &)
        ReadHook.note(path, kwargs.fetch(:mode, args.first))
        super
      end

      def read(path = nil, *args, **kwargs, &)
        ReadHook.note(path, kwargs.fetch(:mode, args.first))
        super
      end

      def binread(path = nil, *args, **kwargs, &)
        ReadHook.note(path, nil)
        super
      end

      def readlines(path = nil, *args, **kwargs, &)
        ReadHook.note(path, kwargs.fetch(:mode, nil))
        super
      end

      def foreach(path = nil, *args, **kwargs, &)
        ReadHook.note(path, kwargs.fetch(:mode, nil))
        super
      end

      def new(path = nil, *args, **kwargs, &)
        ReadHook.note(path, kwargs.fetch(:mode, args.first))
        super
      end
    end

    # Prepended to Kernel: RSpec loads spec files with `load`, and Minitest
    # suites `require` theirs. `require_relative` is left alone, because a
    # prepended method would resolve the path against this file.
    module LoadHook
      private

      def load(file, *)
        recorder = Affected.recorder
        recorder ? recorder.loading(file) { super } : super
      end

      def require(feature)
        recorder = Affected.recorder
        recorder ? recorder.loading(feature) { super } : super
      end
    end

    # Prepended to TestTracker: the segment model keeps one context open from
    # one boundary to the next, so code that belongs to another context in
    # the middle of a test is set aside by closing the test's segment, opening
    # the other one, and reopening the test's after it. Only the thread that
    # runs the tests moves the segment; another thread's code stays where it
    # lands.
    module TrackerAside
      def aside(id)
        previous = @segment&.id
        return yield if previous.nil? || previous.eql?(id) || poisoned? || !(@depth.zero? || @owner.equal?(Thread.current))

        open_segment(id)
        begin
          yield
        ensure
          open_segment(previous) unless poisoned?
        end
      end
    end

    # Prepended to Process's singleton class, beside SimpleCov's own fork hook.
    module ForkHook
      def _fork
        pid = super
        Affected.recorder&.forked if pid.zero?
        pid
      end
    end

    # Prepended to TestTracker's singleton class: the contexts are named by
    # stable test ids, and Affected's runner integration goes in beside
    # SimpleCov's own, inside it.
    module TrackerHooks
      def rspec_example_id(example)
        Affected.recorder ? example.metadata.fetch(:affected_id) { super } : super
      end

      def minitest_test_id(test)
        Affected.recorder ? Minitest.id(test.class, test.name) : super
      end

      def install_minitest_hook(*)
        installed = super
        Affected.install_minitest
        installed
      end
    end

    # Prepended to SimpleCov's singleton class, at the points of the run
    # Affected hangs on: tracking starts, this process's result exists, and
    # the final result exists.
    module Lifecycle
      def start_test_tracking
        started = super
        Affected.start
        started
      end

      def collect_own_coverage(standalone:)
        collected = super
        own = current_run.result
        Affected.capture(own) if Affected.recorder && own
        collected
      end

      def result
        fresh = !current_run.result?
        final = super
        Affected.finish if fresh && Affected.recorder && final_result_process?
        final
      end
    end
  end
end
