# frozen_string_literal: true

require "helper"
require "simplecov/cli"
require "support/affected"

RSpec.describe SimpleCov::CLI::Affected::Recorded do
  include AffectedProject

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:calc) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
  let(:input) { File.join(project_root, "coverage", "coverage.json") }

  before do
    document = recording({"lib/calc.rb" => calc, "spec/calc_spec.rb" => "it 'adds' do\n  1\nend\n", "spec/other_spec.rb" => ""},
      tests: {"spec/calc_spec.rb::adds" => {file: "spec/calc_spec.rb", lines: {"lib/calc.rb" => [3]}},
              "spec/other_spec.rb::other" => {file: "spec/other_spec.rb"}})
    SimpleCov::Affected::Sidecar.write(SimpleCov::Affected::Sidecar.path(File.dirname(input)), document)
    allow(SimpleCov::CLI::Affected::RUNNER).to receive(:call).and_return(0)
  end

  after { FileUtils.rm_rf(project_root) }

  def affected(*args) = SimpleCov::CLI.run(["affected", "--input", input, *args], stdout: stdout, stderr: stderr)

  def json = JSON.parse(stdout.string)

  def edit_calc = write_source("lib/calc.rb", calc.sub("a + b", "b + a"))

  it "names each selected test and why" do
    edit_calc
    affected("--json")

    expect(json).to eq("full" => nil, "tests" => {"spec/calc_spec.rb::adds" => "def lib/calc.rb Calc#add"},
      "files" => %w[spec/calc_spec.rb], "new_files" => [], "skipped" => 1)
  end

  it "prints the test files that hold a selected test" do
    edit_calc

    expect([affected, stdout.string]).to eq([0, "spec/calc_spec.rb\n"])
  end

  it "adds the test files the recording has never seen" do
    write_source("spec/added_spec.rb", "")
    affected

    expect(stdout.string).to eq("spec/added_spec.rb\n")
  end

  it "says when no recorded test is reached" do
    affected

    expect([stdout.string, stderr.string]).to eq(["", "simplecov affected: no recorded test touches the changed code\n"])
  end

  it "appends the files to the runner command" do
    edit_calc
    affected("--run", "rspec")

    expect(SimpleCov::CLI::Affected::RUNNER).to have_received(:call).with(%w[rspec spec/calc_spec.rb], project_root)
  end

  it "runs nothing when no recorded test is reached" do
    affected("--run", "rspec")

    expect(SimpleCov::CLI::Affected::RUNNER).not_to have_received(:call)
  end

  context "when every test has to run" do
    before { write_source("Gemfile.lock", "changed") }

    it "answers the reason alone" do
      affected("--json")

      expect(json).to eq("full" => "env")
    end

    it "prints no file, and says why on stderr" do
      affected

      expect([stdout.string, stderr.string]).to eq(["", "simplecov affected: running every test (env)\n"])
    end

    it "runs the bare runner command" do
      affected("--run", "rspec")

      expect(SimpleCov::CLI::Affected::RUNNER).to have_received(:call).with(%w[rspec], project_root)
    end

    it "prints nothing else and succeeds" do
      expect(affected).to eq(0)
    end
  end

  it "says that --base does not apply" do
    affected("--base", "main")

    expect(stderr.string).to start_with("simplecov affected: --base is ignored")
  end

  it "refuses a file that is not a recording" do
    File.write(SimpleCov::Affected::Sidecar.path(File.dirname(input)), "{}")

    expect([affected, stderr.string]).to match([1, /is not an affected recording/])
  end

  it "looks for the project in the working directory when the recorded root is gone" do
    document = SimpleCov::Affected::Sidecar.read(SimpleCov::Affected::Sidecar.path(File.dirname(input)))
    SimpleCov::Affected::Sidecar.write(SimpleCov::Affected::Sidecar.path(File.dirname(input)), document.merge("root" => "/gone"))
    edit_calc

    expect(Dir.chdir(project_root) { affected("--json") && json.fetch("files") }).to eq(%w[spec/calc_spec.rb])
  end
end
