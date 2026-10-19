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
      stub_const("Minitest::Test", Class.new)
    end

    after { described_class.instance_variable_set(:@recorder, nil) }

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

      expect([File.singleton_class.ancestors, Kernel.ancestors])
        .to match([include(described_class::ReadHook), include(described_class::LoadHook)])
    end

    it "wires itself into RSpec" do
      described_class.start

      expect(described_class::RSpec).to have_received(:install).with(SimpleCov::TestTracker.rspec_module)
    end

    it "wires itself into a Minitest that is already loaded" do
      described_class.start

      expect(described_class::Minitest).to have_received(:install).with(Minitest::Test)
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

    before { allow(SimpleCov).to receive_messages(root: root, coverage_path: coverage_path) }

    after { described_class.instance_variable_set(:@captured, nil) }

    def sidecar = File.join(coverage_path, ".affected.json")

    it "writes the captured recording beside the report" do
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

    it "captures nothing without a recorder" do
      described_class.capture(result)
      described_class.finish

      expect(File.exist?(sidecar)).to be(false)
    end
  end
end
