# frozen_string_literal: true

require "helper"
require "support/sandbox_project"

RSpec.describe "simplecov/affected/rails", :sandbox do
  def sidecar = JSON.parse(read_file("coverage/.affected.json"))

  def run_tests(mode = "all", workers: 2)
    run_command_and_expect_success("bin/rails test", env: {"SIMPLECOV_AFFECTED" => mode, "PARALLEL_WORKERS" => workers.to_s}, timeout: 120)
  end

  def edit(path, from, to) = write_file(path, read_file(path).sub(from, to))

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
    write_file("app/models/order.rb", <<~RUBY)
      class Order
        TITLE = "Orders"

        def subtotal(quantity:, unit_price:)
          quantity * unit_price
        end
      end
    RUBY
    write_file("app/views/orders/show.html.erb", "<h1><%= Order::TITLE %></h1>\n<%= render \"orders/line\", total: 3 %>\n")
    write_file("app/views/orders/_line.html.erb", "<p><%= total %></p>\n")
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
    write_file("test/views/orders_test.rb", <<~RUBY)
      require "test_helper"

      class OrdersTest < ActiveSupport::TestCase
        def page = ActionController::Base.render(template: "orders/show")

        test("shows the title") { assert_match(/<h1>[A-Z]/, page) }
        test("shows the total") { assert_match(/>3</, page) }
      end
    RUBY
    install_dependencies
  end

  context "with the tests spread over two workers" do
    before { run_tests }

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
      expect(run_tests("select").output).to include("running 0 of 4 recorded tests")
    end
  end

  context "with every test in one process" do
    before { run_tests(workers: 1) }

    it "gives every test that rendered a template a read of it, not only the first" do
      reads = %w[title total].map { |name| sidecar.dig("tests", "test/views/orders_test.rb::OrdersTest#test_shows_the_#{name}", "reads") }

      expect(reads).to all(include("app/views/orders/_line.html.erb", "app/views/orders/show.html.erb"))
    end

    it "runs the tests that render a changed partial" do
      edit("app/views/orders/_line.html.erb", "<p>", "<p class=\"total\">")

      expect(run_tests("select", workers: 1).output).to include("running 2 of 4 recorded tests")
    end

    it "runs the tests whose template mentions a changed constant" do
      edit("app/models/order.rb", '"Orders"', '"All orders"')

      run_tests("audit", workers: 1)

      expect(JSON.parse(read_file("coverage/.affected-audit.json")).fetch("reasons").compact.keys)
        .to contain_exactly("test/views/orders_test.rb::OrdersTest#test_shows_the_title", "test/views/orders_test.rb::OrdersTest#test_shows_the_total")
    end
  end
end
