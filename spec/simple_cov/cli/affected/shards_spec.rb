# frozen_string_literal: true

require "helper"
require "simplecov/cli"
require "tmpdir"

RSpec.describe SimpleCov::CLI::Affected::Shards do
  let(:dir) { Dir.mktmpdir }
  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:output) { File.join(dir, "out.json") }

  after { FileUtils.rm_rf(dir) }

  def shard(name, *ids, env: "e")
    tests = ids.to_h { |id| [id, {"file" => "a_spec.rb", "reads" => [], "lines" => {}}] }
    path = File.join(dir, "#{name}.json")
    File.write(path, JSON.generate("version" => 1, "root" => dir, "env" => env, "files" => {}, "latest" => {},
      "tests" => tests, "loads" => {}, "boot" => {"lines" => {}, "reads" => []}, "reads" => {}, "unmeasured" => {}, "unloaded" => {}, "runs" => {},
      "complete" => ["a_spec.rb"]))
    path
  end

  def merge(*args) = SimpleCov::CLI.run(["affected", "merge", *args], stdout: stdout, stderr: stderr)

  it "joins the shards' tests into one recording" do
    merge(shard("one", "a"), shard("two", "b"), "--output", output)

    expect(JSON.parse(File.read(output)).fetch("tests").keys).to eq(%w[a b])
  end

  it "does not keep a shard's list of complete files" do
    merge(shard("one", "a"), "--output", output)

    expect(JSON.parse(File.read(output))).not_to have_key("complete")
  end

  it "says where it wrote" do
    merge(shard("one", "a"), "--output", output)

    expect(stdout.string).to eq("simplecov affected merge: wrote #{output}\n")
  end

  it "says nothing with --quiet" do
    merge(shard("one", "a"), "--output", output, "--quiet")

    expect(stdout.string).to be_empty
  end

  it "writes beside the report by default" do
    allow(SimpleCov::CLI).to receive(:coverage_dir).and_return(dir)
    merge(shard("one", "a"))

    expect(File.exist?(File.join(dir, ".affected.json"))).to be(true)
  end

  it "refuses to run without inputs" do
    expect([merge, stderr.string]).to eq([1, "simplecov affected merge: missing input files\n"])
  end

  it "refuses an input that is not a recording" do
    File.write(output, "{}")

    expect([merge(output), stderr.string]).to match([1, /out\.json is not an affected recording/])
  end

  it "refuses shards recorded under different environments" do
    expect(merge(shard("one", "a"), shard("two", "b", env: "f"))).to eq(1)
  end
end
