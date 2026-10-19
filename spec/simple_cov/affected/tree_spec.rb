# frozen_string_literal: true

require "helper"
require "support/affected"
require "simplecov/affected/tree"
require "simplecov/affected/version"

RSpec.describe SimpleCov::Affected::Tree do
  include AffectedProject

  before do
    write_source("lib/a.rb", "A = 1\n")
    write_source("vendor/bundle/x.rb", "X = 1\n")
    write_source("coverage/y.rb", "Y = 1\n")
  end

  after { FileUtils.rm_rf(project_root) }

  it "reads a file's source" do
    expect(tree.text("lib/a.rb")).to eq("A = 1\n")
  end

  it "answers nil for a file that is gone" do
    expect([tree.text("lib/gone.rb"), tree.digest("lib/gone.rb"), tree.version("lib/gone.rb")]).to eq([nil, nil, nil])
  end

  it "digests a source the way the recording does" do
    expect(tree.digest("lib/a.rb")).to eq(source_digest("A = 1\n"))
  end

  it "digests a data file the way the recording does" do
    expect(tree.file_digest("lib/a.rb")).to eq(SimpleCov::Affected::Sidecar.file_digest(File.join(project_root, "lib/a.rb")))
  end

  it "reads a file's current version" do
    expect(tree.version("lib/a.rb").source).to eq("A = 1\n")
  end

  it "lists the project's Ruby files, without dependencies or the coverage output" do
    expect(tree.ruby_files).to eq(%w[lib/a.rb])
  end

  it "tells whether a file exists" do
    expect([tree.exist?("lib/a.rb"), tree.exist?("lib")]).to eq([true, false])
  end
end
