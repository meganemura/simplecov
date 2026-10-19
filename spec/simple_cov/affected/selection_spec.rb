# frozen_string_literal: true

require "helper"
require "support/affected"
require "simplecov/affected/tree"
require "simplecov/affected/selection"

RSpec.describe SimpleCov::Affected::Selection do
  include AffectedProject

  let(:calc) do
    <<~RUBY
      class Calc
        LIMIT = 10
        def add(a, b)
          a + b
        end
        def sub(a, b)
          a - b
        end
        def twice(a) = a * 2
        def half(a); a / 2; end
      end
    RUBY
  end
  let(:spec) do
    <<~RUBY
      RSpec.describe Calc do
        it "adds" do
          expect(Calc.new.add(1, Calc::LIMIT)).to eq(11)
        end
        it "subtracts" do
          expect(Calc.new.sub(2, 1)).to eq(1)
        end
      end
    RUBY
  end
  let(:tests) do
    {"spec/calc_spec.rb::Calc adds" => {file: "spec/calc_spec.rb", line: 2, lines: {"lib/calc.rb" => [4], "spec/calc_spec.rb" => [3]}},
     "spec/calc_spec.rb::Calc subtracts" => {file: "spec/calc_spec.rb", line: 5, lines: {"lib/calc.rb" => [7, 10], "spec/calc_spec.rb" => [6]}}}
  end
  let(:loads) { {"spec/calc_spec.rb" => {lines: {"spec/calc_spec.rb" => [1, 2, 5]}}} }
  let(:document) { recording({"lib/calc.rb" => calc, "spec/calc_spec.rb" => spec}, tests: tests, loads: loads) }

  after { FileUtils.rm_rf(project_root) }

  def selected
    result = described_class.call(document, tree)
    result.full ? {full: result.full} : result.reasons.compact
  end

  def edit(path, from, to) = write_source(path, File.read(File.join(project_root, path)).sub(from, to))

  it "selects nothing when nothing changed" do
    document
    expect(selected).to be_empty
  end

  it "selects the tests that ran a changed method" do
    document
    edit("lib/calc.rb", "a + b", "a + b + 0")
    expect(selected).to eq("spec/calc_spec.rb::Calc adds" => "def lib/calc.rb Calc#add")
  end

  it "selects a test whose own block changed" do
    document
    edit("spec/calc_spec.rb", "eq(1)", "eq(1.0)")
    expect(selected).to match("spec/calc_spec.rb::Calc subtracts" => start_with("block spec/calc_spec.rb "))
  end

  it "selects the tests that called a changed one-line def" do
    document
    edit("lib/calc.rb", "a / 2;", "a / 3;")
    expect(selected).to eq("spec/calc_spec.rb::Calc subtracts" => "def lib/calc.rb Calc#half")
  end

  it "selects the tests that reach a changed constant by name" do
    document
    edit("lib/calc.rb", "LIMIT = 10", "LIMIT = 11")
    expect(selected).to eq("spec/calc_spec.rb::Calc adds" => "name LIMIT")
  end

  it "selects the tests in a class whose endless def changed, which a library may call unnamed" do
    document
    edit("lib/calc.rb", "a * 2", "a * 3")
    expect(selected.values.uniq).to eq(["name Calc"])
  end

  it "reruns the group whose body the load ran when an example is added" do
    document
    edit("spec/calc_spec.rb", "  it \"subtracts\"", "  it(\"new\") { }\n  it \"subtracts\"")
    expect(selected.keys.size).to eq(2)
  end

  it "selects the tests that called a one-line def that is gone" do
    document
    edit("lib/calc.rb", "  def half(a); a / 2; end\n", "")
    expect(selected).to eq("spec/calc_spec.rb::Calc subtracts" => "def lib/calc.rb Calc#half")
  end

  it "selects by the test's own lines alone when its file has no load record" do
    loads.clear
    document
    edit("lib/calc.rb", "a + b", "a + b + 0")
    expect(selected).to eq("spec/calc_spec.rb::Calc adds" => "def lib/calc.rb Calc#add")
  end

  it "selects a test that failed last time" do
    tests.fetch("spec/calc_spec.rb::Calc adds")[:ok] = false
    expect(selected).to eq("spec/calc_spec.rb::Calc adds" => "failed")
  end

  it "selects a test marked to run every time" do
    tests.fetch("spec/calc_spec.rb::Calc adds")[:must_run] = true
    expect(selected).to eq("spec/calc_spec.rb::Calc adds" => "must_run")
  end

  it "selects the tests that ran a file that is gone" do
    document
    File.delete(File.join(project_root, "lib/calc.rb"))
    expect(selected.values.uniq).to eq(["deleted lib/calc.rb"])
  end

  it "drops the tests of a test file that is gone" do
    document
    File.delete(File.join(project_root, "spec/calc_spec.rb"))
    expect(described_class.call(document, tree).reasons).to be_empty
  end

  it "selects every test that ran a file whose changed unit coverage does not report" do
    document.dig("files", "lib/calc.rb").each_value { |version| version.fetch("lines")[3] = nil }
    edit("lib/calc.rb", "a + b", "a + b + 0")
    expect(selected).to eq("spec/calc_spec.rb::Calc adds" => "def lib/calc.rb", "spec/calc_spec.rb::Calc subtracts" => "def lib/calc.rb")
  end

  context "with a unit whose first line coverage does not report" do
    let(:document) do
      recording({"lib/guard.rb" => "class Guard\n  def check(a)\n    begin\n      a.to_s\n    end if a\n  end\nend\n", "spec/guard_spec.rb" => "it\n"},
        tests: {"spec/guard_spec.rb::checks" => {file: "spec/guard_spec.rb", lines: {"lib/guard.rb" => [5]}},
                "spec/guard_spec.rb::other" => {file: "spec/guard_spec.rb", lines: {"lib/guard.rb" => [1]}}})
        .tap { |recorded| recorded.dig("files", "lib/guard.rb").each_value { |version| version.fetch("lines")[2] = nil } }
    end

    it "pins it down by the lines below it" do
      document
      edit("lib/guard.rb", "a.to_s", "a.to_sym")
      expect(selected).to eq("spec/guard_spec.rb::checks" => "def lib/guard.rb Guard#check")
    end
  end

  context "with data files" do
    before do
      write_source("data/rates.yml", "a: 1\n")
      tests.fetch("spec/calc_spec.rb::Calc adds")[:reads] = ["data/rates.yml"]
      document["reads"] = {"data/rates.yml" => SimpleCov::Affected::Sidecar.file_digest(File.join(project_root, "data/rates.yml"))}
    end

    it "selects the tests that read a changed data file" do
      write_source("data/rates.yml", "a: 2\n")
      expect(selected).to eq("spec/calc_spec.rb::Calc adds" => "read data/rates.yml")
    end

    it "keeps the tests that read an unchanged data file" do
      expect(selected).to be_empty
    end

    it "runs everything when a data file read before the first test file changed" do
      document["boot"]["reads"] = ["data/rates.yml"]
      write_source("data/rates.yml", "a: 2\n")
      expect(selected).to eq(full: "read data/rates.yml")
    end
  end

  it "reaches the names a template the test read mentions" do
    write_source("app/views/total.erb", "<%= Calc::LIMIT %>")
    tests.fetch("spec/calc_spec.rb::Calc subtracts")[:reads] = ["app/views/total.erb"]
    document["reads"] = {"app/views/total.erb" => SimpleCov::Affected::Sidecar.file_digest(File.join(project_root, "app/views/total.erb"))}
    edit("lib/calc.rb", "LIMIT = 10", "LIMIT = 11")
    expect(selected.keys).to include("spec/calc_spec.rb::Calc subtracts")
  end

  describe "a test file's load" do
    it "charges a unit of another file it ran to every test of the file" do
      loads.fetch("spec/calc_spec.rb")[:lines]["lib/calc.rb"] = [7]
      document
      edit("lib/calc.rb", "a - b", "a - b - 0")
      expect(selected.values).to eq(["def lib/calc.rb Calc#sub"] * 2)
    end

    it "charges a group of the test file to the tests written inside it" do
      document
      edit("spec/calc_spec.rb", "RSpec.describe Calc do\n", "RSpec.describe Calc do\n  let(:x) { 1 }\n")
      expect(selected.keys.size).to eq(2)
    end

    context "with two groups" do
      let(:spec) { "RSpec.describe Calc do\n  it \"adds\" do\n    1\n  end\nend\nRSpec.describe Calc do\n  it \"subtracts\" do\n    1\n  end\nend\n" }
      let(:tests) do
        {"spec/calc_spec.rb::Calc adds" => {file: "spec/calc_spec.rb", line: 2, lines: {"spec/calc_spec.rb" => [3]}},
         "spec/calc_spec.rb::Calc subtracts" => {file: "spec/calc_spec.rb", line: 7, lines: {"spec/calc_spec.rb" => [8]}}}
      end
      let(:loads) { {"spec/calc_spec.rb" => {lines: {"spec/calc_spec.rb" => [1, 2, 6, 7]}}} }

      it "charges a changed group to its own tests only" do
        document
        edit("spec/calc_spec.rb", "  it \"adds\" do\n", "  let(:x) { 1 }\n  it \"adds\" do\n")
        expect(selected.keys).to eq(["spec/calc_spec.rb::Calc adds"])
      end
    end

    context "with a group that holds no test, such as shared examples" do
      let(:spec) { "RSpec.describe Calc do\n  it \"adds\" do\n    1\n  end\nend\nshared_examples \"calc\" do\n  it \"works\" do\n  end\nend\n" }
      let(:tests) { {"spec/calc_spec.rb::Calc adds" => {file: "spec/calc_spec.rb", line: 2, lines: {"spec/calc_spec.rb" => [3]}}} }
      let(:loads) { {"spec/calc_spec.rb" => {lines: {"spec/calc_spec.rb" => [1, 2, 7]}}} }

      it "charges it to every test of the file" do
        document
        edit("spec/calc_spec.rb", "  it \"works\" do\n", "  it \"still works\" do\n")
        expect(selected.keys).to eq(["spec/calc_spec.rb::Calc adds"])
      end
    end

    it "charges nothing for a file whose lines the load holds without a hit" do
      tests.each_value { |test| test[:lines].delete("lib/calc.rb") }
      loads.fetch("spec/calc_spec.rb")[:lines]["lib/calc.rb"] = []
      document.dig("files", "lib/calc.rb").each_value { |version| version.fetch("lines")[6] = nil }
      edit("lib/calc.rb", "a - b", "a - b - 0")
      expect(selected).to be_empty
    end

    it "charges every test of the file when the unit it ran cannot be pinned down" do
      tests.each_value { |test| test[:lines].delete("lib/calc.rb") }
      loads.fetch("spec/calc_spec.rb")[:lines]["lib/calc.rb"] = [7]
      document.dig("files", "lib/calc.rb").each_value { |version| version.fetch("lines")[6] = nil }
      edit("lib/calc.rb", "a - b", "a - b - 0")
      expect(selected.values.uniq).to eq(["def lib/calc.rb"])
    end
  end

  describe "names local to a test file" do
    let(:spec) { "HELPER = 1\nRSpec.describe Calc do\n  it \"adds\" do\n    expect(HELPER).to eq(1)\n  end\nend\n" }
    let(:tests) { {"spec/calc_spec.rb::Calc adds" => {file: "spec/calc_spec.rb", line: 3, lines: {"spec/calc_spec.rb" => [4]}}} }

    it "selects the file's tests that reach the name" do
      document
      edit("spec/calc_spec.rb", "HELPER = 1", "HELPER = 2")
      expect(selected).to eq("spec/calc_spec.rb::Calc adds" => "name HELPER")
    end
  end

  describe "changes every test may see" do
    it "runs everything under another Ruby or lockfile" do
      document["env"] = "other"
      expect(selected).to eq(full: "env")
    end

    it "keeps to the tests when a file loaded before coverage started is as it was" do
      write_source("lib/early.rb", "1\n")
      document["unmeasured"] = {"lib/early.rb" => SimpleCov::Affected::Sidecar.file_digest(File.join(project_root, "lib/early.rb"))}
      expect(selected).to be_empty
    end

    it "keeps to the tests when code that ran before the first test file is as it was" do
      document["boot"]["lines"] = {"lib/calc.rb" => [source_digest(calc), "8"]}
      expect(selected).to be_empty
    end

    it "runs everything when a file loaded before coverage started changed" do
      write_source("lib/early.rb", "1\n")
      document["unmeasured"] = {"lib/early.rb" => "0"}
      expect(selected).to eq(full: "unmeasured lib/early.rb")
    end

    it "runs everything when code that ran before the first test file changed" do
      document["boot"]["lines"] = {"lib/calc.rb" => [source_digest(calc), "8"]}
      edit("lib/calc.rb", "a + b", "a + b + 0")
      expect(selected).to eq(full: "boot lib/calc.rb Calc#add")
    end

    it "ignores a one-line def's line in the boot lines, which is its definition" do
      document["boot"]["lines"] = {"lib/calc.rb" => [source_digest(calc), "200"]}
      edit("lib/calc.rb", "a / 2;", "a / 3;")
      expect(selected).not_to have_key(:full)
    end

    it "runs everything when a file that ran before the first test file is gone" do
      document["boot"]["lines"] = {"lib/calc.rb" => [source_digest(calc), "1"]}
      File.delete(File.join(project_root, "lib/calc.rb"))
      expect(selected).to eq(full: "deleted lib/calc.rb")
    end

    it "runs everything when such a file's change cannot be pinned down" do
      document["boot"]["lines"] = {"lib/calc.rb" => [source_digest(calc), "1"]}
      document.dig("files", "lib/calc.rb").each_value { |version| version.fetch("lines")[3] = nil }
      edit("lib/calc.rb", "a + b", "a + b + 0")
      expect(selected).to eq(full: "boot lib/calc.rb")
    end

    it "runs everything when a file no longer parses" do
      document
      edit("lib/calc.rb", "a + b", "a +")
      expect(selected).to eq(full: "unparsable lib/calc.rb")
    end

    it "runs everything where Prism cannot load" do
      allow(SimpleCov::StaticCoverageExtractor).to receive(:prism_loaded?).and_return(false)
      expect(selected).to eq(full: "no parser")
    end
  end
end
