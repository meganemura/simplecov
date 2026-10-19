# frozen_string_literal: true

require_relative "../../affected/sidecar"
require_relative "../../affected/recorder"
require_relative "../../affected/plan"

module SimpleCov
  module CLI
    module Affected
      #
      # `simplecov affected` over a recording from `require
      # "simplecov/affected"`, used whenever `.affected.json` sits beside the
      # input. The recording selects single tests by what each ran, read, and
      # reached by name, and compares every recorded version of a file with the
      # working tree, so no git ref is involved and `--base` has nothing to do.
      #
      # Stdout keeps the contract of the report-only path: the test files that
      # hold a selected test, plus the test files the recording does not know,
      # one per line, and nothing at all on a full run, which a bare runner
      # reads as "run everything". `--json` names each selected test and why.
      #
      module Recorded
        extend CommandHelpers

        extend self

        def command_name = "affected"

        def sidecar(input)
          path = SimpleCov::Affected::Sidecar.path(File.dirname(input))
          path if File.file?(path)
        end

        def run(path, opts, stdout:, stderr:)
          stderr.puts("simplecov affected: --base is ignored, #{path} compares each test with the working tree") if opts.fetch(:base)
          document = SimpleCov::Affected::Sidecar.read(path)
          return error(stderr, "#{path} is not an affected recording (written by `require \"simplecov/affected\"`)") unless document

          coverage = File.dirname(path)
          root = Dir.exist?(document.fetch("root").to_s) ? document.fetch("root") : Dir.pwd
          plan = SimpleCov::Affected::Plan.decide(document, root, coverage)
          return full(plan.full, opts, root, stdout, stderr) if plan.full

          deliver(selection(plan, document, root, coverage), opts, root, stdout, stderr)
        end

        def full(reason, opts, root, stdout, stderr)
          stderr.puts("simplecov affected: running every test (#{reason})")
          return emit(stdout, "full" => reason) if opts.fetch(:json)
          return Affected.run_command(opts.fetch(:run), root, stderr) if opts.fetch(:run)

          0
        end

        # The test files of the selected tests, and the test files the
        # recording has never seen, whose tests are all new.
        def selection(plan, document, root, coverage)
          tests = plan.reasons.compact
          recorder = SimpleCov::Affected::Recorder.new(root, coverage)
          known = document.fetch("files").keys | document.fetch("unloaded").keys | document.fetch("unmeasured").keys
          added = Dir.glob("**/*.rb", base: root).select { |file| recorder.test_file(File.join(root, file)) } - known
          {"full" => nil, "tests" => tests, "files" => tests.keys.map { |id| id.split("::", 2).first.to_s }.uniq.sort,
           "new_files" => added.sort, "skipped" => plan.reasons.size - tests.size}
        end

        def deliver(selection, opts, root, stdout, stderr)
          return emit(stdout, selection) if opts.fetch(:json)

          files = selection.fetch("files") | selection.fetch("new_files")
          return Affected.note_untouched(stderr) if files.empty?
          return Affected.run_command(opts.fetch(:run) + files, root, stderr) if opts.fetch(:run)

          files.each { |file| stdout.puts(file) }
          0
        end

        def emit(stdout, document)
          stdout.puts(JSON.pretty_generate(document))
          0
        end
      end
    end
  end
end
