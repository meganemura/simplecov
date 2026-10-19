# frozen_string_literal: true

require_relative "sidecar"

module SimpleCov
  module Affected
    #
    # Folds recordings together. Two operations, because two different things
    # get folded:
    #
    # `combine` joins recordings of the same code: the parts the processes of
    # one run wrote (a forked worker, a parallel_tests worker), or the
    # sidecars of the shards of one CI build. Nothing in one says anything
    # about the others' tests, so it is a union; a test recorded twice (a
    # worker inherits whatever its parent recorded before the fork) keeps the
    # later record and the union of the lines both saw.
    #
    # `onto` lays a run over the recording it starts from. A run that selected
    # some tests says nothing about the rest, so the previous records stay,
    # each against the version of each file it was recorded with; that is why
    # a file keeps several versions. What the run does say overrides: a test it
    # ran is recorded afresh, and a test file it ran in full drops the ids it
    # no longer defines.
    #
    module Merge
      # Recording-wide keys whose values the later document replaces per key.
      PER_KEY = %w[latest reads unmeasured unloaded].freeze

      extend self

      def combine(documents)
        documents.reduce { |into, document| join(into, document) }
      end

      # `root` is where the test files are looked up, so a recording keeps no
      # test whose file is gone.
      def onto(previous, run, root)
        complete = run.fetch("complete", [])
        document = if previous.nil? || !previous["env"].eql?(run["env"])
          run
        else
          join(drop_stale(previous, run, complete), run)
        end
        prune(document.except("complete"), root)
      end

      private

      def join(into, document)
        joined = into.merge("root" => document["root"], "env" => document["env"])
        joined["files"] = join_files(into.fetch("files"), document.fetch("files"))
        joined["runs"] = join_files(into.fetch("runs"), document.fetch("runs"))
        PER_KEY.each { |key| joined[key] = into.fetch(key).merge(document.fetch(key)) }
        joined["tests"] = join_records(into.fetch("tests"), document.fetch("tests"))
        joined["loads"] = join_records(into.fetch("loads"), document.fetch("loads"))
        joined["boot"] = join_record(into.fetch("boot"), document.fetch("boot"))
        joined["complete"] = (into.fetch("complete", []) | document.fetch("complete", [])).sort
        joined
      end

      # Per file its versions, or per run the version of each file it loaded:
      # two processes of one run each loaded some of the files.
      def join_files(into, files)
        into.merge(files) { |_key, versions, more| versions.merge(more) }
      end

      def join_records(into, records)
        into.merge(records) { |_id, record, again| join_record(record, again) }
      end

      # The later record wins, except that its lines and reads add to the
      # earlier ones where both saw the same source: two processes running
      # the same test (or one test's load context, split across a fork) each
      # saw part of what it touched.
      def join_record(record, again)
        none = {} #: Hash[String, [String, String]]
        lines = record.fetch("lines", none).merge(again.fetch("lines", none)) do |_relative, (digest, hex), (newer, more)|
          digest.eql?(newer) ? [digest, (hex.to_i(16) | more.to_i(16)).to_s(16)] : [newer, more]
        end
        record.merge(again).merge("lines" => lines, "reads" => (record.fetch("reads", []) | again.fetch("reads", [])).sort)
      end

      # Two kinds of previous record the run contradicts. A test file the run
      # ran in full defines exactly the ids the run recorded for it. And a test
      # the run did not rerun that read a data file the run saw at another
      # version was recorded against a version no digest is kept for any
      # more; dropping it makes it new, which selects it.
      def drop_stale(previous, run, complete)
        moved = run.fetch("reads").select { |path, digest| previous.fetch("reads").fetch(path, digest) != digest }.keys
        ran = run.fetch("tests")
        tests = previous.fetch("tests").reject do |id, test|
          next false if ran.key?(id)

          complete.include?(test.fetch("file")) || test.fetch("reads").intersect?(moved)
        end
        loads = previous.fetch("loads").reject { |_file, load| load.fetch("reads").intersect?(moved) }
        previous.merge("tests" => tests, "loads" => loads)
      end

      # Keeps what something still points at: a test whose file exists, a load
      # context of such a file, the runs those were recorded in, and of each
      # file the versions a record or a run names plus the one last seen.
      def prune(document, root)
        tests = document.fetch("tests").select { |_id, test| File.file?(File.join(root, test.fetch("file").to_s)) }
        loads = document.fetch("loads").select { |file, _load| File.file?(File.join(root, file)) }
        runs = document.fetch("runs").slice(*(tests.values + loads.values).map { |record| record["run"] }.uniq)
        named = Hash.new { |hash, relative| hash[relative] = Set.new } #: Hash[String, Set[String]]
        [*tests.values, *loads.values, document.fetch("boot")].each do |record|
          record.fetch("lines").each { |relative, (digest, _hex)| named[relative] << digest }
        end
        [document.fetch("latest"), *runs.values].each do |versions|
          versions.each { |relative, digest| named[relative] << digest }
        end
        files = document.fetch("files").to_h { |relative, versions| [relative, versions.slice(*named[relative])] }
        loaded = document.fetch("files").keys.to_set | document.fetch("unmeasured").keys
        document.merge("tests" => tests, "loads" => loads, "runs" => runs, "unloaded" => document.fetch("unloaded").except(*loaded),
          "files" => files.reject { |_relative, versions| versions.empty? })
      end
    end
  end
end
