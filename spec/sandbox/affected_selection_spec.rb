# frozen_string_literal: true

require "helper"
require "support/sandbox_project"

RSpec.describe "simplecov/affected selection", :sandbox do
  let(:config) do
    <<~RUBY
      require 'simplecov'
      require 'simplecov/affected'
      SimpleCov.start { track_tests }
    RUBY
  end

  before { setup_project("faked_project") }

  def edit(path, from, to) = write_file(path, read_file(path).sub(from, to))

  describe "an RSpec suite" do
    before do
      configure_simplecov(:rspec, config)
      run_command(sorted_rspec_command)
      edit("lib/faked_project/some_class.rb", "label.reverse", "label.reverse.itself")
    end

    context "when selecting" do
      before { run_command(sorted_rspec_command) }

      it "runs only the examples the change reaches" do
        expect(last_command.output).to include("1 example, 0 failures")
      end

      it "says what it runs" do
        expect(last_command.output).to match(/SimpleCov affected: running 1 of \d+ recorded tests, and any new ones/)
      end

      it "keeps the records of the examples it left out" do
        expect(JSON.parse(read_file("coverage/.affected.json")).fetch("tests"))
          .to include("spec/some_class_spec.rb::SomeClass should compare with 'foo'")
      end
    end

    context "when auditing" do
      before { run_command(sorted_rspec_command, env: {"SIMPLECOV_AFFECTED" => "audit"}) }

      def audit = JSON.parse(read_file("coverage/.affected-audit.json"))

      it "runs every example" do
        expect(last_command.output).not_to include("1 example,")
      end

      it "writes down what the selection would have run, and why" do
        expect(audit.fetch("reasons")).to eq("spec/some_class_spec.rb::SomeClass should be reversible" => "def lib/faked_project/some_class.rb SomeClass#reverse")
      end

      it "writes down that no example it would have skipped failed" do
        expect(audit).to include("skipped_failures" => [], "selected" => 1)
      end
    end
  end

  describe "a Minitest suite" do
    before do
      self.bundle_with = "minitest"
      install_dependencies
      configure_simplecov(:minitest, config)
      run_command_and_expect_success("bundle exec rake minitest")
      edit("lib/faked_project/some_class.rb", "label.reverse", "label.reverse.itself")
      run_command_and_expect_success("bundle exec rake minitest")
    end

    it "runs only the tests the change reaches" do
      expect(last_command.output.scan(/^\w+#test_\w+/)).to contain_exactly("SomeTest#test_reverse", "OtherTest#test_reverse")
    end
  end
end
