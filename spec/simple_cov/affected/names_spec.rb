# frozen_string_literal: true

require "helper"
require "support/affected"
require "simplecov/affected/tree"
require "simplecov/affected/recording"
require "simplecov/affected/names"

RSpec.describe SimpleCov::Affected::Names do
  include AffectedProject

  let(:sources) { {"lib/a.rb" => "require \"b\"\nNUMBERS = [1]\n", "lib/b.rb" => "FACES = [*NUMBERS]\n"} }
  let(:tests) { {"spec/a_spec.rb::a" => {file: "spec/a_spec.rb", lines: {}}} }
  let(:document) { recording(sources.merge("spec/a_spec.rb" => "HELPER = 1\nOTHER = HELPER\n"), tests: tests) }

  after { FileUtils.rm_rf(project_root) }

  def keys = described_class.new(SimpleCov::Affected::Recording.new(document), "run", tree).keys

  def edit(path, from, to) = write_source(path, File.read(File.join(project_root, path)).sub(from, to))

  it "finds nothing when nothing changed" do
    document
    expect(keys).to be_empty
  end

  it "spreads a changed name to the statics that mention it" do
    document
    edit("lib/a.rb", "[1]", "[2]")
    expect(keys).to eq("NUMBERS" => nil, "FACES" => nil)
  end

  it "keeps a name defined in a test file local to it, spread within the file" do
    document
    edit("spec/a_spec.rb", "HELPER = 1", "HELPER = 2")
    expect(keys).to eq("HELPER" => "spec/a_spec.rb", "OTHER" => "spec/a_spec.rb")
  end

  it "makes a name global once a non-test file changes it too" do
    sources["lib/c.rb"] = "HELPER = 1\n"
    document
    edit("spec/a_spec.rb", "HELPER = 1", "HELPER = 2") && edit("lib/c.rb", "HELPER = 1", "HELPER = 3")
    expect(keys).to include("HELPER" => nil)
  end

  it "counts a require that stops its target loading, and the names the target defined" do
    document
    edit("lib/a.rb", "require \"b\"\n", "")
    expect(keys).to eq("path:lib/b.rb" => nil, "FACES" => nil)
  end

  it "counts nothing for a require that moved" do
    sources["lib/c.rb"] = "C = 1\n"
    document
    edit("lib/a.rb", "require \"b\"\n", "") && edit("lib/c.rb", "C = 1\n", "require_relative \"b\"\nC = 1\n")
    expect(keys).to be_empty
  end

  it "keys a file whose requires of outside features changed by its path" do
    document
    edit("lib/a.rb", "require \"b\"\n", "require \"b\"\nload \"json\"\n")
    expect(keys).to eq("path:lib/a.rb" => nil)
  end

  it "counts the names of a new file that no loaded file knew" do
    document
    write_source("lib/fresh.rb", "FRESH = 1\nNUMBERS = [1]\n")
    expect(keys).to eq("FRESH" => nil)
  end

  it "counts nothing for a new file in a test directory" do
    document
    write_source("spec/support/helper.rb", "FRESH = 1\n")
    expect(keys).to be_empty
  end

  it "counts nothing for a file that was on disk, unloaded, all along" do
    write_source("bench/run.rb", "BENCH = 1\n")
    document["unloaded"] = {"bench/run.rb" => "x"}
    expect(keys).to be_empty
  end

  it "counts a changed one-line def as a changed name" do
    sources["lib/a.rb"] = "class A\n  def go; 1; end\nend\n"
    document
    edit("lib/a.rb", "1;", "2;")
    expect(keys).to eq("go" => nil)
  end

  context "with one name changed twice in one test file" do
    let(:document) { recording(sources.merge("spec/a_spec.rb" => "class A\n  def go; 1; end\nend\nclass B\n  def go; 1; end\nend\n"), tests: tests) }

    it "keeps the name local to the file" do
      document
      edit("spec/a_spec.rb", "1; end\nend\nclass B\n  def go; 1;", "2; end\nend\nclass B\n  def go; 2;")
      expect(keys).to eq("go" => "spec/a_spec.rb")
    end
  end

  it "counts a removed one-line def" do
    sources["lib/a.rb"] = "class A\n  def go; 1; end\nend\n"
    document
    edit("lib/a.rb", "  def go; 1; end\n", "")
    expect(keys).to include("go" => nil)
  end

  it "counts nothing for a dropped require of a file the run never loaded" do
    write_source("lib/optional.rb", "OPTIONAL = 1\n")
    sources["lib/a.rb"] = "begin\n  require \"optional\"\nend\n"
    document["unloaded"] = {"lib/optional.rb" => "x"}
    edit("lib/a.rb", "  require \"optional\"\n", "  nil\n")
    expect(keys).to eq("path:lib/a.rb" => nil)
  end

  it "names the first changed file that no longer parses" do
    document
    edit("lib/a.rb", "[1]", "[")
    expect(described_class.new(SimpleCov::Affected::Recording.new(document), "run", tree).unparsable).to eq("lib/a.rb")
  end

  describe "#resolve" do
    subject(:names) { document && described_class.new(SimpleCov::Affected::Recording.new(document), "run", tree) }

    it "resolves a relative require against the requiring file" do
      expect([names.resolve("lib/a.rb", "require_relative", "b"), names.resolve("lib/a.rb", "require_relative", "b.rb")]).to eq(%w[lib/b.rb lib/b.rb])
    end

    it "resolves a require against the usual load path roots" do
      expect(names.resolve("lib/x/y.rb", "require", "a.rb")).to eq("lib/a.rb")
    end

    it "names a feature outside the project as such" do
      expect([names.resolve("lib/a.rb", "require", "json"), names.resolve("lib/a.rb", "require_relative", "../x")])
        .to eq(%w[feature:json feature:../x])
    end
  end
end
