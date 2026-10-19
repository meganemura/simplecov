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

      def install(test_case)
        test_case.prepend(Run)
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
