# frozen_string_literal: true

require "helper"
require "prism"
require "simplecov/affected/tokens"

RSpec.describe SimpleCov::Affected::Tokens do
  def tokens(code, **) = described_class.of(Prism.parse(code).value, **)

  it "reads the names a piece of code calls, assigns, and defines" do
    expect(tokens("@limit = Hash.new.fetch(:size)\n$out = go")).to include("limit", "Hash", "new", "fetch", "size", "go", "out")
  end

  it "leaves local variables and parameters out, so they never pass for methods" do
    expect(tokens("->(query) { found = query }")).not_to include("query", "found")
  end

  it "reads the words of a string, which `send` can name a method by" do
    expect(tokens(%(send("query_all"), "\\xFF"))).to include("query_all")
  end

  it "names a setter by its attribute" do
    expect(tokens("self.limit = 1")).to include("limit")
  end

  it "keeps operators as they are" do
    expect(tokens("a == b")).to include("==")
  end

  it "keeps a nested def's name but not its body" do
    expect(tokens("class A\n  def outer\n    inner\n  end\nend\n")).to include("outer").and(satisfy { |found| !found.include?("inner") })
  end

  it "reads into the nested code it is not told to stop at" do
    expect(tokens("class A\n  def outer\n    inner\n  end\nend\n", stop: ->(_node) { false })).to include("inner")
  end

  it "digests code without its blank lines and indentation" do
    expect(described_class.digest("a\n\n    b\n")).to eq(described_class.digest("a\nb"))
  end
end
