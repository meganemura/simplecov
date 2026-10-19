# frozen_string_literal: true

module SimpleCov
  module Affected
    #
    # RSpec's side of the recording, through RSpec's public configuration
    # only. An example's id is its spec file and full description, which stay
    # put when lines are added above it, unlike `file:line`; an example
    # without a description is told apart by its position among its group's
    # other undescribed examples. The id is derived when the example is
    # defined, before RSpec generates a description from the matcher, so the
    # recording and the selection compute the same one.
    #
    module RSpec
      extend self

      def install(rspec)
        return if @installed || rspec.nil?

        @installed = true
        undescribed = {} #: Hash[untyped, Integer]
        undescribed.compare_by_identity
        rspec.configure do |config|
          config.define_derived_metadata { |metadata| Affected::RSpec.derive(metadata, undescribed) }
          config.prepend_before(:context) { Affected::RSpec.mark(self.class) }
          config.around { |example| Affected::RSpec.run(example) }
          config.before(:suite) { Affected::RSpec.note_filters(config) }
        end
      end

      # The exclusions RSpec sets itself (`if:`, `unless:`) and the one the
      # selection adds leave every test of a file that matters to the run; any
      # other filter leaves out tests the recording still has to keep.
      OWN_EXCLUSIONS = %i[if unless affected_id].freeze

      def note_filters(config)
        recorder = Affected.recorder
        excluded = config.exclusion_filter.rules.keys - OWN_EXCLUSIONS
        recorder.filtered! if recorder && !(config.inclusion_filter.empty? && excluded.empty?)
      end

      def derive(metadata, undescribed)
        group = metadata[:example_group]
        file = group && Affected.recorder&.project_file(metadata.fetch(:rerun_file_path))
        return unless file

        description = metadata.fetch(:full_description).strip
        if metadata.fetch(:description).to_s.empty?
          undescribed[group] = undescribed.fetch(group, 0) + 1
          description = "#{description} {#{undescribed.fetch(group)}}"
        end
        metadata[:affected_id] = "#{file}::#{description}"
        metadata[:affected_line] = line_in_file(metadata)
      end

      # The line in the spec file itself: an example from shared examples
      # sits in the support file, and its `it_behaves_like` group is the line
      # that belongs to the spec.
      def line_in_file(metadata)
        found = metadata
        found = found[:example_group] || found[:parent_example_group] until found.nil? || found[:file_path].eql?(metadata[:rerun_file_path])
        (found || metadata).fetch(:line_number)
      end

      def run(example)
        metadata = example.metadata
        id = metadata[:affected_id]
        recorder = Affected.recorder
        return example.run unless id && recorder

        recorder.test(id, file: id.split("::", 2).first, line: metadata[:affected_line], must_run: !!metadata[:must_run]) do
          example.run
          example.exception.nil?
        end
      end

      # The top-level group's `before(:context)` is the one hook RSpec's
      # configuration can reach; from there every group of the file gets a
      # boundary before its own `before(:context)` and `after(:context)`
      # hooks, so their code is the file's rather than whichever example
      # happened to run last.
      def mark(group)
        recorder = Affected.recorder
        file = recorder&.project_file(group.metadata.fetch(:rerun_file_path))
        return unless recorder && file

        recorder.boundary(file)
        group.prepend_after(:context) { recorder.boundary(file) }
        nested(group).each do |child|
          child.prepend_before(:context) { recorder.boundary(file) }
          child.prepend_after(:context) { recorder.boundary(file) }
        end
      end

      def nested(group)
        group.subclasses.flat_map { |child| [child, *nested(child)] }
      end
    end
  end
end
