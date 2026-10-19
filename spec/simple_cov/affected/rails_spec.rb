# frozen_string_literal: true

require "helper"
require "support/affected"

RSpec.describe "SimpleCov::Affected::Rails" do
  # Requiring the layer registers Rails' globals in SimpleCov's own
  # configuration; they are taken back out after each example so the rest
  # of the suite sees SimpleCov's default.
  before do
    require "simplecov/affected/rails"
    SimpleCov::Affected::Rails.register
  end

  after { SimpleCov.affected_globals.replace(SimpleCov.affected_globals - SimpleCov::Affected::Rails::GLOBAL) }

  it "registers Rails' configuration, schema, fixtures, and locales as global" do
    SimpleCov.affected_globals.clear
    SimpleCov::Affected::Rails.register

    expect(SimpleCov.affected_globals).to include("config/**/*", "db/schema.rb", "db/migrate/**/*", "test/fixtures/**/*")
  end

  describe "the global files" do
    it "take in the locale files I18n loads from the project" do
      stub_const("I18n", Module.new { def self.load_path = [["/proj/lib/locales/ja.yml"], "/gems/rails/en.yml"] })
      allow(SimpleCov).to receive(:root).and_return("/proj")

      expect(SimpleCov::Affected.globals - SimpleCov.affected_globals).to eq(["lib/locales/ja.yml"])
    end

    it "are the configured ones alone before I18n loads" do
      hide_const("I18n")

      expect(SimpleCov::Affected.globals).to eq(SimpleCov.affected_globals)
    end
  end
end
