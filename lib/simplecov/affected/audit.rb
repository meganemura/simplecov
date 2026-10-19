# frozen_string_literal: true

require "json"
require_relative "../atomic_file"

module SimpleCov
  module Affected
    #
    # What `affected :audit` writes once every test has run: which of the
    # tests this run ran the selection would have skipped, and which of those
    # failed. A skipped test that failed is a change the selection missed, so
    # an audit job in CI checks the selection against the full suite before
    # anyone relies on `:select`.
    #
    #   {"full": null, "ran": 340, "selected": 12,
    #    "skipped": ["spec/a_spec.rb::A parses", ...],
    #    "skipped_failures": [],
    #    "reasons": {"spec/b_spec.rb::B reads": "def lib/b.rb 14", ...}}
    #
    module Audit
      NAME = ".affected-audit.json"

      extend self

      # `run` is the run's own recording, all its processes joined, or nil
      # when no test ran.
      def write(coverage_path, plan, run)
        report = report(plan, run ? run.fetch("tests") : {})
        AtomicFile.write(File.join(coverage_path, NAME), JSON.pretty_generate(report))
        $stderr.puts "SimpleCov affected audit: #{summary(report)}" # rubocop:disable Style/StderrPuts
      end

      def report(plan, tests)
        reasons = tests.keys.to_h { |id| [id, plan.reason(id)] }
        skipped = reasons.select { |_id, reason| reason.nil? }.keys
        {"full" => plan.full, "ran" => tests.size, "selected" => tests.size - skipped.size, "skipped" => skipped,
         "skipped_failures" => skipped.reject { |id| tests.fetch(id).fetch("ok") }, "reasons" => reasons.compact}
      end

      def summary(report)
        return "the selection would have run every test (#{report.fetch("full")})" if report.fetch("full")

        "the selection would have skipped #{report.fetch("skipped").size} of #{report.fetch("ran")} tests, " \
          "and #{report.fetch("skipped_failures").size} of those failed"
      end
    end
  end
end
