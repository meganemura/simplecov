# frozen_string_literal: true

require "helper"
require "coverage"
require "support/affected"

RSpec.describe SimpleCov::Affected::TrackerClose do
  subject(:tracker) { SimpleCov::TestTracker.new(root_regex: %r{\A/proj/}) }

  let(:file) { "/proj/app/models/room.rb" }

  it "leaves what runs after it closes to no context" do
    allow(Coverage).to receive(:peek_result).and_return(*[[0, 0, 0], [1, 0, 0], [1, 1, 1]].map { |lines| {file => {lines: lines}} })
    tracker.track("t") {}
    tracker.close
    map = tracker.recorded_map(closing: {file => {lines: [1, 1, 1]}})

    expect([map.covering(file, 1), map.covering(file, 2)]).to eq([["t"], []])
  end
end
