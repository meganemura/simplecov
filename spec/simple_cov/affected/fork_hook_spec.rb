# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::ForkHook do
  let(:process) do
    Class.new do
      def initialize(pid) = @pid = pid

      def _fork = @pid

      prepend SimpleCov::Affected::ForkHook
    end
  end

  let(:recorder) { instance_double(SimpleCov::Affected::Recorder, forked: nil) }

  before { allow(SimpleCov::Affected).to receive(:recorder).and_return(recorder) }

  it "tells the recorder in the child" do
    process.new(0)._fork

    expect(recorder).to have_received(:forked)
  end

  it "forks a child with nothing to tell when nothing records" do
    allow(SimpleCov::Affected).to receive(:recorder).and_return(nil)

    expect(process.new(0)._fork).to eq(0)
  end

  it "leaves the parent alone" do
    process.new(42)._fork

    expect(recorder).not_to have_received(:forked)
  end
end
