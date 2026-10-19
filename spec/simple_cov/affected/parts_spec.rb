# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::Parts do
  let(:root) { Dir.mktmpdir }
  let(:coverage_path) { File.join(root, "coverage") }

  before { File.write(File.join(root, "a_spec.rb"), "") }

  after { FileUtils.rm_rf(root) }

  def part(*ids)
    tests = ids.to_h { |id| [id, {"file" => "a_spec.rb", "reads" => [], "lines" => {}}] }
    {"version" => 1, "root" => root, "env" => "e", "files" => {}, "latest" => {}, "tests" => tests, "loads" => {},
     "boot" => {"lines" => {}, "reads" => []}, "reads" => {}, "unmeasured" => {}, "unloaded" => {}, "runs" => {}, "complete" => []}
  end

  def sidecar = SimpleCov::Affected::Sidecar.read(File.join(coverage_path, ".affected.json"))

  def finish = described_class.finish(coverage_path, "run 1", root, timeout: 600)

  it "keeps one directory per run, named safely" do
    expect(described_class.run_dir(coverage_path, "parallel-tests:/tmp/x")).to end_with(".affected-parts/parallel-tests__tmp_x")
  end

  it "folds every process's part into the sidecar" do
    described_class.write(coverage_path, "run 1", 11, part("a"))
    described_class.write(coverage_path, "run 1", 12, part("b"))
    finish

    expect(sidecar.fetch("tests").keys).to eq(%w[a b])
  end

  it "lays the run over the previous recording" do
    SimpleCov::Affected::Sidecar.write(File.join(coverage_path, ".affected.json"), part("old"))
    described_class.write(coverage_path, "run 1", 11, part("a"))
    finish

    expect(sidecar.fetch("tests").keys).to eq(%w[old a])
  end

  it "leaves the sidecar alone when no part was written" do
    expect([finish, sidecar]).to eq([nil, nil])
  end

  it "answers the run's own recording, its processes joined" do
    SimpleCov::Affected::Sidecar.write(File.join(coverage_path, ".affected.json"), part("old"))
    described_class.write(coverage_path, "run 1", 11, part("a"))
    described_class.write(coverage_path, "run 1", 12, part("b"))

    expect(finish.fetch("tests").keys).to eq(%w[a b])
  end

  it "leaves out another run's parts" do
    described_class.write(coverage_path, "run 2", 11, part("other"))
    described_class.write(coverage_path, "run 1", 12, part("a"))
    finish

    expect(sidecar.fetch("tests").keys).to eq(%w[a])
  end

  it "removes the run's parts once folded" do
    described_class.write(coverage_path, "run 1", 11, part("a"))
    finish

    expect(Dir.exist?(File.join(coverage_path, ".affected-parts"))).to be(false)
  end

  it "keeps a recent directory of another run, which may still be running" do
    described_class.write(coverage_path, "run 2", 11, part("other"))
    finish

    expect(Dir.exist?(described_class.run_dir(coverage_path, "run 2"))).to be(true)
  end

  it "clears a directory a crashed run left behind" do
    described_class.write(coverage_path, "run 2", 11, part("other"))
    File.utime(Time.now - 3600, Time.now - 3600, described_class.run_dir(coverage_path, "run 2"))
    finish

    expect(Dir.exist?(File.join(coverage_path, ".affected-parts"))).to be(false)
  end
end
