# frozen_string_literal: true

require_relative "sidecar"
require_relative "recorder"

module SimpleCov
  module Affected
    #
    # The working tree as the selection sees it: no git, only what the files
    # hold now, compared with the digests recorded. Each file is read at most
    # once per selection.
    #
    class Tree
      attr_reader :root

      def initialize(root, coverage_path)
        @root = root
        @files = Recorder.new(root, coverage_path)
        @texts = {} #: Hash[String, String?]
        @versions = {} #: Hash[String, Version?]
      end

      # nil for a file that is gone or unreadable.
      def text(path)
        @texts.fetch(path) do
          @texts[path] = File.read(File.join(@root, path), encoding: Encoding::UTF_8)
        rescue SystemCallError
          @texts[path] = nil
        end
      end

      # The digest the recording uses for sources.
      def digest(path)
        source = text(path)
        Sidecar.digest(source) if source
      end

      # The digest the recording uses for data files.
      def file_digest(path)
        Sidecar.file_digest(File.join(@root, path))
      end

      def version(path)
        @versions.fetch(path) do
          source = text(path)
          @versions[path] = source && Version.new(path, source)
        end
      end

      def exist?(path)
        File.file?(File.join(@root, path))
      end

      # Every Ruby file of the project, as root-relative paths.
      def ruby_files
        @ruby_files ||= Dir.glob("**/*.rb", base: @root).select { |path| @files.project_file(File.join(@root, path)) }.sort
      end
    end
  end
end
