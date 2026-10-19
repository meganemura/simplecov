# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::Merge do
  let(:root) { Dir.mktmpdir }

  before { FileUtils.mkdir_p(File.join(root, "spec")) && %w[a b].each { |name| File.write(File.join(root, "spec/#{name}_spec.rb"), "") } }

  after { FileUtils.rm_rf(root) }

  def version(digest, hits = [1]) = {digest => {"source" => ["x"], "lines" => hits}}

  def test(file = "spec/a_spec.rb", lines: {"lib/a.rb" => %w[v1 1]}, reads: [], ok: true)
    {"file" => file, "line" => 1, "ok" => ok, "time" => 0.1, "must_run" => false, "reads" => reads, "lines" => lines}
  end

  def recording(tests: {}, files: {"lib/a.rb" => version("v1")}, latest: {"lib/a.rb" => "v1"}, **rest)
    boot = {"lines" => {}, "reads" => []}
    {"version" => 1, "root" => root, "env" => "e", "files" => files, "latest" => latest, "tests" => tests,
     "loads" => {}, "boot" => boot, "reads" => {}, "unmeasured" => {}}.merge(rest.transform_keys(&:to_s))
  end

  describe ".combine" do
    it "joins the tests of every part" do
      joined = described_class.combine([recording(tests: {"a" => test}), recording(tests: {"b" => test("spec/b_spec.rb")})])

      expect(joined.fetch("tests").keys).to eq(%w[a b])
    end

    it "adds up the lines two parts saw of one test against the same source" do
      joined = described_class.combine([recording(tests: {"a" => test(lines: {"lib/a.rb" => %w[v1 1]})}),
        recording(tests: {"a" => test(lines: {"lib/a.rb" => %w[v1 4]})})])

      expect(joined.dig("tests", "a", "lines", "lib/a.rb")).to eq(%w[v1 5])
    end

    it "keeps the later lines where the source differs" do
      joined = described_class.combine([recording(tests: {"a" => test(lines: {"lib/a.rb" => %w[v1 1]})}),
        recording(tests: {"a" => test(lines: {"lib/a.rb" => %w[v2 4]})})])

      expect(joined.dig("tests", "a", "lines", "lib/a.rb")).to eq(%w[v2 4])
    end

    it "keeps every version of a file" do
      joined = described_class.combine([recording, recording(files: {"lib/a.rb" => version("v2")})])

      expect(joined.dig("files", "lib/a.rb").keys).to eq(%w[v1 v2])
    end

    it "joins the reads of a test" do
      joined = described_class.combine([recording(tests: {"a" => test(reads: ["x.yml"])}),
        recording(tests: {"a" => test(reads: ["w.yml"])})])

      expect(joined.dig("tests", "a", "reads")).to eq(%w[w.yml x.yml])
    end

    it "joins the files each part ran in full" do
      joined = described_class.combine([recording(complete: ["spec/b_spec.rb"]), recording(complete: ["spec/a_spec.rb"])])

      expect(joined.fetch("complete")).to eq(%w[spec/a_spec.rb spec/b_spec.rb])
    end
  end

  describe ".onto" do
    let(:previous) { recording(tests: {"a" => test(ok: false), "b" => test("spec/b_spec.rb")}) }

    it "keeps the previous tests a run did not run" do
      merged = described_class.onto(previous, recording(tests: {"a" => test}), root)

      expect(merged.fetch("tests").keys).to eq(%w[a b])
    end

    it "records a test the run ran afresh" do
      merged = described_class.onto(previous, recording(tests: {"a" => test}), root)

      expect(merged.dig("tests", "a", "ok")).to be(true)
    end

    it "drops the ids a test file the run ran in full no longer defines" do
      run = recording(tests: {"a2" => test}, complete: ["spec/a_spec.rb"])

      expect(described_class.onto(previous, run, root).fetch("tests").keys).to eq(%w[b a2])
    end

    it "drops a previous test that read a data file the run saw at another version" do
      stale = recording(tests: {"a" => test(reads: ["x.yml"]), "b" => test("spec/b_spec.rb")}, reads: {"x.yml" => "d1"})
      run = recording(reads: {"x.yml" => "d2"})

      expect(described_class.onto(stale, run, root).fetch("tests").keys).to eq(%w[b])
    end

    it "drops a load context that read such a data file" do
      stale = recording(loads: {"spec/a_spec.rb" => {"lines" => {}, "reads" => ["x.yml"]}}, reads: {"x.yml" => "d1"})

      expect(described_class.onto(stale, recording(reads: {"x.yml" => "d2"}), root).fetch("loads")).to be_empty
    end

    it "starts afresh from a recording made under another environment" do
      merged = described_class.onto(previous.merge("env" => "other"), recording, root)

      expect(merged.fetch("tests")).to be_empty
    end

    it "starts afresh without a previous recording" do
      expect(described_class.onto(nil, recording(tests: {"a" => test}), root).fetch("tests").keys).to eq(%w[a])
    end

    it "drops the tests of a test file that is gone" do
      File.delete(File.join(root, "spec/b_spec.rb"))

      expect(described_class.onto(previous, recording, root).fetch("tests").keys).to eq(%w[a])
    end

    it "drops the load context of a test file that is gone" do
      run = recording(loads: {"spec/gone_spec.rb" => {"lines" => {}, "reads" => []}})

      expect(described_class.onto(nil, run, root).fetch("loads")).to be_empty
    end

    it "keeps only the file versions some record names, and the latest" do
      run = recording(files: {"lib/a.rb" => version("v3"), "lib/b.rb" => version("w1")}, latest: {"lib/a.rb" => "v3"})
      merged = described_class.onto(previous.merge("files" => {"lib/a.rb" => version("v1").merge(version("v0"))}), run, root)

      expect(merged.fetch("files").transform_values(&:keys)).to eq("lib/a.rb" => %w[v1 v3])
    end

    it "does not keep the run's list of complete files" do
      expect(described_class.onto(nil, recording(complete: []), root)).not_to have_key("complete")
    end
  end
end
