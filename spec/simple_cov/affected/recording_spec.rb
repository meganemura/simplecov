# frozen_string_literal: true

require "helper"
require "support/affected"
require "simplecov/affected/recording"

RSpec.describe SimpleCov::Affected::Recording do
  include AffectedProject

  subject(:subject_recording) { described_class.new(document) }

  let(:document) do
    recording({"lib/a.rb" => "require \"b\"\nA = B\n", "lib/b.rb" => "B = 1\n", "spec/a_spec.rb" => "X = A\n"},
      tests: {"spec/a_spec.rb::a" => {file: "spec/a_spec.rb"}}, unmeasured: {"lib/early.rb" => "d"})
  end

  after { FileUtils.rm_rf(project_root) }

  def index = subject_recording.index("run") { |_path, _kind, feature| "lib/#{feature}.rb" }

  it "answers nil for a version it does not hold" do
    expect(subject_recording.version("lib/a.rb", "nope")).to be_nil
  end

  it "rebuilds a recorded version's source" do
    expect(subject_recording.version("lib/b.rb", source_digest("B = 1\n")).source).to eq("B = 1\n")
  end

  it "answers no hits for a version it does not hold" do
    expect(subject_recording.hits("lib/a.rb", "nope")).to eq([])
  end

  it "falls back to the latest versions for a run it does not know" do
    expect(subject_recording.snapshot(nil)).to eq(document.fetch("latest"))
  end

  it "groups the tests by file" do
    expect([subject_recording.tests_of("spec/a_spec.rb").size, subject_recording.tests_of("spec/b_spec.rb")]).to eq([1, []])
  end

  it "tells the test directories" do
    expect([subject_recording.test_dir?("spec/support/x.rb"), subject_recording.test_dir?("lib/x.rb")]).to eq([true, false])
  end

  it "knows every file it saw" do
    expect(subject_recording.known).to include("lib/a.rb", "lib/early.rb")
  end

  it "indexes what the run's files define" do
    expect(index.known.fetch("B")).not_to be_empty
  end

  it "indexes what the run's files require" do
    expect(index.requires).to eq("lib/b.rb" => 1)
  end

  it "indexes who mentions a name, leaving test files out" do
    expect(index.uses.fetch("A")).to eq([%w[lib/a.rb A]])
  end

  it "skips a file it cannot parse" do
    document["files"]["lib/b.rb"] = {"z" => {"source" => ["B = ("], "lines" => []}}
    document["runs"]["run"]["lib/b.rb"] = "z"
    expect(index.known).not_to have_key("B")
  end
end
