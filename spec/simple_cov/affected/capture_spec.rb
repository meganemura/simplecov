# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::Capture do
  let(:root) { Dir.mktmpdir }
  let(:recorder) { SimpleCov::Affected::Recorder.new(root, File.join(root, "coverage")) }
  let(:map) { SimpleCov::ContextMap.new }
  let(:result) do
    coverage = {lib => {lines: [1, 2, nil]}, spec => {"lines" => [1, 1]}}
    Struct.new(:contexts, :original_result).new(map, coverage)
  end
  let(:document) { described_class.call(recorder, result, root, run: "run-1") }

  def lib = File.join(root, "lib/calc.rb")

  def spec = File.join(root, "spec/calc_spec.rb")

  def coverage = result.original_result

  def digest_of(path) = SimpleCov::Affected::Sidecar.digest(File.read(path))

  before do
    allow(SimpleCov).to receive(:track_test).and_yield
    {lib => "class Calc\n  def add = 1\nend\n", spec => "it 'adds' do\nend\n"}.each do |path, text|
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, text)
    end
    File.write(File.join(root, "table.yml"), "a: 1\n")
    recorder.loading(spec) { recorder.read(File.join(root, "table.yml")) }
    recorder.test("spec/calc_spec.rb::adds", file: "spec/calc_spec.rb", line: 1) { true }
    map.record("spec/calc_spec.rb::adds", lib => 0b10)
    map.record("spec/calc_spec.rb", spec => 0b1)
    map.record("hand-written", lib => 0b1)
    map.record("(boot)", lib => 0b100)
  end

  after { FileUtils.rm_rf(root) }

  it "keeps the source and hits of every project Ruby file, the test files included" do
    expect(document.fetch("files").fetch("spec/calc_spec.rb"))
      .to eq(digest_of(spec) => {"source" => ["it 'adds' do", "end"], "lines" => [1, 1]})
  end

  it "reads the hits Coverage keys by symbol" do
    expect(document.dig("files", "lib/calc.rb", digest_of(lib), "lines")).to eq([1, 2, nil])
  end

  it "keeps the version of each file the run loaded" do
    expect(document.fetch("runs")).to eq("run-1" => document.fetch("latest"))
  end

  it "lists the project's Ruby files the process never loaded" do
    File.write(File.join(root, "bench.rb"), "1\n")

    expect(document.fetch("unloaded")).to eq("bench.rb" => digest_of(File.join(root, "bench.rb")))
  end

  it "names each file's version" do
    expect(document.fetch("latest")).to eq("lib/calc.rb" => digest_of(lib), "spec/calc_spec.rb" => digest_of(spec))
  end

  it "keeps one test's record in one object" do
    expect(document.fetch("tests").fetch("spec/calc_spec.rb::adds")).to include(
      "file" => "spec/calc_spec.rb", "line" => 1, "ok" => true, "must_run" => false, "reads" => [],
      "lines" => {"lib/calc.rb" => [digest_of(lib), "2"]}, "run" => "run-1"
    )
  end

  it "keeps what a test file ran and read as it loaded" do
    expect(document.fetch("loads")).to eq(
      "spec/calc_spec.rb" => {"lines" => {"spec/calc_spec.rb" => [digest_of(spec), "1"]}, "reads" => ["table.yml"], "run" => "run-1"}
    )
  end

  it "folds contexts no test owns into boot" do
    expect(document.fetch("boot")).to eq("lines" => {"lib/calc.rb" => [digest_of(lib), "5"]}, "reads" => [])
  end

  it "digests every data file read" do
    expect(document.fetch("reads")).to eq("table.yml" => digest_of(File.join(root, "table.yml")))
  end

  it "names the test files whose tests all ran" do
    expect(document.fetch("complete")).to eq(%w[spec/calc_spec.rb])
  end

  it "records the environment" do
    expect(document.fetch("env")).to eq(SimpleCov::Affected::Sidecar.env(root))
  end

  it "skips files outside the project, files that are not Ruby, and files gone since" do
    %w[/elsewhere/gem.rb app/view.erb lib/gone.rb].each { |path| coverage[File.expand_path(path, root)] = {"lines" => [1]} }
    map.record("spec/calc_spec.rb::adds", File.join(root, "lib/gone.rb") => 1)

    expect(document.fetch("files").keys).to contain_exactly("lib/calc.rb", "spec/calc_spec.rb")
  end

  it "lists project files loaded before coverage started" do
    early = File.join(root, "lib/early.rb")
    File.write(early, "1\n")
    loaded = [early, "thread.rb", lib, "/elsewhere/x.rb", File.join(root, "data.so")]

    expect(described_class.call(recorder, result, root, run: "run-1", loaded_features: loaded).fetch("unmeasured"))
      .to eq("lib/early.rb" => digest_of(early))
  end

  it "records nothing for a process whose map was dropped" do
    result.contexts = nil

    expect(document).to be_nil
  end
end
