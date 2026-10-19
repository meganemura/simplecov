# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::Recorder do
  subject(:recorder) { described_class.new("/proj", "/proj/coverage") }

  before { allow(SimpleCov).to receive(:track_test).and_yield }

  describe "#test" do
    it "records a passing test with its file, line, and time" do
      recorder.test("spec/a_spec.rb::A works", file: "spec/a_spec.rb", line: 3) { true }

      expect(recorder.tests.fetch("spec/a_spec.rb::A works")).to have_attributes(
        file: "spec/a_spec.rb", line: 3, ok: true, must_run: false, time: a_value >= 0
      )
    end

    it "records a test that answers false as failed" do
      recorder.test("t", file: nil, line: nil) { false }

      expect(recorder.tests.fetch("t").ok).to be(false)
    end

    it "lets a test's error through" do
      expect { recorder.test("t", file: nil, line: nil) { raise "boom" } }.to raise_error("boom")
    end

    it "records a test that raises as failed" do
      suppress(RuntimeError) { recorder.test("t", file: nil, line: nil) { raise "boom" } }

      expect(recorder.tests.fetch("t").ok).to be(false)
    end

    it "keeps the must-run mark" do
      recorder.test("t", file: nil, line: nil, must_run: true) { true }

      expect(recorder.tests.fetch("t").must_run).to be(true)
    end

    it "answers whether the test passed" do
      expect(recorder.test("t", file: nil, line: nil) { true }).to be(true)
    end

    it "gives the test the data files read while it ran" do
      recorder.test("t", file: nil, line: nil) do
        recorder.read("/proj/spec/fixtures/a.yml")
        true
      end

      expect(recorder.tests.fetch("t").reads.to_a).to eq(["spec/fixtures/a.yml"])
    end

    it "gives reads after the test back to boot" do
      recorder.test("t", file: nil, line: nil) { true }
      recorder.read("/proj/config/b.yml")

      expect(recorder.boot_reads.to_a).to eq(["config/b.yml"])
    end
  end

  describe "#read" do
    it "ignores Ruby files, whose code coverage already tracks" do
      recorder.read("/proj/lib/a.rb")

      expect(recorder.boot_reads).to be_empty
    end

    it "ignores files outside the project" do
      recorder.read("/elsewhere/a.yml")

      expect(recorder.boot_reads).to be_empty
    end

    it "ignores the coverage output" do
      recorder.read("/proj/coverage/.resultset.json")

      expect(recorder.boot_reads).to be_empty
    end

    it "ignores directories that hold no project source" do
      recorder.read("/proj/vendor/bundle/a.yml")

      expect(recorder.boot_reads).to be_empty
    end

    it "takes a path-like object" do
      recorder.read(Pathname("/proj/data/a.csv"))

      expect(recorder.boot_reads.to_a).to eq(["data/a.csv"])
    end

    it "records nothing once SimpleCov reads for itself" do
      recorder.stop_reading
      recorder.read("/proj/data/a.csv")

      expect(recorder.boot_reads).to be_empty
    end
  end

  describe "#loading" do
    it "charges a test file's load to the file" do
      recorder.loading("/proj/spec/a_spec.rb") { :loaded }

      expect(SimpleCov).to have_received(:track_test).with("spec/a_spec.rb")
    end

    it "answers the load's value" do
      expect(recorder.loading("/proj/spec/a_spec.rb") { :loaded }).to eq(:loaded)
    end

    it "gives the file the reads made while it loads" do
      recorder.loading("/proj/test/a_test.rb") { recorder.read("/proj/test/data.json") }

      expect(recorder.loads.fetch("test/a_test.rb").to_a).to eq(["test/data.json"])
    end

    it "gives reads after the load back to whoever came before" do
      recorder.loading("/proj/test/a_test.rb") { :loaded }
      recorder.read("/proj/data.json")

      expect(recorder.boot_reads.to_a).to eq(["data.json"])
    end

    it "leaves a file that is no test file alone" do
      recorder.loading("/proj/lib/a.rb") { :loaded }

      expect(SimpleCov).not_to have_received(:track_test)
    end

    it "still answers the load of a file that is no test file" do
      expect(recorder.loading("/proj/lib/a.rb") { :loaded }).to eq(:loaded)
    end

    it "recognizes every naming convention for test files" do
      files = %w[test/test_a.rb test/spec_a.rb spec/a_spec.rb test/a_test.rb lib/a.rb]
      found = files.filter_map { |file| recorder.test_file("/proj/#{file}") }

      expect(found).to eq(%w[test/test_a.rb test/spec_a.rb spec/a_spec.rb test/a_test.rb])
    end
  end

  describe "#boundary" do
    it "opens the file's context" do
      recorder.boundary("spec/a_spec.rb")

      expect(SimpleCov).to have_received(:track_test).with("spec/a_spec.rb")
    end

    it "gives the file the reads that follow" do
      recorder.boundary("spec/a_spec.rb")
      recorder.read("/proj/data.json")

      expect(recorder.loads.fetch("spec/a_spec.rb").to_a).to eq(["data.json"])
    end
  end

  it "opens the boot context as it starts" do
    recorder.start

    expect(SimpleCov).to have_received(:track_test).with("(boot)")
  end
end
