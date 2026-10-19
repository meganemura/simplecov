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

  describe "rendering" do
    let(:recorder) { SimpleCov::Affected::Recorder.new("/proj", "/proj/coverage") }
    let(:subscribed) { [] }
    let(:notifications) do
      list = subscribed
      Module.new { define_singleton_method(:subscribe) { |pattern, &block| list << [pattern, block] } }
    end

    before do
      stub_const("ActiveSupport::Notifications", notifications)
      SimpleCov::Affected::Rails.instance_variable_set(:@notifications, nil)
    end

    after { SimpleCov::Affected::Rails.instance_variable_set(:@notifications, nil) }

    def render(name, identifier)
      subscribed.each { |pattern, block| block.call(name, 0, 1, "id", {identifier: identifier}) if pattern.match?(name) }
    end

    def render_in_test(name, identifier)
      recorder.test("t", file: nil, line: nil) { render(name, identifier) }
      recorder.tests.fetch("t").reads.to_a
    end

    it "counts each template a test renders as a read of it" do
      expect(render_in_test("render_template.action_view", "/proj/app/views/rooms/show.html.erb")).to eq(["app/views/rooms/show.html.erb"])
    end

    it "counts partials, layouts, and collections too" do
      reads = %w[partial layout collection].flat_map { |kind| render_in_test("render_#{kind}.action_view", "/proj/app/views/_#{kind}.html.erb") }

      expect(reads).to eq(%w[app/views/_partial.html.erb app/views/_layout.html.erb app/views/_collection.html.erb])
    end

    it "leaves out a renderable object, named by its class rather than a path" do
      expect(render_in_test("render_template.action_view", "RoomComponent")).to be_empty
    end

    it "subscribes once per process" do
      allow(notifications).to receive(:subscribe).and_call_original
      2.times { recorder.test("t", file: nil, line: nil) { true } }

      expect(notifications).to have_received(:subscribe).once
    end

    it "waits for ActiveSupport before it subscribes" do
      hide_const("ActiveSupport::Notifications")
      recorder.test("t", file: nil, line: nil) { true }

      expect(SimpleCov::Affected::Rails.instance_variable_get(:@notifications)).to be_nil
    end
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
