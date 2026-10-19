# frozen_string_literal: true

module SimpleCov
  module Affected
    #
    # What one process records beside SimpleCov's own ContextMap: each test's
    # outcome, time, and the data files it read, and which test file a stretch
    # of code ran for. The lines themselves stay SimpleCov's: the tracker
    # already peeks once per test without clearing the counters, so the report
    # totals stay whole, and this class only names the contexts.
    #
    # Three kinds of context reach the map besides the tests. `(boot)` is
    # everything from the start of tracking to the first test file, which no
    # test owns. A test file's own path is the code that ran while it loaded
    # and in its example groups' `before(:context)` and `after(:context)`
    # hooks, which serves every test of that file. Both are opened as empty
    # `track_test` calls: the tracker keeps a segment open until the next
    # boundary, so the code after the marker belongs to it without wrapping
    # anything.
    #
    class Recorder
      BOOT = "(boot)"
      TEST_FILE = /\A(?:test_.*|spec_.*|.*_(?:test|spec))\.rb\z/
      SKIPPED_DIRS = %w[.git .bundle vendor tmp log node_modules].freeze

      Test = Struct.new(:file, :line, :ok, :time, :must_run, :reads)

      attr_reader :tests, :loads, :boot_reads

      def initialize(root, coverage_path)
        @prefix = File.join(root, "")
        @coverage_prefix = File.join(coverage_path, "")
        @tests = {} #: Hash[String, Test]
        @loads = {} #: Hash[String, Set[String]]
        @boot_reads = Set.new #: Set[String]
        @sink = @boot_reads #: Set[String]?
        @narrowed = Set.new #: Set[String]
        @filtered = false
      end

      def start
        SimpleCov.track_test(BOOT) {}
      end

      # Records the block as one test. The block answers whether the test
      # passed, so each runner keeps its own notion of a pass.
      def test(id, file:, line:, must_run: false)
        reads = Set.new #: Set[String]
        outer = @sink
        @sink = reads
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_second)
        ok = false
        begin
          ok = yield
        ensure
          @sink = outer
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_second) - started
          @tests[id] = Test.new(file, line, ok, elapsed.round(6).to_f, must_run, reads)
        end
      end

      # Wraps the loading of a file that is a test file, so the code it runs as
      # it loads (a `property :x, coerce: Symbol` at the top of a spec) is
      # charged to that file's tests rather than to no one.
      def loading(path, &)
        file = test_file(path)
        return yield unless file

        outer = @sink
        @sink = (@loads[file] ||= Set.new)
        begin
          SimpleCov.track_test(file, &)
        ensure
          @sink = outer
        end
      end

      # From here to the next test, code and reads serve the tests of `file`.
      def boundary(file)
        @sink = (@loads[file] ||= Set.new)
        SimpleCov.track_test(file) {}
      end

      def read(path)
        sink = @sink or return
        relative = project_file(path)
        sink << relative if relative && !relative.end_with?(".rb")
      end

      # A test file some of whose tests were left out on purpose, by the
      # selection or by the runner's own filter, still defines the ids it did
      # not run; only a file whose every test ran may drop recorded ids.
      def narrowed(file)
        @narrowed << file
      end

      def filtered!
        @filtered = true
      end

      def complete
        return [] if @filtered

        ((@loads.keys | @tests.each_value.filter_map(&:file)) - @narrowed.to_a).sort
      end

      # Reads after this point are SimpleCov's own (sources, templates, the
      # report), never a test's.
      def stop_reading
        @sink = nil
      end

      def test_file(path)
        relative = project_file(path)
        relative if relative && TEST_FILE.match?(File.basename(relative))
      end

      # Root-relative, or nil for anything outside the project or in a
      # directory that holds no project source (dependencies, scratch, logs,
      # the coverage output itself).
      def project_file(path)
        absolute = File.expand_path(path.to_s)
        return nil unless absolute.start_with?(@prefix) && !absolute.start_with?(@coverage_prefix)

        relative = absolute.delete_prefix(@prefix)
        relative unless SKIPPED_DIRS.include?(relative.split("/", 2).first)
      end
    end
  end
end
