# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::Lifecycle do
  include AffectedHelpers

  # Stands in for SimpleCov's singleton: what the lifecycle wraps answers
  # fixed values, and the run state is a real one.
  let(:host_class) do
    Struct.new(:current_run, :final) do
      def start_test_tracking = :started

      def collect_own_coverage(standalone:) = standalone

      def result = (current_run.result ||= :result)

      def final_result_process? = final
    end.tap { |klass| klass.prepend(described_class) }
  end
  let(:host) { host_class.new(SimpleCov::CurrentRun.new, true) }

  before { allow(SimpleCov::Affected).to receive_messages(start: nil, capture: nil, finish: nil) }

  around { |example| with_recorder("/proj") { example.run } }

  it "answers what starting the tracking answers" do
    expect(host.start_test_tracking).to eq(:started)
  end

  it "starts Affected once tracking is set up" do
    host.start_test_tracking

    expect(SimpleCov::Affected).to have_received(:start)
  end

  it "captures this process's result once it exists" do
    host.current_run.result = :own
    host.collect_own_coverage(standalone: true)

    expect(SimpleCov::Affected).to have_received(:capture).with(:own)
  end

  it "answers what collecting answers" do
    expect(host.collect_own_coverage(standalone: true)).to be(true)
  end

  it "captures nothing when no result was collected" do
    host.collect_own_coverage(standalone: false)

    expect(SimpleCov::Affected).not_to have_received(:capture)
  end

  it "finishes in the process that owns the final result" do
    host.result

    expect(SimpleCov::Affected).to have_received(:finish)
  end

  it "answers the result" do
    expect(host.result).to eq(:result)
  end

  it "does not finish in a worker whose result another process merges" do
    host.final = false
    host.result

    expect(SimpleCov::Affected).not_to have_received(:finish)
  end

  it "finishes once, not on every later read of the result" do
    2.times { host.result }

    expect(SimpleCov::Affected).to have_received(:finish).once
  end

  context "without a recorder" do
    before do
      SimpleCov::Affected.instance_variable_set(:@recorder, nil)
      host.current_run.result = :own
      host.collect_own_coverage(standalone: true)
      host.current_run.result = nil
      host.result
    end

    it "captures nothing" do
      expect(SimpleCov::Affected).not_to have_received(:capture)
    end

    it "finishes nothing" do
      expect(SimpleCov::Affected).not_to have_received(:finish)
    end
  end
end
