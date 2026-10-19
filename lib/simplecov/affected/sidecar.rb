# frozen_string_literal: true

require "digest"
require "json"
require_relative "../atomic_file"

module SimpleCov
  module Affected
    #
    # The recording `require "simplecov/affected"` keeps beside the report, in
    # `coverage/.affected.json`. It is its own file rather than more keys in
    # `.resultset.json` or `coverage.json` because it holds what those two have
    # no place for (data files read, outcomes, times, the sources of test files
    # the report filters out), and because the selection must still work when
    # the report is HTML only.
    #
    # One test's record is one object, readable with a single `jq` call:
    #
    #   {"file": "spec/a_spec.rb", "line": 12, "ok": true, "time": 0.0021,
    #    "must_run": false, "reads": ["spec/fixtures/a.yml"],
    #    "lines": {"lib/a.rb": ["<source digest>", "<hex bitmap>"]}}
    #
    # Each bitmap is coverage.json's encoding (bit N is line N+1) and names the
    # version of the file it was recorded against, because a run that ran only
    # some tests leaves the others recorded against older sources. `files`
    # keeps every version some record still points at.
    #
    module Sidecar
      VERSION = 1
      NAME = ".affected.json"
      LOCKFILES = %w[Gemfile.lock gems.locked].freeze

      extend self

      def path(coverage_path)
        File.join(coverage_path, NAME)
      end

      def digest(text)
        Digest::SHA256.hexdigest(text)[0, 16] || ""
      end

      # nil for a file that is gone, which then differs from any digest.
      def file_digest(path)
        digest(File.binread(path))
      rescue SystemCallError
        nil
      end

      # What every record assumes: the Ruby and the resolved gems. The lockfile
      # stands in for the gems because the CLI that selects runs outside the
      # bundle, where the loaded specs are not the suite's.
      def env(root)
        parts = [RUBY_VERSION, RUBY_PLATFORM]
        LOCKFILES.each { |name| parts << file_digest(File.join(root, name)).to_s }
        digest(parts.join("\0"))
      end

      # nil for a missing, unreadable, or foreign file, which callers read as
      # "nothing recorded yet": every test runs and records afresh.
      def read(path)
        data = JSON.parse(File.read(path, encoding: Encoding::UTF_8))
        data if data.instance_of?(Hash) && data["version"].eql?(VERSION)
      rescue SystemCallError, JSON::ParserError
        nil
      end

      def write(path, data)
        AtomicFile.write(path, JSON.generate(data))
      end
    end
  end
end
