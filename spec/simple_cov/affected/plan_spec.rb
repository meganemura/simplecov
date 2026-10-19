# frozen_string_literal: true

require "helper"
require "support/affected"
require "simplecov/affected/tree"
require "simplecov/affected/selection"

RSpec.describe SimpleCov::Affected::Plan do
  include AffectedProject

  let(:calc) { "class Calc\n  def add(a, b)\n    a + b\n  end\nend\n" }
  let(:coverage_path) { File.join(project_root, "coverage") }

  before do
    document = recording({"lib/calc.rb" => calc, "spec/calc_spec.rb" => "it 'adds' do\n  1\nend\n"},
      tests: {"spec/calc_spec.rb::adds" => {file: "spec/calc_spec.rb", lines: {"lib/calc.rb" => [3]}},
              "spec/calc_spec.rb::other" => {file: "spec/calc_spec.rb"}})
    SimpleCov::Affected::Sidecar.write(SimpleCov::Affected::Sidecar.path(coverage_path), document)
  end

  after { FileUtils.rm_rf(project_root) }

  def plan = described_class.load(project_root, coverage_path)

  it "runs a test a change reaches, for its reason" do
    write_source("lib/calc.rb", calc.sub("a + b", "b + a"))

    expect(plan.reason("spec/calc_spec.rb::adds")).to eq("def lib/calc.rb Calc#add")
  end

  it "leaves out a recorded test no change reaches" do
    expect(plan.reason("spec/calc_spec.rb::other")).to be_nil
  end

  it "runs a test the recording does not know" do
    expect(plan.reason("spec/calc_spec.rb::added")).to eq("new")
  end

  it "runs every test without a recording" do
    FileUtils.rm_rf(coverage_path)

    expect([plan.full, plan.reason("spec/calc_spec.rb::other")]).to eq(["no recording", "full"])
  end

  it "runs every test, and says why, when the selection fails" do
    allow(SimpleCov::Affected::Selection).to receive(:call).and_raise(KeyError, "tests")

    expect(plan.full).to eq("the selection failed: KeyError: tests")
  end

  it "sums up what it runs" do
    write_source("lib/calc.rb", calc.sub("a + b", "b + a"))

    expect(plan.summary).to eq("running 1 of 2 recorded tests, and any new ones")
  end

  it "sums up a full run with its reason" do
    expect(described_class.new("env", {}).summary).to eq("running every test (env)")
  end
end
