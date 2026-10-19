# frozen_string_literal: true

module SimpleCov
  # A file's first load inside a test runs its class body once per process,
  # for whichever test happens to come first, though every later test depends
  # on it as much. Charging that load to the test would let a change to the
  # class body select that one test, so the load runs in boot's segment and
  # the test's segment resumes after it.
  class TestTracker
    # Wrapped around Kernel's `require` and `load`: autoload (Zeitwerk's
    # included) goes through `require`. `require_relative` is left alone,
    # because a wrapper would resolve the path against this file; a file it
    # loads inside a test still reaches boot, through the segment's check for
    # files it did not open with.
    #
    # The methods are aliased in, the way RubyGems, Bootsnap, and Zeitwerk
    # wrap `require`, rather than prepended. Those libraries alias whatever
    # `require` is when they load, and with a module prepended to Kernel the
    # alias takes the prepended method, so their own wrapper drops out of the
    # chain: a helper that starts SimpleCov before a Rails application loads
    # then has Zeitwerk's autoload of a namespace directory reach the plain
    # `require`, which fails.
    module LoadHook
      ORIGINALS = {load: :simplecov_original_load, require: :simplecov_original_require}.freeze

      def self.install(kernel = ::Kernel)
        return if kernel.private_method_defined?(ORIGINALS.fetch(:require))

        ORIGINALS.each do |name, original|
          kernel.send(:alias_method, original, name)
          kernel.send(:define_method, name, instance_method(name))
          kernel.send(:private, name, original)
        end
      end

      private

      def load(file, *rest)
        tracker = SimpleCov.test_tracker
        return simplecov_original_load(file, *rest) unless tracker

        tracker.loading(file, :load) { simplecov_original_load(file, *rest) }
      end

      def require(feature)
        tracker = SimpleCov.test_tracker
        return simplecov_original_require(feature) unless tracker

        tracker.loading(feature, :require) { simplecov_original_require(feature) }
      end
    end

    # Runs the block, a `require` or `load` of `feature`, in boot's segment
    # when it is a Ruby file's first load and a test's segment is open. A
    # `require` that turns out to load nothing is remembered, so a feature
    # required on every call costs a lookup, not a coverage peek.
    def loading(feature, kind)
      segment = @segment
      return yield if segment.nil? || segment.id.eql?(BOOT) || !first_load?(feature, kind)

      loaded = aside(BOOT) { yield }
      @loaded << feature unless loaded
      loaded
    end

    # Closes the open segment, runs the block in `id`'s, and reopens the one
    # it closed. Only the thread that runs the tests moves the segment;
    # another thread's code stays where it lands.
    def aside(id)
      previous = @segment&.id
      return yield if previous.nil? || previous.eql?(id) || poisoned? || !(@depth.zero? || @owner.equal?(Thread.current))

      open_segment(id)
      begin
        yield
      ensure
        open_segment(previous) unless poisoned?
      end
    end

    private

    # `load` runs its file every time, so only its first call for a path is
    # a first load. `require` loads a Ruby file once, so it is one while the
    # file it resolves to is not among the loaded features. A feature that
    # does not resolve is left to `require` itself, to load from a gem it
    # activates or to raise.
    def first_load?(feature, kind)
      name = feature.respond_to?(:to_path) ? feature.to_path : feature
      return false unless name.is_a?(String)
      return !@loaded.add?(File.expand_path(name)).nil? if kind.equal?(:load)
      return false if @loaded.include?(name)

      type, path = $LOAD_PATH.resolve_feature_path(name)
      return true if type.equal?(:rb) && !$LOADED_FEATURES.include?(path)

      @loaded << name
      false
    end
  end
end
