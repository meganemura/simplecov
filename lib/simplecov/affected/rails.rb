# frozen_string_literal: true

require_relative "../affected"

module SimpleCov
  module Affected
    #
    # What a Rails application keeps across tests, which per-test recording
    # cannot see, loaded by `require "simplecov/affected/rails"` in place of
    # `require "simplecov/affected"`. Nothing here loads Rails: each rule
    # looks at what is already defined when it is needed.
    #
    # A process reads its configuration, its schema, its fixtures, and its
    # locales once, in whichever test needs them first, and keeps them. A
    # change to one can reach any test, so these files are global: a change
    # to one, a file added under them, or one removed reruns every test.
    #
    module Rails
      GLOBAL = %w[
        config/**/*
        db/schema.rb db/*_schema.rb db/structure.sql db/*_structure.sql
        db/migrate/**/* db/*_migrate/**/* db/seeds.rb db/seeds/**/*
        test/fixtures/**/* spec/fixtures/**/*
      ].freeze

      # Locale files outside `config/`, an engine's or a `lib/locales`, are
      # global too; I18n knows them once the application has booted.
      module Globals
        def globals
          super | Rails.locale_files(SimpleCov.root)
        end
      end

      # Idempotent, so a project that names its own globals first keeps them.
      def self.register
        SimpleCov.affected_global(GLOBAL)
        Affected.singleton_class.prepend(Globals)
      end

      def self.locale_files(root)
        return [] unless defined?(::I18n) && ::I18n.respond_to?(:load_path)

        prefix = File.join(root, "")
        ::I18n.load_path.flatten.map(&:to_s).select { |path| path.start_with?(prefix) }.map { |path| path.delete_prefix(prefix) }
      end
    end
  end
end

SimpleCov::Affected::Rails.register
