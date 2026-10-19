# frozen_string_literal: true

require "helper"
require "support/sandbox_project"

RSpec.describe "simplecov/affected/rails", :sandbox do
  def sidecar = JSON.parse(read_file("coverage/.affected.json"))

  def run_tests(mode = "all") = run_command_and_expect_success("bin/rails test", env: {"SIMPLECOV_AFFECTED" => mode}, timeout: 120)

  before do
    setup_project("rails/minitest_rails")
    write_file("test/test_helper.rb", <<~RUBY)
      require "simplecov"
      require "simplecov/affected/rails"
      SimpleCov.start "rails" do
        track_tests
      end

      ENV["RAILS_ENV"] ||= "test"
      require_relative "../config/environment"
      require "rails/test_help"
      I18n.load_path << Rails.root.join("lib/locales/extra.yml").to_s

      class ActiveSupport::TestCase
        parallelize workers: 2, threshold: 0, parallelize_databases: false
      end
    RUBY
    write_file("lib/locales/extra.yml", "en:\n  extra: Extra\n")
    write_file("test/models/order_test.rb", <<~RUBY)
      require "test_helper"

      class OrderTest < ActiveSupport::TestCase
        test("subtotal") { assert_equal 30, Order.new.subtotal(quantity: 3, unit_price: 10) }
      end
    RUBY
    write_file("test/models/receipt_test.rb", <<~RUBY)
      require "test_helper"

      class ReceiptTest < ActiveSupport::TestCase
        test("translates") { assert_equal "Extra", I18n.t("extra") }
      end
    RUBY
    install_dependencies
    run_tests
  end

  it "records the configuration as global files" do
    expect(sidecar.dig("global", "config/**/*")).to include("config/application.rb", "config/routes.rb")
  end

  it "records a locale file outside the configuration as global" do
    expect(sidecar.fetch("global")).to have_key("lib/locales/extra.yml")
  end

  it "runs every test when a global file changed" do
    write_file("config/routes.rb", "#{read_file("config/routes.rb")}\n# a new route\n")

    expect(run_tests("select").output).to include("running every test (global config/routes.rb)")
  end

  it "runs no recorded test when nothing changed" do
    expect(run_tests("select").output).to include("running 0 of 2 recorded tests")
  end
end
