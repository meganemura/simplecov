# frozen_string_literal: true

require_relative "sidecar"

module SimpleCov
  module Affected
    #
    # The selection for one run, decided once, as tracking starts: before any
    # test file loads or edits a file, and before Affected hooks file reads,
    # so the selection's own reads of the project are not charged to the
    # boot context of the run it decides. A forked worker inherits it.
    #
    # Each test runs for a reason or not at all. A test the recording does not
    # know is `new` and always runs, which is also how a test whose recorded
    # file was not fully run, or that was dropped as stale, comes back.
    #
    class Plan
      NEW = "new"
      FULL = "full"

      attr_reader :full, :reasons

      def self.load(root, coverage_path)
        document = Sidecar.read(Sidecar.path(coverage_path))
        document ? decide(document, root, coverage_path) : new("no recording", {})
      end

      # A selection that fails runs the whole suite and says why, rather than
      # stopping a suite that would otherwise pass.
      def self.decide(document, root, coverage_path)
        require_relative "tree"
        require_relative "selection"
        result = Selection.call(document, Tree.new(root, coverage_path))
        new(result.full, result.reasons)
      rescue => e
        new("the selection failed: #{e.class}: #{e.message}", {})
      end

      def initialize(full, reasons)
        @full = full
        @reasons = reasons
      end

      # Why the test runs, or nil when no change reaches it.
      def reason(id)
        full ? FULL : reasons.fetch(id, NEW)
      end

      def summary
        return "running every test (#{full})" if full

        "running #{reasons.count { |_id, reason| reason }} of #{reasons.size} recorded tests, and any new ones"
      end
    end
  end
end
