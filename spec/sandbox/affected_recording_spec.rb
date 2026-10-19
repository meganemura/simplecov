# frozen_string_literal: true

require "helper"
require "support/sandbox_project"

RSpec.describe "simplecov/affected recording", :sandbox do
  let(:config) do
    <<~RUBY
      require 'simplecov'
      require 'simplecov/affected'
      SimpleCov.start do
        track_tests
        affected :all
      end
    RUBY
  end

  before { setup_project("faked_project") }

  def sidecar = JSON.parse(read_file("coverage/.affected.json"))

  def test_record(id) = sidecar.fetch("tests").fetch(id)

  describe "an RSpec suite" do
    before do
      write_file("data/answer.yml", "answer: 42\n")
      write_file("spec/reading_spec.rb", <<~RUBY)
        require "spec_helper"
        require "yaml"

        SomeClass.new("loaded").reverse

        RSpec.describe "reading" do
          it "reads its data" do
            expect(YAML.load_file("data/answer.yml")).to eq("answer" => 42)
          end

          it { expect(SomeClass.new("ab").reverse).to eq("ba") }

          it "fails" do
            expect(1).to eq(2)
          end
        end
      RUBY
      configure_simplecov(:rspec, config)
      run_command(sorted_rspec_command)
    end

    it "names each example by its file and full description" do
      expect(sidecar.fetch("tests").keys).to include("spec/reading_spec.rb::reading reads its data",
        "spec/reading_spec.rb::reading {1}")
    end

    it "records the lines each example ran, against the source it ran" do
      digest = sidecar.dig("latest", "lib/faked_project/some_class.rb")

      expect(test_record("spec/reading_spec.rb::reading {1}").dig("lines", "lib/faked_project/some_class.rb"))
        .to match([digest, /\A\h+\z/])
    end

    it "records the data files an example read" do
      expect(test_record("spec/reading_spec.rb::reading reads its data").fetch("reads")).to eq(["data/answer.yml"])
    end

    it "records whether each example passed" do
      expect(%w[reads\ its\ data fails].map { |name| test_record("spec/reading_spec.rb::reading #{name}").fetch("ok") })
        .to eq([true, false])
    end

    it "charges the code a spec file runs as it loads to the file" do
      expect(sidecar.dig("loads", "spec/reading_spec.rb", "lines")).to have_key("lib/faked_project/some_class.rb")
    end

    it "keeps the test files' sources, which the report filters out" do
      expect(sidecar.fetch("files")).to have_key("spec/reading_spec.rb")
    end
  end

  describe "a later run of part of the suite" do
    before do
      write_file("spec/reading_spec.rb", <<~RUBY)
        require "spec_helper"

        RSpec.describe "reading" do
          it("passes") { expect(1).to eq(1) }
          it("fails") { expect(1).to eq(2) }
        end
      RUBY
      configure_simplecov(:rspec, config)
      run_command(sorted_rspec_command)
      run_command("bundle exec rspec spec/reading_spec.rb -e passes")
    end

    it "keeps the records of the tests it did not run" do
      expect(test_record("spec/reading_spec.rb::reading fails").fetch("ok")).to be(false)
    end

    it "keeps the other spec files' records" do
      expect(sidecar.fetch("tests").keys.map { |id| id.split("::").first }.uniq.size).to be > 1
    end

    it "folds its parts away" do
      expect(file_exist?("coverage/.affected-parts")).to be(false)
    end
  end

  describe "a run whose tests run in forked workers" do
    before do
      self.bundle_with = "minitest"
      install_dependencies
      write_file("test/forked_test.rb", <<~RUBY)
        class ForkedTest < Minitest::Test
          def test_reverse = assert_equal("ba", SomeClass.new("ab").reverse)

          def test_compare = assert(SomeClass.new("ab").compare_with("ab"))
        end
      RUBY
      write_file("fork_run.rb", <<~RUBY)
        require "simplecov"
        require "simplecov/affected"
        SimpleCov.start do
          track_tests
          affected :all
          merge_subprocesses true
        end
        require "minitest"
        require_relative "lib/faked_project"
        load File.expand_path("test/forked_test.rb")
        %w[test_reverse test_compare].map { |name| fork { ForkedTest.new(name).run } }.each { |pid| Process.wait(pid) }
      RUBY
      run_command_and_expect_success("bundle exec ruby fork_run.rb")
    end

    it "folds every worker's tests into one recording" do
      expect(sidecar.fetch("tests").keys).to contain_exactly("test/forked_test.rb::ForkedTest#test_reverse",
        "test/forked_test.rb::ForkedTest#test_compare")
    end

    it "records what each worker's test ran" do
      expect(test_record("test/forked_test.rb::ForkedTest#test_reverse").fetch("lines")).to have_key("lib/faked_project/some_class.rb")
    end
  end

  describe "a Minitest suite" do
    before do
      self.bundle_with = "minitest"
      install_dependencies
      configure_simplecov(:minitest, config)
      run_command_and_expect_success("bundle exec rake minitest")
    end

    it "names each test by its file, class, and method" do
      expect(sidecar.fetch("tests").keys).to include("minitest/some_test.rb::SomeTest#test_reverse")
    end

    it "records each test's outcome and time" do
      expect(test_record("minitest/some_test.rb::SomeTest#test_reverse")).to include("ok" => true, "time" => a_kind_of(Float))
    end
  end
end
