# frozen_string_literal: true

require "helper"
require "simplecov/cli"
require "support/cli_context"
require "support/git_fixture"

RSpec.describe SimpleCov::CLI do
  include_context "a CLI"

  describe "affected subcommand over recorded units", mutant_expression: "SimpleCov::CLI::Affected*" do
    def recorded
      <<~RUBY
        # frozen_string_literal: true

        class Calc
          def add(a, b)
            a + b
          end

          def doubled(items)
            items.map do |item|
              item * 2
            end
          end

          def self.table
            [1, 2]
          end

          LIMIT = 10
        end
      RUBY
    end

    def shapes
      <<~RUBY
        module Shapes
          class << self
            def area
              square = ->(side) do
                side * side
              end
              square.call(2)
            end
          end

          def self.labels
            [1].each do |n|
              n.to_s
            end
            [].each do |n|
              n.to_s
            end
            {}.fetch(:key) do |key|
              key
            end
          end

          def self.safe
            Integer("x")
          rescue ArgumentError
            0
          end

          def self.nothing
          end

          def self.one = 1

          def self.only_rescue
          rescue
            nil
          end
        end
      RUBY
    end

    # Line hits as a run would record them: `table` ran once while the file
    # loaded, before any test, and so did every line outside the methods.
    let(:hits) { [nil, nil, 1, 1, 2, nil, nil, 1, 2, 2, nil, nil, nil, 1, 1, nil, nil, 1, nil] }
    # add_spec ran `add`, doubled_spec entered the block, empty_spec ran
    # `doubled` over no items and so never entered it.
    let(:entry) do
      {"source" => recorded.lines.map(&:chomp), "lines" => hits,
       "contexts" => {"0" => line_bits(5), "1" => line_bits(9, 10), "2" => line_bits(9)}}
    end
    let(:tmp) do
      specs = %w[add doubled empty area labels safe].to_h { |name| ["spec/#{name}_spec.rb", ""] }
      GitFixture.checkout("lib/calc.rb" => recorded, "lib/shapes.rb" => shapes, ".gitignore" => "coverage.json\n", **specs)
    end

    # area_spec called the lambda, labels_spec entered the first `each` but not
    # the second, and safe_spec went through the rescue.
    def shapes_entry
      hits = Array.new(shapes.lines.size)
      {3 => 1, 4 => 1, 5 => 1, 7 => 1, 12 => 1, 13 => 1, 15 => 1, 16 => 0, 18 => 1, 19 => 1, 24 => 1, 26 => 1}
        .each { |line, count| hits[line - 1] = count }
      {"source" => shapes.lines.map(&:chomp), "lines" => hits,
       "contexts" => {"3" => line_bits(4, 5, 7), "4" => line_bits(12, 13, 15, 18, 19), "5" => line_bits(24, 26)}}
    end

    def payload
      contexts = %w[spec/add_spec.rb:3 spec/doubled_spec.rb:3 spec/empty_spec.rb:3
        spec/area_spec.rb:1 spec/labels_spec.rb:1 spec/safe_spec.rb:1]
      {"contexts" => contexts, "coverage" => {"lib/calc.rb" => entry, "lib/shapes.rb" => shapes_entry}}
    end

    def every_file = "spec/add_spec.rb\nspec/doubled_spec.rb\nspec/empty_spec.rb\n"

    def line_bits(*lines) = lines.sum { |line| 1 << (line - 1) }.to_s(16)

    def json_path = File.join(tmp, "coverage.json")

    def edit!(from, to, file: "lib/calc.rb")
      path = File.join(tmp, file)
      source = File.read(path)
      raise "#{from.inspect} is not in the fixture" unless source.include?(from)

      File.write(path, source.sub(from, to))
    end

    def affected(*flags)
      File.write(json_path, JSON.dump(payload))
      Dir.chdir(tmp) { ok!(run("affected", "--input", json_path, *flags)) }
    end

    def selected_contexts
      affected("--json")
      JSON.parse(stdout.string).fetch("contexts")
    end

    after { FileUtils.rm_rf(tmp) }

    context "with an edit inside a lambda in a singleton method" do
      before { edit!("side * side", "side + side", file: "lib/shapes.rb") }

      it "selects only the tests that called the lambda" do
        affected

        expect(stdout.string).to eq("spec/area_spec.rb\n")
      end
    end

    context "with an edit inside the second of two blocks of one name" do
      before { edit!("  [].each do |n|\n      n.to_s", "  [].each do |n|\n      n.inspect", file: "lib/shapes.rb") }

      it "selects nothing, since no test entered that block" do
        affected

        expect(stdout.string).to be_empty
      end
    end

    context "with an edit inside a rescue clause" do
      before { edit!("    0\n", "    1\n", file: "lib/shapes.rb") }

      it "selects the tests that ran the method" do
        affected

        expect(stdout.string).to eq("spec/safe_spec.rb\n")
      end
    end

    context "with an edit inside one method" do
      before { edit!("a + b", "a - b") }

      it "selects only the test files that ran the method" do
        affected

        expect(stdout.string).to eq("spec/add_spec.rb\n")
      end

      it "names the recorded tests that ran it" do
        expect(selected_contexts).to eq(["spec/add_spec.rb:3"])
      end
    end

    context "with an edit inside a block" do
      before { edit!("item * 2", "item * 3") }

      it "selects only the tests that entered the block" do
        affected

        expect(stdout.string).to eq("spec/doubled_spec.rb\n")
      end
    end

    context "with an edit in a method around a block" do
      before { edit!("items.map", "items.reverse.map") }

      it "selects every test that ran the method, inside the block or not" do
        affected

        expect(stdout.string).to eq("spec/doubled_spec.rb\nspec/empty_spec.rb\n")
      end
    end

    context "with a block renamed inside its method" do
      before { edit!("items.map do", "items.each do") }

      it "selects every test that ran the method" do
        affected

        expect(stdout.string).to eq("spec/doubled_spec.rb\nspec/empty_spec.rb\n")
      end
    end

    context "with a block added inside a method" do
      before { edit!("a + b\n", "[a, b].sum do |n|\n      n\n    end\n") }

      it "selects the tests that ran the method holding it" do
        affected

        expect(stdout.string).to eq("spec/add_spec.rb\n")
      end
    end

    context "with changes that leave every token in place" do
      before do
        edit!("  def add(a, b)\n    a + b\n  end\n\n", "")
        edit!("  def self.table", "  def add(a, b)\n    # sum them\n\n        a +   b # still a sum\n  end\n\n  def self.table")
      end

      it "selects nothing" do
        affected

        expect(stdout.string).to be_empty
      end

      it "says no recorded test touches the change" do
        affected

        expect(stderr.string).to eq("simplecov affected: no recorded test touches the changed code\n")
      end
    end

    context "with a changed magic comment" do
      before { edit!("frozen_string_literal: true", "frozen_string_literal: false") }

      it "selects every test touching the file" do
        affected

        expect(stdout.string).to eq(every_file)
      end
    end

    {
      "outside every unit" => ["LIMIT = 10", "LIMIT = 11"],
      "in a method's parameters" => ["def add(a, b)", "def add(a, b = 0)"],
      "that adds a method" => ["  LIMIT = 10\n", "  LIMIT = 10\n\n  def sub(a, b)\n    a - b\n  end\n"],
      "that removes a method" => ["  def add(a, b)\n    a + b\n  end\n", ""],
      "that renames a method" => ["def add(a, b)", "def plus(a, b)"],
      "that defines a method inside a block" => ["item * 2", "def helper\n        1\n      end\n      item * 2"],
      "inside a method that ran while no test was recorded" => ["[1, 2]", "[1, 3]"],
      "that no longer parses" => ["a + b", "a +"]
    }.each do |where, (from, to)|
      context "with an edit #{where}" do
        before { edit!(from, to) }

        it "selects every test touching the file, as before units" do
          affected

          expect(stdout.string).to eq(every_file)
        end
      end
    end

    context "with an edit to a block whose first line coverage does not report" do
      let(:hits) { super().tap { |lines| lines[9] = nil } }

      before { edit!("item * 2", "item * 3") }

      it "selects every test touching the file" do
        affected

        expect(stdout.string).to eq(every_file)
      end
    end

    context "with an edit to a method no test ran" do
      let(:hits) { super().tap { |lines| lines[14] = 0 } }

      before { edit!("[1, 2]", "[1, 3]") }

      it "selects nothing" do
        affected

        expect(stdout.string).to be_empty
      end
    end

    {
      "without the recorded source" => -> { entry.delete("source") },
      "with a recorded source that is not a list of lines" => -> { entry["source"] = [1] },
      "without line hits" => -> { entry.delete("lines") }
    }.each do |report, strip|
      context "with a report #{report}" do
        before do
          instance_exec(&strip)
          edit!("a + b", "a - b")
        end

        it "selects every test touching the file, as before units" do
          affected

          expect(stdout.string).to eq(every_file)
        end
      end
    end

    context "with a recorded source that does not parse" do
      let(:entry) { super().merge("source" => ["<%= title %>"]) }

      before { edit!("a + b", "a - b") }

      it "selects every test touching the file" do
        affected

        expect(stdout.string).to eq(every_file)
      end
    end

    context "with the file deleted" do
      before { File.delete(File.join(tmp, "lib/calc.rb")) }

      it "selects every test that ran it" do
        affected

        expect(stdout.string).to eq(every_file)
      end
    end

    context "when Prism cannot load" do
      before do
        allow(SimpleCov::StaticCoverageExtractor).to receive(:prism_loaded?).and_return(false)
        edit!("a + b", "a - b")
      end

      it "selects every test touching the file, as before units" do
        affected

        expect(stdout.string).to eq(every_file)
      end
    end
  end
end
