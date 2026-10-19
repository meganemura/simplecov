# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::RSpec do
  include AffectedHelpers

  around { |example| with_recorder("/proj") { example.run } }

  before { allow(SimpleCov).to receive(:track_test).and_yield }

  describe ".install" do
    let(:config) { instance_spy(RSpec::Core::Configuration) }
    let(:rspec) { Struct.new(:config) { def configure = yield(config) }.new(config) }

    after { described_class.instance_variable_set(:@installed, false) }

    it "derives ids through RSpec's configuration" do
      described_class.install(rspec)

      expect(config).to have_received(:define_derived_metadata)
    end

    it "marks groups through RSpec's configuration" do
      described_class.install(rspec)

      expect(config).to have_received(:prepend_before).with(:context)
    end

    it "wraps examples through RSpec's configuration" do
      described_class.install(rspec)

      expect(config).to have_received(:around)
    end

    it "looks at the runner's filters once the suite starts" do
      described_class.install(rspec)

      expect(config).to have_received(:before).with(:suite)
    end

    it "does nothing without RSpec" do
      expect(described_class.install(nil)).to be_nil
    end

    it "installs once per process" do
      2.times { described_class.install(rspec) }

      expect(config).to have_received(:around).once
    end
  end

  describe ".derive" do
    let(:group) { {file_path: "/proj/spec/a_spec.rb", line_number: 1} }
    let(:undescribed) { {}.compare_by_identity }

    def example(description, line: 5, file: "/proj/spec/a_spec.rb", parent: group)
      {example_group: parent, description: description, full_description: "Calc #{description}",
       file_path: file, rerun_file_path: "/proj/spec/a_spec.rb", line_number: line}
    end

    def derived(metadata)
      described_class.derive(metadata, undescribed)
      metadata
    end

    it "names an example by its spec file and full description" do
      expect(derived(example("adds"))).to include(affected_id: "spec/a_spec.rb::Calc adds", affected_line: 5)
    end

    it "numbers undescribed examples within their group" do
      ids = [example(""), example(nil), example("", parent: {file_path: "/proj/spec/a_spec.rb"})].map do |metadata|
        derived(metadata).fetch(:affected_id)
      end

      expect(ids).to eq(["spec/a_spec.rb::Calc {1}", "spec/a_spec.rb::Calc {2}", "spec/a_spec.rb::Calc {1}"])
    end

    it "places a shared example at the group that includes it" do
      shared = example("is shared", line: 40, file: "/proj/spec/support/shared.rb",
        parent: {file_path: "/proj/spec/support/shared.rb", parent_example_group: group.merge(line_number: 9)})

      expect(derived(shared).fetch(:affected_line)).to eq(9)
    end

    it "keeps the example's own line when no group sits in the spec file" do
      orphan = example("orphan", line: 7, file: "/proj/spec/support/shared.rb", parent: {file_path: "/proj/spec/support/shared.rb"})

      expect(derived(orphan).fetch(:affected_line)).to eq(7)
    end

    it "leaves a group's own metadata alone" do
      expect(derived(group)).not_to have_key(:affected_id)
    end

    it "leaves an example alone without a recorder" do
      SimpleCov::Affected.instance_variable_set(:@recorder, nil)

      expect(derived(example("adds"))).not_to have_key(:affected_id)
    end

    it "leaves an example outside the project alone, such as RSpec's suite hooks" do
      expect(derived(example("hook").merge(rerun_file_path: "/gems/rspec/exe/rspec"))).not_to have_key(:affected_id)
    end
  end

  describe ".run" do
    let(:metadata) { {affected_id: "spec/a_spec.rb::Calc adds", affected_line: 5} }
    let(:example) { instance_double(RSpec::Core::Example::Procsy, metadata: metadata, run: :ran, exception: nil) }

    it "records the example with its outcome" do
      described_class.run(example)

      expect(SimpleCov::Affected.recorder.tests.fetch("spec/a_spec.rb::Calc adds"))
        .to have_attributes(file: "spec/a_spec.rb", line: 5, ok: true, must_run: false)
    end

    it "records a failed example as failed" do
      allow(example).to receive(:exception).and_return(RuntimeError.new)
      described_class.run(example)

      expect(SimpleCov::Affected.recorder.tests.fetch("spec/a_spec.rb::Calc adds").ok).to be(false)
    end

    it "keeps an example's must-run mark" do
      metadata[:must_run] = true
      described_class.run(example)

      expect(SimpleCov::Affected.recorder.tests.fetch("spec/a_spec.rb::Calc adds").must_run).to be(true)
    end

    it "just runs an example it did not name" do
      metadata.clear

      expect(described_class.run(example)).to eq(:ran)
    end

    it "records nothing for an example it did not name" do
      metadata.clear
      described_class.run(example)

      expect(SimpleCov::Affected.recorder.tests).to be_empty
    end
  end

  describe ".note_filters" do
    let(:config) { RSpec::Core::Configuration.new }

    def complete
      SimpleCov::Affected.recorder.tap { |recorder| recorder.boundary("spec/a_spec.rb") }.complete
    end

    it "keeps every file complete under RSpec's own filters and the selection's" do
      config.filter_run_excluding(affected_id: ->(_id) { false })
      described_class.note_filters(config)

      expect(complete).to eq(%w[spec/a_spec.rb])
    end

    it "notes a filter that leaves tests out" do
      config.filter_run_including(focus: true)
      described_class.note_filters(config)

      expect(complete).to be_empty
    end

    it "notes an exclusion that leaves tests out" do
      config.filter_run_excluding(slow: true)
      described_class.note_filters(config)

      expect(complete).to be_empty
    end

    it "does nothing without a recorder" do
      SimpleCov::Affected.instance_variable_set(:@recorder, nil)

      expect(described_class.note_filters(config)).to be_nil
    end
  end

  describe ".mark" do
    # Groups are classes, and nested groups are their subclasses, which is all
    # `mark` relies on.
    let(:top) do
      Class.new do
        class << self
          def metadata = {rerun_file_path: "/proj/spec/a_spec.rb"}

          def hooks = (@hooks ||= [])

          def prepend_before(scope, &hook) = hooks << [:before, scope, hook]

          def prepend_after(scope, &hook) = hooks << [:after, scope, hook]
        end
      end
    end
    let(:child) { Class.new(top) }
    let(:grandchild) { Class.new(child) }

    before { grandchild }

    it "opens the spec file's context before the top group's own hooks" do
      described_class.mark(top)

      expect(SimpleCov).to have_received(:track_test).with("spec/a_spec.rb")
    end

    it "puts a boundary before every nested group's context hooks and after every group's" do
      described_class.mark(top)

      expect([top, child, grandchild].map { |group| group.hooks.map { |kind, scope, _| [kind, scope] } })
        .to eq([[[:after, :context]], [[:before, :context], [:after, :context]], [[:before, :context], [:after, :context]]])
    end

    it "makes each boundary open the spec file's context" do
      described_class.mark(top)
      [top, child, grandchild].each { |group| group.hooks.each { |_, _, hook| hook.call } }

      expect(SimpleCov).to have_received(:track_test).with("spec/a_spec.rb").exactly(6).times
    end

    it "leaves a group alone without a recorder" do
      SimpleCov::Affected.instance_variable_set(:@recorder, nil)
      described_class.mark(top)

      expect(top.hooks).to be_empty
    end

    it "leaves a group outside the project alone" do
      allow(top).to receive(:metadata).and_return(rerun_file_path: "/gems/x_spec.rb")
      described_class.mark(top)

      expect(SimpleCov).not_to have_received(:track_test)
    end
  end
end
