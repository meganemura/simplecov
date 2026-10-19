# frozen_string_literal: true

require_relative "sidecar"
require_relative "../static_coverage_extractor"

module SimpleCov
  module Affected
    #
    # Decides, from a recording and the working tree alone, which recorded
    # tests a change can affect, and why. No git: every recorded version is
    # compared with the file as it is now, so the answer holds whatever the
    # last run was and whatever happened since.
    #
    # Some changes reach every test, and the answer is then the full suite
    # with the reason (`full`): another Ruby or lockfile, a data file read
    # before the first test file, a project file loaded before coverage
    # started, a file that no longer parses, and code that ran before the
    # first test file (a `RSpec.configure` block, a method a library calls as
    # it loads), whose effects any test may see.
    #
    # Otherwise each test gets the first reason that applies, cheapest first,
    # or nil:
    #
    # | reason | when |
    # | --- | --- |
    # | `failed` | it failed last time |
    # | `must_run` | it is marked to run every time |
    # | `deleted <path>` | a file it ran is gone |
    # | `def <path> <id>`, `block <path> <id>` | a unit it ran changed or is gone |
    # | `read <path>` | a data file it read changed |
    # | `name <name>` | a static it reaches by name changed |
    #
    # `def <path>` alone means the unit could not be pinned down (a source
    # that does not parse, or a unit none of whose lines coverage reports),
    # and every test that ran a line of the file is selected. A test
    # file's load and context hooks count for each test of that file: a unit
    # the load ran in the test file itself selects the tests written inside
    # it, and one in another file selects every test of the file.
    #
    class Selection
      Result = Struct.new(:full, :reasons)
      Charged = Struct.new(:id, :kind, :first_line, :entry_line, :last_line, :one_liner)
      Status = Struct.new(:deleted, :whole, :charged)
      NOTHING = Array.new(0).freeze
      DELETED = Status.new(true, false, NOTHING).freeze
      WHOLE = Status.new(false, true, NOTHING).freeze
      TEMPLATE = /\.(?:erb|haml|slim)\z/

      # Prism loads only here, and only where it can (not JRuby on Windows),
      # through the static extractor's probe.
      def self.call(document, tree)
        return Result.new("no parser", {}) unless StaticCoverageExtractor.prism_loaded?

        require_relative "recording"
        require_relative "names"
        new(document, tree).call
      end

      def initialize(document, tree)
        @recording = Recording.new(document)
        @tree = tree
        @statuses = {} #: Hash[[String, String], Status?]
        @names = {} #: Hash[String, Names]
        @masks = {} #: Hash[[String, String, Array[String]], Hash[String, [Integer, Integer]]]
      end

      def call
        full = global
        return Result.new(full, {}) if full

        reasons = @recording.tests.to_h { |id, test| [id, reason(test)] }
        Result.new(nil, reasons.select { |id, _reason| @tree.exist?(@recording.tests.fetch(id).fetch("file")) })
      end

      private

      def global
        document = @recording.document
        return "env" unless document.fetch("env").eql?(Sidecar.env(@tree.root))

        boot = document.fetch("boot")
        changed_read(boot.fetch("reads"))&.then { |path| return "read #{path}" }
        document.fetch("unmeasured").each { |path, digest| return "unmeasured #{path}" unless @tree.file_digest(path).eql?(digest) }
        unparsable || boot_reason(boot.fetch("lines"))
      end

      def boot_reason(lines)
        lines.each do |path, (digest, hex)|
          status = status(path, digest)
          next unless status
          return "deleted #{path}" if status.deleted
          return "boot #{path}" if status.whole

          hit = status.charged.find { |piece| !piece.one_liner && hex.to_i(16).anybits?(span(piece)) }
          return "boot #{path} #{hit.id}" if hit
        end
        nil
      end

      def unparsable
        runs = @recording.tests.each_value.map { |test| test["run"] }.uniq
        runs.each { |run| names(run).unparsable&.then { |path| return "unparsable #{path}" } }
        nil
      end

      def reason(test)
        return "failed" unless test.fetch("ok")
        return "must_run" if test.fetch("must_run")

        load = @recording.loads.fetch(test.fetch("file"), nil)
        records = [test, load].compact
        deleted(records) || ran(test) || loaded(test, load) || changed_read(records.flat_map { |record| record.fetch("reads") })&.then { |path| "read #{path}" } ||
          name(test, records)
      end

      def deleted(records)
        records.each do |record|
          record.fetch("lines").each { |path, (digest, _hex)| return "deleted #{path}" if status(path, digest)&.deleted }
        end
        nil
      end

      def ran(test)
        test.fetch("lines").each do |path, (digest, hex)|
          status = status(path, digest)
          next unless status

          bits = hex.to_i(16)
          return "def #{path}" if status.whole && bits.positive?

          hit = status.charged.find { |piece| bits.anybits?(span(piece)) }
          return "#{hit.kind} #{path} #{hit.id}" if hit
        end
        nil
      end

      def loaded(test, load)
        return nil unless load

        load.fetch("lines").each do |path, (digest, hex)|
          status = status(path, digest)
          next unless status

          bits = hex.to_i(16)
          return "def #{path}" if status.whole && bits.positive?

          status.charged.each do |piece|
            next if piece.one_liner || !bits.anybits?(span(piece))
            return "#{piece.kind} #{path} #{piece.id}" if written_in?(test, path, piece)
          end
        end
        nil
      end

      # A unit of the test file itself that ran as it loaded (an example
      # group's body) holds the tests written inside it. When it holds none
      # (shared examples used elsewhere in the file), every test of the file
      # may depend on it.
      def written_in?(test, path, piece)
        return true unless path.eql?(test.fetch("file"))

        inside = ->(other) { (piece.first_line..piece.last_line).cover?(other["line"]) }
        inside.call(test) || @recording.tests_of(path).none?(&inside)
      end

      def changed_read(paths)
        paths.find { |path| !@tree.file_digest(path).eql?(@recording.reads[path]) }
      end

      def name(test, records)
        keys = names(test["run"]).keys.select { |key, _local| Tokens::WORD_START.match?(key) }
        return nil if keys.empty?

        files = test.fetch("lines").keys
        reached = reached(test, records, keys)
        hit = keys.select { |key, local| reached.include?(key) && (local.nil? || files.include?(local)) }.keys.min
        "name #{hit}" if hit
      end

      def names(run)
        @names[run.to_s] ||= Names.new(@recording, run, @tree)
      end

      # Which of the changed keys a test reaches: a key its units mention (the
      # units it ran, and those its file's load ran), the classes and modules
      # around them, the files they are in, and the templates it read.
      # Operators are never keys here: nearly every test calls `==`.
      def reached(test, records, keys)
        found = Set.new #: Set[String]
        records.each_with_index do |record, index|
          record.fetch("lines").each do |path, (digest, hex)|
            found << Statics.path_key(path)
            bits = hex.to_i(16)
            masks(path, digest, keys).each do |key, (units, calls)|
              found << key if bits.anybits?(units) || (index.zero? && bits.anybits?(calls))
            end
          end
        end
        test.fetch("reads").grep(TEMPLATE).each { |path| found.merge(Tokens.words(@tree.text(path).to_s)) }
        found
      end

      # Per changed key, the lines of one version that reach it: a unit's own
      # lines (from its entry line down, less its nested units) when its own
      # code mentions the key, which leaves out the other examples of a
      # `describe` a test sits in; and the line of a one-line def that does,
      # which counts only in a test's own lines, because in a load's lines it
      # is the definition, not a call. Worked out once per version, so each
      # test costs a few mask tests.
      def masks(path, digest, keys)
        @masks[[path, digest, keys.keys]] ||= begin
          masks = keys.keys.to_h { |key| [key, [0, 0]] } #: Hash[String, [Integer, Integer]]
          version = @recording.version(path, digest)
          fill_masks(version, masks) if version # simplecov:disable branch -- recorded versions are kept
          masks
        end
      end

      def fill_masks(version, masks)
        version.own_lines.each do |id, own|
          (version.reach.fetch(id) & masks.keys).each { |key| masks.fetch(key)[0] |= own }
        end
        version.one_liners.each_value do |piece|
          (piece.tokens & masks.keys).each { |key| masks.fetch(key)[1] |= 1 << (piece.first_line - 1) }
        end
      end

      def span(piece)
        Version.mask(piece.entry_line, piece.last_line)
      end

      def status(path, digest)
        @statuses.fetch([path, digest]) { @statuses[[path, digest]] = compare(path, digest) }
      end

      # nil when the file is as recorded.
      def compare(path, digest)
        current = @tree.digest(path)
        return nil if current.eql?(digest)
        return DELETED unless current

        before = @recording.version(path, digest)
        after = @tree.version(path)
        # simplecov:disable branch -- the recorded version is kept and parsed as it loaded, and an unparsable current one ends the selection first
        outlined = before&.outline
        now = after&.outline
        return WHOLE unless before && after && outlined && now
        # simplecov:enable branch

        charged = charged_units(before, outlined, now) + charged_one_liners(before, after)
        hits = @recording.hits(path, digest)
        (charged.all? { |piece| traceable?(piece, hits) }) ? Status.new(false, false, charged) : WHOLE
      end

      # Every entry into a unit runs a line event inside its span, so a test
      # that entered it has a bit there, but not always on the entry line:
      # `begin ... end if ready` reports the predicate's line, and a block
      # whose body is a multi-line array literal reports its first element.
      # What has to hold is that coverage reports the unit at all.
      def traceable?(piece, hits)
        hits[(piece.entry_line - 1)...piece.last_line].to_a.any?(Integer)
      end

      # A unit changed when its head or its body did, or it is gone. A unit
      # that is new changes the text around it, which is charged instead.
      def charged_units(before, outlined, now)
        outlined.units.each_value.filter_map do |unit|
          kept = now.units[unit.id]
          next if kept && kept.head.eql?(unit.head) && kept.body.eql?(unit.body)

          Charged.new(unit.id, unit.method ? "def" : "block", before.line_of(unit.start_offset), unit.entry_line, unit.last_line, false)
        end
      end

      def charged_one_liners(before, after)
        kept = after.one_liners
        before.one_liners.each_value.filter_map do |piece|
          next if kept[piece.id]&.text.eql?(piece.text)

          Charged.new(piece.id, "def", piece.first_line, piece.first_line, piece.last_line, true)
        end
      end
    end
  end
end
