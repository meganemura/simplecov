# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::Minitest do
  include AffectedHelpers

  let(:test_case) do
    Class.new do
      attr_accessor :name, :passed, :skipped

      def initialize(name) = (@name = name)

      def run = :result

      def passed? = passed

      def skipped? = skipped

      def test_0007_adds
      end
    end.tap { |klass| described_class.install(klass) }
  end

  before do
    stub_const("CalcTest", test_case)
    allow(SimpleCov).to receive(:track_test).and_yield
  end

  def recorded(test)
    with_recorder(File.dirname(__dir__, 3)) do |recorder|
      test.run
      recorder.tests
    end
  end

  it "names a test by file, class, and method, without minitest/spec's number" do
    expect(with_recorder(File.dirname(__dir__, 3)) { described_class.id(CalcTest, "test_0007_adds") })
      .to eq("spec/simple_cov/affected/minitest_spec.rb::CalcTest#test_adds")
  end

  it "names a test without a file while nothing records" do
    expect(described_class.id(CalcTest, "test_0007_adds")).to eq("::CalcTest#test_adds")
  end

  it "names a test whose method it cannot find without a file" do
    expect(described_class.id(CalcTest, "test_missing")).to eq("::CalcTest#test_missing")
  end

  it "records a passing test with its file and line" do
    test = CalcTest.new("test_0007_adds").tap { |run| run.passed = true }

    expect(recorded(test).fetch("spec/simple_cov/affected/minitest_spec.rb::CalcTest#test_adds"))
      .to have_attributes(file: "spec/simple_cov/affected/minitest_spec.rb", line: 21, ok: true)
  end

  it "records a skipped test as passing" do
    test = CalcTest.new("test_0007_adds").tap { |run| run.skipped = true }

    expect(recorded(test).values.map(&:ok)).to eq([true])
  end

  it "records a failing test as failed" do
    expect(recorded(CalcTest.new("test_0007_adds")).values.map(&:ok)).to eq([false])
  end

  it "answers what the run answers" do
    expect(with_recorder("/proj") { CalcTest.new("test_0007_adds").run }).to eq(:result)
  end

  it "just runs the test without a recorder" do
    expect(CalcTest.new("test_0007_adds").run).to eq(:result)
  end
end
