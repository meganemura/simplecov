# frozen_string_literal: true

module SimpleCov
  module Affected
    #
    # Turns one process's result into a sidecar document: SimpleCov's
    # ContextMap supplies which lines each context ran, the recorder supplies
    # what the context was, and the files are read once more to keep the
    # source each bitmap was recorded against. The result's original coverage
    # is used rather than the report's, so the test files the default profiles
    # filter out of the report are kept: an `it` block is a unit too.
    #
    module Capture
      extend self

      def call(recorder, result, root, loaded_features: $LOADED_FEATURES)
        map = result.contexts
        return nil unless map

        versions = {} #: Hash[String, String]
        document = blank(root)
        record_files(document, versions, recorder, result.original_result)
        record_contexts(document, versions, recorder, map.to_h)
        record_reads(document, recorder, root)
        record_unmeasured(document, recorder, result.original_result, loaded_features)
        document
      end

      private

      def blank(root)
        empty = {} #: Hash[String, untyped]
        {"version" => Sidecar::VERSION, "root" => root, "env" => Sidecar.env(root), "files" => {}, "latest" => {},
         "tests" => {}, "loads" => {}, "boot" => empty, "reads" => {}, "unmeasured" => {}}
      end

      def record_files(document, versions, recorder, coverage)
        coverage.each do |path, entry|
          relative = recorder.project_file(path)
          next unless relative&.end_with?(".rb")

          source = read_source(path)
          next unless source

          digest = Sidecar.digest(source)
          versions[path] = relative
          document.fetch("latest")[relative] = digest
          document.fetch("files")[relative] = {digest => {"source" => source.lines(chomp: true), "lines" => entry["lines"]}}
        end
      end

      def read_source(path)
        File.read(path, encoding: Encoding::UTF_8)
      rescue SystemCallError
        nil
      end

      # A context the recorder never named (a hand-written `track_test` around
      # something that is not a test) is folded into boot: no test owns it.
      def record_contexts(document, versions, recorder, map)
        lines = owned_lines(versions, document.fetch("latest"), recorder, map)
        none = {} #: Hash[String, [String, String]]
        recorder.tests.each do |id, test|
          document.fetch("tests")[id] = {"file" => test.file, "line" => test.line, "ok" => test.ok, "time" => test.time,
                                         "must_run" => test.must_run, "reads" => test.reads.sort,
                                         "lines" => lines.fetch(id, none)}
        end
        recorder.loads.each do |file, reads|
          document.fetch("loads")[file] = {"lines" => lines.fetch(file, none), "reads" => reads.sort}
        end
        document["boot"] = {"lines" => lines.fetch(Recorder::BOOT, none), "reads" => recorder.boot_reads.sort}
      end

      def owned_lines(versions, latest, recorder, map)
        bits = Hash.new { |hash, id| hash[id] = Hash.new(0) } #: Hash[String, Hash[String, Integer]]
        ids = map.fetch("contexts")
        map.fetch("files").each do |path, table|
          relative = versions[path]
          next unless relative

          table.each do |index, hex|
            id = ids.fetch(Integer(index, 10))
            owner = (recorder.tests.key?(id) || recorder.loads.key?(id)) ? id : Recorder::BOOT
            bits[owner][relative] |= hex.to_i(16)
          end
        end
        bits.transform_values do |files|
          files.to_h { |relative, value| [relative, [latest.fetch(relative), value.to_s(16)]] }
        end
      end

      def record_reads(document, recorder, root)
        read = recorder.tests.each_value.flat_map { |test| test.reads.to_a } + recorder.loads.values.flat_map(&:to_a) +
          recorder.boot_reads.to_a
        read.uniq.sort.each { |path| document.fetch("reads")[path] = Sidecar.file_digest(File.join(root, path)) }
      end

      # Project files that were loaded before Coverage started have no lines to
      # attribute, so the selection can only tell that they changed.
      def record_unmeasured(document, recorder, coverage, loaded_features)
        loaded_features.each do |path|
          relative = recorder.project_file(path) if File.absolute_path?(path)
          next unless relative&.end_with?(".rb") && !coverage.key?(path)

          document.fetch("unmeasured")[relative] = Sidecar.file_digest(path)
        end
      end
    end
  end
end
