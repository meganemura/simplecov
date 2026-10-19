# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::LoadHook do
  include AffectedHelpers

  let(:host) do
    kernel = Module.new do
      private

      def load(file, *) = [:load, file]

      def require(feature) = [:require, feature]
    end
    Class.new { include kernel }.tap { |klass| klass.prepend(described_class) }.new
  end

  before { allow(SimpleCov).to receive(:track_test).and_yield }

  it "charges a loaded spec file to itself" do
    with_recorder("/proj") { host.send(:load, "/proj/spec/a_spec.rb") }

    expect(SimpleCov).to have_received(:track_test).with("spec/a_spec.rb")
  end

  it "charges a required test file to itself" do
    with_recorder("/proj") { host.send(:require, "/proj/test/a_test.rb") }

    expect(SimpleCov).to have_received(:track_test).with("test/a_test.rb")
  end

  it "answers what the load answers" do
    expect(with_recorder("/proj") { host.send(:load, "/proj/spec/a_spec.rb", true) })
      .to eq([:load, "/proj/spec/a_spec.rb"])
  end

  it "passes loads straight through without a recorder" do
    expect([host.send(:load, "a.rb"), host.send(:require, "b")]).to eq([[:load, "a.rb"], [:require, "b"]])
  end
end
