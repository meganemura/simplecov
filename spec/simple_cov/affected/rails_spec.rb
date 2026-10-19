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

  describe "a ViewComponent's render" do
    include AffectedHelpers
    include AffectedProject

    before do
      stub_const("ViewComponent::Base", Class.new { def render_in(_view) = "html" })
      stub_const("AffectedSpecComponents", Module.new)
      %w[@components @sidecars].each { |name| SimpleCov::Affected::Rails.instance_variable_set(name, nil) }
      write_source("app/components/card_component.rb", <<~RUBY)
        module AffectedSpecComponents
          class CardComponent < ViewComponent::Base; end
          class WideCardComponent < CardComponent; end
        end
      RUBY
      write_source("app/components/card_component.html.erb", "<div></div>\n")
      write_source("app/components/card_component.yml", "en: {}\n")
      write_source("app/components/card_component/card_component.html+phone.erb", "<p></p>\n")
      write_source("app/components/cards_component.html.erb", "<ul></ul>\n")
      load File.join(project_root, "app/components/card_component.rb")
    end

    after { FileUtils.rm_rf(project_root) }

    def reads_of_render(component)
      with_recorder(project_root) do |recorder|
        SimpleCov::Affected::Rails.install(recorder)
        recorder.test("t", file: nil, line: nil) { component.new.render_in(nil) }
        recorder.tests.fetch("t").reads.sort
      end
    end

    it "reads the files beside the component's class" do
      expect(reads_of_render(AffectedSpecComponents::CardComponent)).to eq(%w[
        app/components/card_component.html.erb app/components/card_component.yml
        app/components/card_component/card_component.html+phone.erb
      ])
    end

    it "reads a superclass's files for a subclass without its own" do
      expect(reads_of_render(AffectedSpecComponents::WideCardComponent)).to include("app/components/card_component.html.erb")
    end

    it "still renders" do
      with_recorder(project_root) do |recorder|
        SimpleCov::Affected::Rails.install(recorder)

        expect(AffectedSpecComponents::CardComponent.new.render_in(nil)).to eq("html")
      end
    end

    it "renders without a recorder" do
      SimpleCov::Affected::Rails.install(SimpleCov::Affected::Recorder.new(project_root, project_root))

      expect(AffectedSpecComponents::CardComponent.new.render_in(nil)).to eq("html")
    end

    it "skips a component whose constant is gone" do
      stub_const("AffectedSpecComponents::Gone", Class.new(AffectedSpecComponents::CardComponent))
      gone = AffectedSpecComponents::Gone
      hide_const("AffectedSpecComponents::Gone")

      expect(reads_of_render(gone)).to include("app/components/card_component.yml")
    end

    it "skips an anonymous component" do
      expect(reads_of_render(Class.new(AffectedSpecComponents::CardComponent))).to include("app/components/card_component.yml")
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
