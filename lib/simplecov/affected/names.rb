# frozen_string_literal: true

require_relative "statics"

module SimpleCov
  module Affected
    #
    # The names one change defined differently, for the tests of one recorded
    # run: the run's versions of the files it loaded are the before, the
    # working tree the after. Each changed key maps to the test file it is
    # local to, or to nil when any test may read it.
    #
    # Four rules keep the set small without guessing:
    #
    # - Only a file the run loaded defines anything. A brand-new file outside
    #   the test directories counts as loaded, and its names count only when
    #   no loaded file knew them (reopening `module Rack` adds nothing).
    # - A name defined in a test file is local to that file's tests.
    # - A require counts only when it changes whether its target loads at all,
    #   so moving a require changes nothing. A require of a feature outside
    #   the project changes what the file sees, which is keyed by its path.
    # - A changed name spreads to every static that mentions it
    #   (`FACES = [*NUMBERS]`), until nothing new changes.
    #
    class Names
      PREFIXES = ["", "lib/", "test/", "spec/", "app/"].freeze
      FLIPS = 3

      attr_reader :keys, :unparsable

      def initialize(recording, run, tree)
        @recording = recording
        @run = run
        @tree = tree
        @snapshot = recording.snapshot(run)
        @paths = recording.known | tree.ruby_files
        @keys = {} #: Hash[String, String?]
        @unparsable = nil #: String?
        @changed = @snapshot.keys.reject { |path| tree.digest(path).eql?(@snapshot.fetch(path)) } +
          (tree.ruby_files - recording.known.to_a)
        compute unless @changed.empty?
      end

      def resolve(path, kind, feature)
        if kind.eql?("require_relative")
          found = File.expand_path(feature, File.join("/", File.dirname(path))).delete_prefix("/")
          found += ".rb" unless found.end_with?(".rb")
          return found if @paths.include?(found)
        else
          file = feature.end_with?(".rb") ? feature : "#{feature}.rb"
          PREFIXES.each { |prefix| return prefix + file if @paths.include?(prefix + file) }
        end
        "feature:#{feature}"
      end

      private

      def index
        @recording.index(@run) { |path, kind, feature| resolve(path, kind, feature) }
      end

      def add(key, local)
        if @keys.key?(key)
          @keys[key] = nil if local.nil? || !@keys[key].eql?(local)
        else
          @keys[key] = local
        end
      end

      # Called only for a file the run loaded, whose version the recording
      # keeps for as long as the run is named.
      def before(path)
        @recording.version(path, @snapshot.fetch(path))
      end

      def requires_of(version)
        version&.statics&.requires || [] # simplecov:disable branch -- a loaded version parsed and is kept
      end

      def compute
        loaded_before, loaded_after = loaded_sets
        after_statics = {} #: Hash[String, Statics]
        loaded_before.each_key do |path|
          old = loaded_before[path] ? before(path) : nil
          now = loaded_after[path] ? @tree.version(path) : nil
          statics = now&.statics
          return @unparsable = path if now && statics.nil?

          after_statics[path] = statics if statics
          compare(path, old, now)
        end
        close(after_statics, loaded_before)
      end

      # Which files the run loads before and after the change. A require
      # whose target flips from loaded to not loaded, or back, can flip what
      # that target requires in turn, so this runs to a fixed point, bounded.
      def loaded_sets
        loaded_before = @changed.to_h { |path| [path, @snapshot.key?(path)] }
        loaded_after = @changed.to_h do |path|
          [path, @tree.exist?(path) && (loaded_before.fetch(path) || !@recording.test_dir?(path))]
        end
        FLIPS.times do
          totals = tally(loaded_before, loaded_after)
          flipped = (totals.keys | index.requires.keys).reject do |target|
            target.start_with?("feature:") || loaded_before.key?(target) ||
              index.requires[target].positive?.eql?(totals[target].positive?)
          end
          flipped.each do |target|
            loaded_before[target] = @snapshot.key?(target)
            loaded_after[target] = totals[target].positive? && @tree.exist?(target)
            add(Statics.path_key(target), nil) unless loaded_before[target].eql?(loaded_after[target])
          end
          break if flipped.empty?
        end
        [loaded_before, loaded_after]
      end

      def tally(loaded_before, loaded_after)
        totals = index.requires.dup
        loaded_before.each_key do |path|
          requires_of(before(path)).each { |kind, feature| totals[resolve(path, kind, feature)] -= 1 } if loaded_before[path]
          requires_of(@tree.version(path)).each { |kind, feature| totals[resolve(path, kind, feature)] += 1 } if loaded_after[path]
        end
        totals
      end

      def compare(path, old, now)
        local = @recording.test_files.include?(path) ? path : nil
        names_before = old&.statics&.names || {}
        names_after = now&.statics&.names || {}
        (names_before.keys | names_after.keys).each do |key|
          next if names_before[key].eql?(names_after[key])
          next if old.nil? && !@snapshot.key?(path) && names_after.fetch(key, []).all? { |sum| index.known[key].include?(sum) }

          add(key, local)
        end
        one_liners(old, now, local)
        add(Statics.path_key(path), local) if old && now && !features(old).eql?(features(now))
      end

      # A one-line def that changed changes its name too: a static calling it
      # as the file loads (`LIMIT = default_limit`) gets another value.
      def one_liners(old, now, local)
        return unless old && now

        kept = now.one_liners
        old.one_liners.each_value { |piece| add(piece.name, local) unless kept[piece.id]&.text.eql?(piece.text) }
      end

      def features(version)
        requires_of(version).map { |kind, feature| resolve(version.path, kind, feature) }.select { |target| target.start_with?("feature:") }.tally
      end

      # A static that mentions a changed name has a changed value. A key enters
      # the frontier once, as it enters `keys`.
      def close(after_statics, loaded_before)
        frontier = @keys.keys
        until frontier.empty?
          token = frontier.pop.to_s
          local = @keys[token]
          users(token, local, after_statics, loaded_before).each do |_path, key|
            next if @keys.key?(key)

            add(key, local)
            frontier << key
          end
        end
      end

      def users(token, local, after_statics, loaded_before)
        none = [] #: Array[[String, String]]
        found = local ? none : index.uses[token].reject { |path, _key| after_statics.key?(path) || loaded_before.key?(path) }
        after_statics.each do |path, statics|
          next if local ? !path.eql?(local) : @recording.test_files.include?(path)

          statics.mentions.each { |key, tokens| found << [path, key] if tokens.include?(token) }
        end
        found
      end
    end
  end
end
