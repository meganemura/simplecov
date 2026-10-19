# frozen_string_literal: true

require_relative "statics"
require_relative "version"

module SimpleCov
  module Affected
    #
    # A sidecar document with the lookups the selection makes over and over:
    # a version of a file by digest, the tests of a test file, and per run the
    # names every file loaded in it defined, mentioned, and required.
    #
    class Recording
      Index = Struct.new(:known, :uses, :requires)

      attr_reader :document

      def initialize(document)
        @document = document
        @versions = {} #: Hash[[String, String], Version?]
        @indexes = {} #: Hash[String, Index]
      end

      def tests = @document.fetch("tests")

      def loads = @document.fetch("loads")

      def reads = @document.fetch("reads")

      # nil for a version the recording does not hold.
      def version(path, digest)
        @versions.fetch([path, digest]) do
          lines = @document.dig("files", path, digest, "source")
          @versions[[path, digest]] = lines && Version.new(path, lines.map { |line| "#{line}\n" }.join)
        end
      end

      def hits(path, digest)
        @document.dig("files", path, digest, "lines") || []
      end

      def snapshot(run)
        @document.fetch("runs").fetch(run.to_s) { @document.fetch("latest") }
      end

      def test_files
        @test_files ||= tests.each_value.to_set { |test| test.fetch("file") }
      end

      def tests_of(file)
        @tests_of ||= tests.each_value.group_by { |test| test.fetch("file") }
        @tests_of.fetch(file, [])
      end

      # The top directories that hold recorded test files (`spec`, `test`): a
      # new file there is a helper or a test, never library code.
      def test_dir?(path)
        @test_dirs ||= test_files.to_set { |file| file.split("/", 2).first }
        @test_dirs.include?(path.split("/", 2).first)
      end

      def known
        @known ||= @document.fetch("files").keys.to_set | @document.fetch("unmeasured").keys | @document.fetch("unloaded").keys
      end

      # What the files one run loaded define, mention, and require. Test files'
      # mentions are left out: a name a test file uses changes only that file.
      def index(run)
        @indexes[run.to_s] ||= begin
          known = Hash.new { |hash, key| hash[key] = Set.new } #: Hash[String, Set[String]]
          uses = Hash.new { |hash, token| hash[token] = [] } #: Hash[String, Array[[String, String]]]
          requires = Hash.new(0) #: Hash[String, Integer]
          snapshot(run).each do |path, digest|
            statics = version(path, digest)&.statics # simplecov:disable branch -- a run's versions are kept with it
            next unless statics

            statics.names.each { |key, sums| known[key].merge(sums) }
            statics.requires.each { |kind, feature| requires[yield(path, kind, feature)] += 1 }
            next if test_files.include?(path)

            statics.mentions.each { |key, tokens| tokens.each { |token| uses[token] << [path, key] } }
          end
          Index.new(known, uses, requires)
        end
      end
    end
  end
end
