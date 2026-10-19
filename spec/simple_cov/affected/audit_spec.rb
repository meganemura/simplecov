# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::Audit do
  let(:coverage_path) { Dir.mktmpdir }
  let(:plan) { SimpleCov::Affected::Plan.new(nil, {"a" => "def lib/a.rb 2", "b" => nil, "c" => nil}) }
  let(:run) { {"tests" => {"a" => {"ok" => true}, "b" => {"ok" => false}, "c" => {"ok" => true}, "d" => {"ok" => true}}} }

  after { FileUtils.rm_rf(coverage_path) }

  def written = JSON.parse(File.read(File.join(coverage_path, ".affected-audit.json")))

  def audit(plan, run) = expect { described_class.write(coverage_path, plan, run) }.to output.to_stderr

  it "writes which tests the selection would have run, and why" do
    audit(plan, run)

    expect(written).to include("full" => nil, "ran" => 4, "selected" => 2, "reasons" => {"a" => "def lib/a.rb 2", "d" => "new"})
  end

  it "writes which tests it would have skipped, and which of those failed" do
    audit(plan, run)

    expect(written).to include("skipped" => %w[b c], "skipped_failures" => %w[b])
  end

  it "says so on stderr" do
    expect { described_class.write(coverage_path, plan, run) }
      .to output("SimpleCov affected audit: the selection would have skipped 2 of 4 tests, and 1 of those failed\n").to_stderr
  end

  it "says when the selection would have run every test" do
    expect { described_class.write(coverage_path, SimpleCov::Affected::Plan.new("env", {}), run) }
      .to output("SimpleCov affected audit: the selection would have run every test (env)\n").to_stderr
  end

  it "writes an empty audit for a run that ran no test" do
    audit(plan, nil)

    expect(written).to include("ran" => 0, "skipped" => [])
  end
end
