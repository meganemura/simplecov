# frozen_string_literal: true

module SimpleCov
  module Affected
    #
    # Minitest's side of the recording. A test's id is its file, class, and
    # method name. minitest/spec numbers each `it` (`test_0012_parses`), and
    # inserting an example would renumber every later one, so the number is
    # left out.
    #
    module Minitest
      SPEC_NUMBER = /\Atest_\d{4}_/

      extend self

      def install(test_case, narrow: false)
        test_case.prepend(Run)
        test_case.singleton_class.prepend(Filters)
        test_case.singleton_class.prepend(Narrow) if narrow
      end

      def id(klass, name)
        "#{file(klass, name)}::#{klass.name}##{name.sub(SPEC_NUMBER, "test_")}"
      end

      def file(klass, name)
        path, = location(klass, name)
        Affected.recorder&.project_file(path) if path
      end

      def location(klass, name)
        klass.instance_method(name).source_location
      rescue NameError
        nil
      end

      # `-n`, `-i`, and `-e` leave out tests the recording still has to keep.
      # Minitest 5 hands the options to each runnable class's `run`, as its
      # last Hash argument; Minitest 6 hands them to `filter_runnable_methods`.
      module Filters
        NAMES = %i[filter include exclude].freeze

        def self.note(options)
          recorder = Affected.recorder
          recorder.filtered! if recorder && options.is_a?(Hash) && NAMES.any? { |name| options[name] }
        end

        def run(*args, **kwargs)
          Filters.note(args.last || kwargs)
          super
        end

        def filter_runnable_methods(options = {})
          Filters.note(options)
          super
        end
      end

      # Minitest 5 and 6 both ask each runnable class for its test methods
      # before filtering and running them, after shuffling them under the
      # run's seed, so leaving names out here keeps the order of the rest.
      module Narrow
        def runnable_methods
          super.select do |name|
            file = Minitest.file(self, name)
            file.nil? || Affected.run?(Minitest.id(self, name))
          end
        end
      end

      module Run
        def run
          recorder = Affected.recorder
          return super unless recorder

          outcome = nil
          _, line = Minitest.location(self.class, name)
          recorder.test(Minitest.id(self.class, name), file: Minitest.file(self.class, name), line: line) do
            outcome = super
            !!(passed? || skipped?)
          end
          outcome
        end
      end
    end
  end
end
