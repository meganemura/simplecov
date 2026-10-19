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
    # A process also compiles each template once, into a method, so only the
    # first test to render it reads the file. ActionView instruments every
    # render, so each render is a read of the template in the test that
    # rendered it, and the selection then reaches the names the template
    # mentions too.
    #
    # A ViewComponent compiles its sidecar template the same way, and its
    # render emits no ActionView event of its own, so each render of a
    # component is a read of the files beside its class's file
    # (`room_component.html.erb`, `room_component.yml`, the files in
    # `room_component/`), its superclasses' included, since a subclass
    # without a template renders its parent's.
    #
    module Rails
      RENDER = /\Arender_(?:template|partial|layout|collection)\.action_view\z/

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

      # Hooks in what is defined by the first test that finds it, once per
      # process: the application has booted by then.
      module Install
        def test(...)
          Rails.install(self)
          super
        end
      end

      module ComponentRender
        def render_in(...)
          Rails.rendered(self.class)
          super
        end
      end

      def self.install(recorder)
        if !@components && defined?(::ViewComponent::Base)
          ::ViewComponent::Base.prepend(ComponentRender)
          @components = true
        end
        return if @notifications || !defined?(::ActiveSupport::Notifications)

        @notifications = ::ActiveSupport::Notifications.subscribe(RENDER) do |*event|
          payload = event.last #: Hash[Symbol, untyped]
          identifier = payload[:identifier]
          recorder.read(identifier) if identifier.is_a?(String) && File.absolute_path?(identifier)
        end
      end

      def self.rendered(component)
        recorder = Affected.recorder or return
        sidecars = (@sidecars ||= {}) #: Hash[Class, Array[String]]
        sidecars.fetch(component) { sidecars[component] = sidecars(component) }.each { |path| recorder.read(path) }
      end

      def self.sidecars(component)
        component.ancestors.take_while { |klass| !klass.equal?(::ViewComponent::Base) }.grep(Class).flat_map do |klass|
          source = klass.name && Object.const_source_location(klass.name)&.first
          source ? beside(source) : []
        end.uniq
      end

      # The files named like `source` with another extension, and the files in
      # the directory named like it.
      def self.beside(source)
        dir = File.dirname(source)
        name = File.basename(source, ".rb")
        (Dir.glob("#{name}.*", base: dir) + Dir.glob("#{name}/**/*", base: dir))
          .map { |path| File.join(dir, path) }.select { |path| File.file?(path) && !path.eql?(source) }.sort
      end

      # Idempotent, so a project that names its own globals first keeps them.
      def self.register
        SimpleCov.affected_global(GLOBAL)
        Affected.singleton_class.prepend(Globals)
        Recorder.prepend(Install)
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
