# frozen_string_literal: true

require "helper"
require "coverage"
require "support/affected"

RSpec.describe SimpleCov::Affected::TrackerAside do
  subject(:tracker) { SimpleCov::TestTracker.new(root_regex: %r{\A/proj/}) }

  let(:file) { "/proj/app/models/room.rb" }

  def peeks(*counts)
    allow(Coverage).to receive(:peek_result).and_return(*counts.map { |lines| {file => {lines: lines}} })
  end

  def covering(line) = tracker.recorded_map.covering(file, line)

  context "with a load in the middle of a test" do
    before do
      # test opens, aside opens boot, aside reopens the test, the map flushes
      peeks([0, 0, 0], [1, 0, 0], [1, 1, 0], [1, 1, 1])
      tracker.track("t") { tracker.aside("(boot)") { :loaded } }
    end

    it "keeps what the test ran before and after the load" do
      expect([covering(1), covering(3)]).to eq([["t"], ["t"]])
    end

    it "charges what ran during the load to the other context" do
      expect(covering(2)).to eq(["(boot)"])
    end
  end

  it "answers the block's value" do
    peeks([0, 0, 0], [0, 0, 0], [0, 0, 0])
    tracker.track("t") {}

    expect(tracker.aside("(boot)") { :loaded }).to eq(:loaded)
  end

  it "does nothing before any segment is open" do
    allow(Coverage).to receive(:peek_result)
    tracker.aside("(boot)") { :loaded }

    expect(Coverage).not_to have_received(:peek_result)
  end

  it "does nothing when the open segment is the one asked for" do
    peeks([0, 0, 0], [0, 0, 0])
    tracker.track("(boot)") {}
    tracker.aside("(boot)") { :loaded }

    expect(Coverage).to have_received(:peek_result).once
  end

  it "leaves the segment alone for a thread that runs no test" do
    peeks([0, 0, 0], [1, 1, 0], [1, 1, 1])
    tracker.track("t") { Thread.new { tracker.aside("(boot)") { :loaded } }.join }

    expect(covering(2)).to eq(["t"])
  end

  it "leaves the segment alone once the load poisons the recording" do
    peeks([0, 0, 0], [0, 0, 0], [0, 0, 0])
    tracker.track("t") { tracker.aside("(boot)") { tracker.send(:poison) } }

    expect(Coverage).to have_received(:peek_result).twice
  end

  it "stops once the recording is poisoned" do
    peeks([0, 0, 0], [0, 0, 0])
    tracker.track("t") {}
    tracker.send(:poison)
    tracker.aside("(boot)") { :loaded }

    expect(Coverage).to have_received(:peek_result).once
  end
end
