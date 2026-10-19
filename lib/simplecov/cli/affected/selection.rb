# frozen_string_literal: true

module SimpleCov
  module CLI
    module Affected
      module Selection
        TEST_FILE_NAME = /\A(?:test_.*|.*_(?:test|spec))\.rb\z/

        extend self

        def build(changed, document, contexts, opts, stderr, root:, base:)
          none = {} #: Hash[String, untyped]
          coverage = document.fetch("coverage", none)
          unless coverage.instance_of?(Hash)
            return CoverageFile.report_invalid(stderr, "affected", opts.fetch(:input), '"coverage" must be an object')
          end

          state = initial_state(changed, contexts, coverage, opts, stderr, root: root, base: base)
          return nil unless changed.all? { |path| classify(path, state) }

          {tests: state.fetch(:tests).uniq.sort, triggers: state.fetch(:triggers)}
        end

        def initial_state(changed, contexts, coverage, opts, stderr, root:, base:)
          {
            tests: [], triggers: [], changed: changed, contexts: contexts,
            known: contexts.each_with_object(Set.new) { |id, set| set << test_file_of(id) },
            index: CoverageFile.exact_index(coverage), root: root, base: base, opts: opts, stderr: stderr
          } #: Hash[Symbol, untyped]
        end

        # A recorded test file selects itself, a file the report covers selects the
        # files of the tests touching it, a test-looking file the map has never seen
        # always runs, and anything else is a trigger. Changed paths are exact
        # root-relative names, so they resolve against the report exactly: a
        # lookalike entry elsewhere must not stand in for a file it doesn't carry.
        def classify(path, state)
          entry = entry_for(path, state)
          if state.fetch(:known).include?(path)
            select_test_file(path, state)
          elsif entry
            select_covering(path, entry, state)
          elsif TEST_FILE_NAME.match?(File.basename(path))
            select_test_file(path, state, note_deleted: false)
          else
            note_untracked(path, state)
          end
        end

        def note_untracked(path, state)
          state.fetch(:triggers) << "#{path} changed but #{state.fetch(:opts).fetch(:input)} has no data for it"
        end

        # A changed test file runs, unless the change is its deletion: its tests are
        # gone, which removes them from the answer without distrusting the map.
        def select_test_file(path, state, note_deleted: true)
          if on_disk?(path, state)
            state.fetch(:tests) << path
          elsif note_deleted
            state.fetch(:stderr).puts("simplecov affected: skipping deleted test file #{path}")
          end
          path
        end

        # Existence judged at the repository root the paths are relative to, not the
        # cwd, so a subdirectory run answers the same.
        def on_disk?(path, state)
          File.exist?(File.expand_path(path, state.fetch(:root)))
        end

        def entry_for(path, state)
          state.fetch(:index)[File.expand_path(path, state.fetch(:root))] || state.fetch(:index)[path]
        end

        def select_covering(path, entry, state)
          table = covering_table(path, entry, state)
          return unless table

          table.each_key { |index| select_context(state.fetch(:contexts).fetch(index), path, state) }
          trigger_on_unrecorded_change(path, Array(entry["lines"]), table, state)
        end

        # A line that ran with no test on record ran while files loaded, so no
        # recorded test stands for it. Loading a def line only names the method.
        def trigger_on_unrecorded_change(path, counts, table, state)
          base = state.fetch(:base)
          return path unless base

          lines = ChangedFiles.report_lines_changed(state.fetch(:root), base, path, state.fetch(:stderr))
          return unless lines

          recorded = table.each_value.reduce(0, :|)
          line = lines.fetch(:changed).filter_map { |number| statement_start(counts, number) }.find do |number|
            ran_unrecorded?(counts.fetch(number - 1), recorded, number) &&
              !ChangedFiles::DEF_LINE.match?(lines.fetch(:source).fetch(number - 1))
          end
          if line
            state.fetch(:triggers) << "the change touches #{path}:#{line}, which ran only while no test was being " \
              "recorded, as files loaded"
          end
          path
        end

        # A line skipped by `:nocov:` reads "ignored" and has no count.
        def ran_unrecorded?(count, recorded, number)
          count.to_i.positive? && !recorded.anybits?(1 << (number - 1))
        end

        # A statement that spans lines is counted on its first.
        def statement_start(counts, number)
          counts.first(number).rindex(&:itself)&.succ
        end

        def covering_table(path, entry, state)
          unless entry.instance_of?(Hash)
            return CoverageFile.report_invalid(state.fetch(:stderr), "affected", state.fetch(:opts).fetch(:input),
              "entry for #{path} must be an object")
          end

          raw = entry["contexts"] || {}
          table = raw.instance_of?(Hash) && Tests.decode_table(raw, state.fetch(:contexts).size)
          return table if table

          CoverageFile.report_invalid(state.fetch(:stderr), "affected", state.fetch(:opts).fetch(:input),
            "entry for #{path} carries a malformed \"contexts\" table")
        end

        # Selected via its file, or a staleness trigger when it has no file to
        # select: a locationless id, or a file that exists neither on disk nor in
        # the change.
        def select_context(id, path, state)
          file = test_file_of(id)
          if file.nil?
            state.fetch(:triggers) << "recorded test #{id} touches #{path} but has no file location"
          elsif on_disk?(file, state)
            state.fetch(:tests) << file
          elsif !state.fetch(:changed).include?(file)
            state.fetch(:triggers) << "recorded test file #{file} no longer exists"
          end
        end

        # "spec/a_spec.rb:12" and the :file granularity's bare "spec/a_spec.rb" both
        # name a file, while a locationless fallback id names none.
        def test_file_of(id)
          base = id.sub(/:\d+\z/, "")
          base if base.include?("/") || base.end_with?(".rb")
        end
      end
    end
  end
end
