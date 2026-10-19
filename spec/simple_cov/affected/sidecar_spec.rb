# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::Sidecar do
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(dir) }

  it "lives beside the report" do
    expect(described_class.path("/proj/coverage")).to eq("/proj/coverage/.affected.json")
  end

  it "reads back what it wrote" do
    path = File.join(dir, ".affected.json")
    described_class.write(path, {"version" => 1, "tests" => {}})

    expect(described_class.read(path)).to eq({"version" => 1, "tests" => {}})
  end

  it "reads a missing file as nothing recorded" do
    expect(described_class.read(File.join(dir, "absent.json"))).to be_nil
  end

  it "reads a file that is not JSON as nothing recorded" do
    File.write(File.join(dir, "bad.json"), "{")

    expect(described_class.read(File.join(dir, "bad.json"))).to be_nil
  end

  it "reads a future version as nothing recorded" do
    File.write(File.join(dir, "next.json"), JSON.dump("version" => 2))

    expect(described_class.read(File.join(dir, "next.json"))).to be_nil
  end

  it "reads a document that is not an object as nothing recorded" do
    File.write(File.join(dir, "list.json"), "[]")

    expect(described_class.read(File.join(dir, "list.json"))).to be_nil
  end

  it "digests a missing file as nil" do
    expect(described_class.file_digest(File.join(dir, "absent"))).to be_nil
  end

  it "digests a file by its content" do
    File.write(File.join(dir, "a"), "same")

    expect(described_class.file_digest(File.join(dir, "a"))).to eq(described_class.digest("same"))
  end

  describe ".env" do
    it "changes with the lockfile" do
      before = described_class.env(dir)
      File.write(File.join(dir, "Gemfile.lock"), "GEM\n")

      expect(described_class.env(dir)).not_to eq(before)
    end

    it "stays put while nothing changes" do
      first = described_class.env(dir)

      expect(described_class.env(dir)).to eq(first)
    end
  end
end
