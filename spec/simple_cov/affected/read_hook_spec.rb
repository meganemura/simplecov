# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::ReadHook do
  include AffectedHelpers

  let(:file_api) do
    Class.new do
      %i[open read binread readlines foreach new].each do |name|
        define_singleton_method(name) { |path = nil, *args, **kwargs, &_block| [name, path, args, kwargs] }
      end
    end.tap { |api| api.singleton_class.prepend(described_class) }
  end

  def reads_of
    with_recorder("/proj") do |recorder|
      yield
      recorder.boot_reads.to_a
    end
  end

  it "records a file read through any of the File API's readers" do
    readers = %i[open read binread readlines foreach new]

    expect(reads_of { readers.each { |name| file_api.public_send(name, "/proj/#{name}.yml") } })
      .to eq(%w[open.yml read.yml binread.yml readlines.yml foreach.yml new.yml])
  end

  it "passes the call through unchanged" do
    expect(file_api.read("/proj/a.yml", 4, mode: "r")).to eq([:read, "/proj/a.yml", [4], {mode: "r"}])
  end

  it "records nothing for a file opened for writing" do
    expect(reads_of { file_api.open("/proj/a.yml", "w") }).to be_empty
  end

  it "records nothing for a file opened for appending through a keyword" do
    expect(reads_of { file_api.open("/proj/a.yml", mode: "a") }).to be_empty
  end

  it "records nothing for a file opened with write flags" do
    expect(reads_of { file_api.open("/proj/a.yml", File::WRONLY) }).to be_empty
  end

  it "records a file opened with read-only flags" do
    expect(reads_of { file_api.open("/proj/a.yml", File::RDONLY) }).to eq(["a.yml"])
  end

  it "records nothing for a descriptor rather than a path" do
    expect(reads_of { file_api.new(3) }).to be_empty
  end

  it "records nothing without a recorder" do
    expect(file_api.read("/proj/a.yml")).to eq([:read, "/proj/a.yml", [], {}])
  end
end
