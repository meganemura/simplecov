# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::TrackerHooks do
  include AffectedHelpers

  let(:host) do
    base = Module.new do
      def rspec_example_id(_example) = "spec/a_spec.rb:3"

      def minitest_test_id(_test) = "test/a_test.rb:3"

      def install_minitest_hook(*) = :installed
    end
    Class.new { include base }.tap { |klass| klass.prepend(described_class) }.new
  end

  let(:example) { instance_double(RSpec::Core::Example, metadata: {affected_id: "spec/a_spec.rb::A works"}) }

  it "keeps SimpleCov's ids without a recorder" do
    expect([host.rspec_example_id(example), host.minitest_test_id(nil)]).to eq(%w[spec/a_spec.rb:3 test/a_test.rb:3])
  end

  it "names an example by its stable id" do
    expect(with_recorder("/proj") { host.rspec_example_id(example) }).to eq("spec/a_spec.rb::A works")
  end

  it "falls back to SimpleCov's id for an example Affected did not name" do
    unnamed = instance_double(RSpec::Core::Example, metadata: {})

    expect(with_recorder("/proj") { host.rspec_example_id(unnamed) }).to eq("spec/a_spec.rb:3")
  end

  it "names a Minitest test by its stable id" do
    test = Struct.new(:name).new("test_works")
    allow(SimpleCov::Affected::Minitest).to receive(:id).with(test.class, "test_works").and_return("stable")

    expect(with_recorder("/proj") { host.minitest_test_id(test) }).to eq("stable")
  end

  it "answers what SimpleCov's Minitest install answers" do
    allow(SimpleCov::Affected).to receive(:install_minitest)

    expect(host.install_minitest_hook).to eq(:installed)
  end

  it "installs Affected's Minitest wrapper beside SimpleCov's" do
    allow(SimpleCov::Affected).to receive(:install_minitest)
    host.install_minitest_hook

    expect(SimpleCov::Affected).to have_received(:install_minitest)
  end
end
