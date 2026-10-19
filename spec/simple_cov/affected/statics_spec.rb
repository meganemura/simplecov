# frozen_string_literal: true

require "helper"
require "prism"
require "simplecov/affected/statics"

RSpec.describe SimpleCov::Affected::Statics do
  def statics(code) = described_class.parse(code, "lib/a.rb")

  def names(code) = statics(code).names

  # The keys whose digests differ between two versions of a source.
  def changed(before, after)
    old = names(before)
    now = names(after)
    (old.keys | now.keys).reject { |key| old[key].eql?(now[key]) }
  end

  it "keys a constant by its name" do
    expect(changed("LIMIT = 1\n", "LIMIT = 2\n")).to eq(%w[LIMIT])
  end

  it "keys a constant path by its last name" do
    expect(changed("A::LIMIT = 1\n", "A::LIMIT = 2\n")).to eq(%w[LIMIT])
  end

  it "keys an instance variable by its bare name" do
    expect(changed("@cache = {}\n", "@cache = []\n")).to eq(%w[cache])
  end

  it "keys a class by its header" do
    expect(changed("class Mash < Hash\nend\n", "class Mash < Object\nend\n")).to eq(%w[Mash])
  end

  it "keys a macro by each symbol it names" do
    expect(changed("class A\n  attr_reader :a, :b\nend\n", "class A\n  attr_reader :a, :b, frozen: true\nend\n")).to eq(%w[a b])
  end

  it "keys a macro that defines a method by that method's name" do
    expect(changed("class A\n  private def go = 1\nend\n", "class A\n  private def go = 2\nend\n")).to include("go")
  end

  it "keys a writer on self by its attribute" do
    expect(changed("self.limit = 1\n", "self.limit = 2\n")).to eq(%w[limit])
  end

  it "keys a call on a constant by the constant" do
    expect(changed("Config.setup(1)\n", "Config.setup(2)\n")).to eq(%w[Config])
  end

  it "keys a statement that defines nothing by the class around it" do
    expect(changed("class A\n  include Comparable\nend\n", "class A\n  include Enumerable\nend\n")).to eq(%w[A])
  end

  it "keys a module by its header and walks into it" do
    expect(changed("module M\n  X = 1\nend\n", "class M\n  X = 2\nend\n")).to contain_exactly("M", "X")
  end

  it "walks into a class body that rescues" do
    expect(changed("class A\n  X = 1\nrescue\nend\n", "class A\n  X = 2\nrescue\nend\n")).to eq(%w[X])
  end

  it "keys a macro that defines a multi-line method by a marker for its body" do
    expect(changed("class A\n  private def go\n    1\n  end\nend\n", "class A\n  private def go\n    2\n  end\nend\n")).to be_empty
  end

  it "keys a call without arguments by its scope" do
    expect(changed("class A\n  reset!\nend\n", "class A\n  clear!\nend\n")).to eq(%w[A])
  end

  it "keys a statement outside any class by the file" do
    expect(changed("puts 1\n", "puts 2\n")).to eq(%w[path:lib/a.rb])
  end

  it "keys an endless def by its name and its class" do
    expect(changed("class A\n  def go = 1\nend\n", "class A\n  def go = 2\nend\n")).to contain_exactly("go", "A")
  end

  it "keys an empty def by its name and its class, so a body written into it counts" do
    expect(changed("class A\n  def go\n  end\nend\n", "class A\n  def go\n    work\n  end\nend\n")).to include("go", "A")
  end

  it "keys the hook methods Ruby calls unasked by their class" do
    expect(changed("class A\nend\n", "class A\n  def ==(other)\n    true\n  end\nend\n")).to eq(%w[A])
  end

  it "keys an ordinary method by its presence alone" do
    expect(changed("class A\n  def go\n    1\n  end\nend\n", "class A\n  def go\n    2\n  end\nend\n")).to be_empty
  end

  it "notes a method that appears" do
    expect(changed("class A\nend\n", "class A\n  def go\n    1\n  end\nend\n")).to eq(%w[go])
  end

  it "leaves a block that is a unit to the units" do
    expect(changed("HANDLER = ->(x) do\n  x\nend\n", "HANDLER = ->(x) do\n  x + 1\nend\n")).to be_empty
  end

  it "keeps a one-line block in its static's text" do
    expect(changed("LIST = [1].map { |x| x }\n", "LIST = [1].map { |x| x + 1 }\n")).to eq(%w[LIST])
  end

  it "walks into a static's block, which is its scope" do
    expect(changed("Point = Struct.new(:x) do\n  LIMIT = 1\nend\n", "Point = Struct.new(:x) do\n  LIMIT = 2\nend\n")).to eq(%w[LIMIT])
  end

  it "walks both branches of a condition, and keys the condition" do
    expect(changed("if a\n  X = 1\nelsif b\n  Y = 1\nelse\n  Z = 1\nend\n", "if c\n  X = 2\nelsif b\n  Y = 2\nelse\n  Z = 2\nend\n"))
      .to contain_exactly("path:lib/a.rb", "X", "Y", "Z")
  end

  it "walks unless, begin, and singleton classes" do
    expect(changed("unless a\n  X = 1\nend\nbegin\n  Y = 1\nend\nclass << self\n  Z = 1\nend\n",
      "unless a\n  X = 2\nend\nbegin\n  Y = 2\nend\nclass << self\n  Z = 2\nend\n")).to eq(%w[X Y Z])
  end

  it "keys a begin with a rescue by its scope" do
    expect(changed("begin\n  X = 1\nend\n", "begin\n  X = 1\nrescue\nend\n")).to eq(%w[path:lib/a.rb])
  end

  it "ignores comments" do
    expect(changed("X = 1 # one\n", "X = 1 # uno\n")).to be_empty
  end

  it "lists requires apart from the names" do
    expect(statics("require \"a\"\nrequire_relative \"b\"\nrequire c\n").requires).to eq([%w[require a], %w[require_relative b]])
  end

  it "records what each static mentions" do
    expect(statics("FACES = [*NUMBERS]\n").mentions.fetch("FACES")).to include("NUMBERS")
  end

  it "records the superclass a class mentions" do
    expect(statics("class Mash < Hashie::Hash\nend\n").mentions.fetch("Mash")).to include("Hashie", "Hash")
  end

  it "answers nil for a source that does not parse" do
    expect(statics("def (")).to be_nil
  end

  it "tells a unit from a one-line def" do
    units = Prism.parse("def a\n  1\nend\ndef b; 1; end\n-> {}\n").value.statements.body
    expect(units.map { |node| described_class.unit?(node) }).to eq([true, false, false])
  end

  it "takes no def whose body holds only a rescue for a unit" do
    expect(described_class.unit?(Prism.parse("def a\nrescue\nend\n").value.statements.body.first)).to be(false)
  end
end
