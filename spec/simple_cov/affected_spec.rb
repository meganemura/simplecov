# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected do
  include AffectedHelpers

  let(:root) { Dir.mktmpdir }

  after { FileUtils.rm_rf(root) }

  describe ".start" do
    before do
      allow(SimpleCov).to receive_messages(affected: :select, root: root, coverage_path: File.join(root, "coverage"),
        test_tracker: SimpleCov::TestTracker)
      allow(SimpleCov).to receive(:track_test).and_yield
      allow(described_class::RSpec).to receive(:install)
      allow(described_class::Minitest).to receive(:install)
      allow($stderr).to receive(:puts)
      stub_const("Minitest::Test", Class.new)
    end

    after { %i[@recorder @plan @mode].each { |name| described_class.instance_variable_set(name, nil) } }

    def start_with(mode, plan = nil)
      allow(SimpleCov).to receive(:affected).and_return(mode)
      allow(described_class::Plan).to receive(:load).and_return(plan) if plan
      described_class.start
    end

    it "starts recording" do
      described_class.start

      expect(described_class.recorder).to be_a(described_class::Recorder)
    end

    it "opens the boot context" do
      described_class.start

      expect(SimpleCov).to have_received(:track_test).with("(boot)")
    end

    it "hooks file reads and test file loads" do
      described_class.start

      expect([File.singleton_class.ancestors.include?(described_class::ReadHook), Kernel.private_method_defined?(:simplecov_affected_original_require)])
        .to eq([true, true])
    end

    it "wires itself into RSpec" do
      described_class.start

      expect(described_class::RSpec).to have_received(:install).with(SimpleCov::TestTracker.rspec_module, narrow: false)
    end

    it "wires itself into a Minitest that is already loaded" do
      described_class.start

      expect(described_class::Minitest).to have_received(:install).with(Minitest::Test, narrow: false)
    end

    it "decides the plan from the last recording" do
      described_class.start

      expect(described_class.plan.full).to eq("no recording")
    end

    it "says what a selecting run runs" do
      described_class.start

      expect($stderr).to have_received(:puts).with("SimpleCov affected: running every test (no recording)")
    end

    it "narrows the runners when selecting tests the plan names" do
      start_with(:select, described_class::Plan.new(nil, {}))

      expect([described_class::RSpec, described_class::Minitest]).to all(have_received(:install).with(anything, narrow: true))
    end

    it "decides a plan for an audit but narrows nothing" do
      start_with(:audit, described_class::Plan.new(nil, {}))

      expect([described_class.plan, described_class.narrowing?]).to match([a_kind_of(described_class::Plan), false])
    end

    it "says nothing as an audit starts" do
      start_with(:audit, described_class::Plan.new(nil, {}))

      expect($stderr).not_to have_received(:puts)
    end

    it "decides no plan when running every test" do
      start_with(:all)

      expect(described_class.plan).to be_nil
    end

    it "starts once, so a forked worker keeps its parent's recorder" do
      described_class.start
      first = described_class.recorder
      described_class.start

      expect(described_class.recorder).to be(first)
    end

    it "stays out of a run that does not track tests" do
      allow(SimpleCov).to receive(:test_tracker).and_return(nil)
      described_class.start

      expect(described_class.recorder).to be_nil
    end

    it "stays out of the run when the mode is off" do
      allow(SimpleCov).to receive(:affected).and_return(:off)
      described_class.start

      expect(described_class.recorder).to be_nil
    end
  end

  describe ".settle" do
    let(:tracker) { instance_double(SimpleCov::TestTracker, close: nil) }

    before { allow(SimpleCov).to receive(:test_tracker).and_return(tracker) }

    it "closes the open segment" do
      described_class.settle

      expect(tracker).to have_received(:close)
    end

    it "stops charging reads" do
      with_recorder("/proj") do |recorder|
        described_class.settle
        recorder.read("/proj/app/views/a.html.erb")

        expect(recorder.boot_reads).to be_empty
      end
    end

    it "does nothing without tracking" do
      allow(SimpleCov).to receive(:test_tracker).and_return(nil)

      expect { described_class.settle }.not_to raise_error
    end
  end

  describe ".run?" do
    after { described_class.instance_variable_set(:@plan, nil) }

    def complete_after(plan, id)
      described_class.instance_variable_set(:@plan, plan)
      with_recorder("/proj") do |recorder|
        recorder.boundary("spec/a_spec.rb")
        [described_class.run?(id), recorder.complete]
      end
    end

    it "runs a test the plan gives a reason" do
      expect(complete_after(described_class::Plan.new(nil, {}), "spec/a_spec.rb::new")).to eq([true, %w[spec/a_spec.rb]])
    end

    it "leaves out a test the plan does not reach, and keeps its file's other records" do
      expect(complete_after(described_class::Plan.new(nil, {"spec/a_spec.rb::a" => nil}), "spec/a_spec.rb::a")).to eq([false, []])
    end

    it "runs every test without a plan" do
      expect(described_class.run?("spec/a_spec.rb::a")).to be(true)
    end

    it "leaves out a test the plan does not reach while nothing records" do
      described_class.instance_variable_set(:@plan, described_class::Plan.new(nil, {"spec/a_spec.rb::a" => nil}))

      expect(described_class.run?("spec/a_spec.rb::a")).to be(false)
    end
  end

  describe ".install_minitest" do
    before { allow(described_class::Minitest).to receive(:install) }

    it "does nothing before recording starts" do
      described_class.install_minitest

      expect(described_class::Minitest).not_to have_received(:install)
    end
  end

  describe ".capture and .finish" do
    let(:coverage_path) { File.join(root, "coverage") }
    let(:result) { Struct.new(:contexts, :original_result).new(SimpleCov::ContextMap.new, {}) }

    before { allow(SimpleCov).to receive_messages(root: root, coverage_path: coverage_path, run_id: "run") }

    def sidecar = File.join(coverage_path, ".affected.json")

    it "leaves this process's recording as a part of the run" do
      with_recorder(root, coverage_path) { described_class.capture(result) }

      expect(File.exist?(File.join(coverage_path, ".affected-parts/run/#{Process.pid}.json"))).to be(true)
    end

    it "folds the run's parts into the sidecar beside the report" do
      with_recorder(root, coverage_path) do
        described_class.capture(result)
        described_class.finish
      end

      expect(SimpleCov::Affected::Sidecar.read(sidecar)).to include("root" => root)
    end

    it "stops counting reads once the run is captured" do
      reads = with_recorder(root, coverage_path) do |recorder|
        described_class.capture(result)
        recorder.read(File.join(root, "late.yml")) || recorder.boot_reads
      end

      expect(reads).to be_empty
    end

    it "writes no part for a result without contexts" do
      with_recorder(root, coverage_path) { described_class.capture(Struct.new(:contexts, :original_result).new(nil, {})) }

      expect(Dir.exist?(File.join(coverage_path, ".affected-parts"))).to be(false)
    end

    context "with a plan" do
      before { described_class.instance_variable_set(:@plan, described_class::Plan.new(nil, {})) }

      after { %i[@plan @mode].each { |name| described_class.instance_variable_set(name, nil) } }

      def finish_as(mode)
        described_class.instance_variable_set(:@mode, mode)
        with_recorder(root, coverage_path) do
          described_class.capture(result)
          described_class.finish
        end
        File.exist?(File.join(coverage_path, ".affected-audit.json"))
      end

      it "writes an audit of the run when auditing" do
        allow($stderr).to receive(:puts)

        expect(finish_as(:audit)).to be(true)
      end

      it "writes no audit when selecting" do
        expect(finish_as(:select)).to be(false)
      end
    end

    it "captures nothing without a recorder" do
      described_class.capture(result)
      described_class.finish

      expect(File.exist?(sidecar)).to be(false)
    end
  end
end
