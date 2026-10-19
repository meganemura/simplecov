# frozen_string_literal: true

require "helper"
require "simplecov/affected/version"

RSpec.describe SimpleCov::Affected::Version do
  subject(:version) { described_class.new("lib/a.rb", source) }

  let(:source) do
    <<~RUBY
      class A
        class << self
          def build
            new.go
          end
        end
        def go; helper; end
        def go; other; end
        def stop = 1
      end
    RUBY
  end

  it "outlines the units" do
    expect(version.outline.units.keys).to eq(["A::<< self#build"])
  end

  it "reads the statics" do
    expect(version.statics.names).to have_key("A")
  end

  it "reads what each unit's own code reaches, with its scopes" do
    expect(version.reach.fetch("A::<< self#build")).to include("new", "go", "A")
  end

  it "lists the one-line defs, apart from endless ones" do
    expect(version.one_liners.keys).to eq(["A#go", "A#go~2"])
  end

  it "reads what a one-line def reaches" do
    expect(version.one_liners.fetch("A#go").tokens).to include("helper", "A")
  end

  it "keeps a one-line def's name and lines" do
    expect(version.one_liners.fetch("A#go~2").to_h.slice(:name, :first_line, :last_line)).to eq(name: "go", first_line: 8, last_line: 8)
  end

  it "names a one-line def inside a unit after the unit, and a singleton one by a dot" do
    expect(described_class.new("lib/b.rb", "Class.new do\n  def go; 1; end\n  def self.make; 1; end\nend\n").one_liners.keys).to eq(["/new#go", "/new.make"])
  end

  it "tells the line of an offset" do
    expect(version.line_of(source.index("def stop"))).to eq(9)
  end
end
