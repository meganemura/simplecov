# frozen_string_literal: true

require_relative "../../affected/merge"

module SimpleCov
  module CLI
    module Affected
      #
      # `simplecov affected merge <files...>`: folds the `.affected.json` each
      # shard of a CI build wrote into one recording, the way `simplecov merge`
      # folds their resultsets. Shards split one suite, so the recordings are
      # joined, never laid over one another: no shard's tests say anything
      # about another's.
      #
      # Shards recorded under different Rubies or lockfiles are refused rather
      # than joined, because the joined recording would claim one environment
      # for tests that ran under another.
      #
      module Shards
        extend CommandHelpers

        extend self

        def command_name = "affected merge"

        def run(args, stdout:, stderr:)
          opts = {output: SimpleCov::Affected::Sidecar.path(CLI.coverage_dir), quiet: false}
          files = build_parser do |parser|
            parser.on("--output PATH") { |value| opts[:output] = value }
            quiet_option(parser, opts)
          end.parse(args)
          return error(stderr, "missing input files") if files.empty?

          documents = read_all(files, stderr)
          documents ? write(documents, opts, stdout, stderr) : 1
        end

        def read_all(files, stderr)
          files.map do |path|
            SimpleCov::Affected::Sidecar.read(path) ||
              (return error_nil(stderr, "#{path} is not an affected recording (written by `require \"simplecov/affected\"`)"))
          end
        end

        def write(documents, opts, stdout, stderr)
          return error(stderr, "the inputs were recorded under different Rubies or lockfiles") unless documents.map { |document| document["env"] }.uniq.one?

          merged = SimpleCov::Affected::Merge.combine(documents)
          SimpleCov::Affected::Sidecar.write(opts.fetch(:output), merged.except("complete"))
          stdout.puts("simplecov affected merge: wrote #{opts.fetch(:output)}") unless opts.fetch(:quiet)
          0
        end
      end
    end
  end
end
