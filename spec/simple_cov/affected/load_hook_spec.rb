# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe SimpleCov::Affected::LoadHook do
  include AffectedHelpers

  let(:kernel) do
    Module.new do
      private

      def load(file, *) = [:load, file]

      def require(feature) = [:require, feature]
    end
  end
  let(:host) do
    described_class.install(kernel)
    mod = kernel
    Class.new { include mod }.new
  end

  before { allow(SimpleCov).to receive(:track_test).and_yield }

  it "charges a loaded spec file to itself" do
    with_recorder("/proj") { host.send(:load, "/proj/spec/a_spec.rb") }

    expect(SimpleCov).to have_received(:track_test).with("spec/a_spec.rb")
  end

  it "charges a required test file to itself" do
    with_recorder("/proj") { host.send(:require, "/proj/test/a_test.rb") }

    expect(SimpleCov).to have_received(:track_test).with("test/a_test.rb")
  end

  it "answers what the load answers" do
    expect(with_recorder("/proj") { host.send(:load, "/proj/spec/a_spec.rb", true) })
      .to eq([:load, "/proj/spec/a_spec.rb"])
  end

  it "passes loads straight through without a recorder" do
    expect([host.send(:load, "a.rb"), host.send(:require, "b")]).to eq([[:load, "a.rb"], [:require, "b"]])
  end

  it "installs once" do
    2.times { described_class.install(kernel) }
    mod = kernel

    expect(Class.new { include mod }.new.send(:require, "b")).to eq([:require, "b"])
  end

  # Zeitwerk aliases `require` as it loads and handles a namespace directory
  # itself, passing the rest to what it aliased.
  def wrap_like_zeitwerk
    kernel.module_eval do
      alias_method :zeitwerk_original_require, :require
      define_method(:require) { |feature| feature.end_with?("/namespace") ? :autovivified : zeitwerk_original_require(feature) }
    end
  end

  it "stays in the chain when a library wraps require after it" do
    host && wrap_like_zeitwerk

    expect(with_recorder("/proj") { [host.send(:require, "/gems/x/namespace"), host.send(:require, "/proj/test/a_test.rb")] })
      .to eq([:autovivified, [:require, "/proj/test/a_test.rb"]])
  end
end
