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

  describe "the runner's filters" do
    # Minitest 5 hands the options to `run`, Minitest 6 to
    # `filter_runnable_methods`; the stand-in answers both.
    let(:runnable) do
      Class.new do
        def self.run(*args, **) = args

        def self.filter_runnable_methods(_options = {}) = [:test_a]
      end.tap { |klass| klass.singleton_class.prepend(SimpleCov::Affected::Minitest::Filters) }
    end

    def complete_after
      with_recorder("/proj") do |recorder|
        recorder.boundary("test/a_test.rb")
        yield
        recorder.complete
      end
    end

    it "notes a name filter handed to run" do
      expect(complete_after { runnable.run(:reporter, {filter: "/x/"}) }).to be_empty
    end

    it "notes an exclusion handed to filter_runnable_methods" do
      expect(complete_after { runnable.filter_runnable_methods(exclude: "x") }).to be_empty
    end

    it "keeps every file complete without filters" do
      expect(complete_after { runnable.run(:klass, :name, :reporter) && runnable.run(seed: 1) }).to eq(%w[test/a_test.rb])
    end

    it "answers what Minitest answers" do
      expect([runnable.run(:reporter, {}), runnable.filter_runnable_methods]).to eq([[:reporter, {}], [:test_a]])
    end
  end

  describe "narrowing" do
    let(:runnable) do
      Class.new do
        def self.runnable_methods = %w[test_kept test_left test_elsewhere]

        def test_kept
        end

        def test_left
        end

        define_method(:test_elsewhere) {}
      end
    end

    before do
      stub_const("NarrowTest", runnable)
      described_class.install(NarrowTest, narrow: true)
      SimpleCov::Affected.instance_variable_set(:@plan,
        SimpleCov::Affected::Plan.new(nil, {"spec/simple_cov/affected/minitest_spec.rb::NarrowTest#test_left" => nil}))
      allow(described_class).to receive(:file).and_call_original
      allow(described_class).to receive(:file).with(NarrowTest, "test_elsewhere").and_return(nil)
    end

    after { SimpleCov::Affected.instance_variable_set(:@plan, nil) }

    it "leaves out the tests the plan does not run, and keeps one with no file" do
      expect(with_recorder(File.dirname(__dir__, 3)) { NarrowTest.runnable_methods }).to eq(%w[test_kept test_elsewhere])
    end
  end

  it "just runs the test without a recorder" do
    expect(CalcTest.new("test_0007_adds").run).to eq(:result)
  end
end
