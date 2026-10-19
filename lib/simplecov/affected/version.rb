# frozen_string_literal: true

require_relative "../cli/affected/units"
require_relative "../cli/affected/units/collector"
require_relative "statics"
require_relative "tokens"

module SimpleCov
  module Affected
    #
    # One version of one Ruby file, recorded or current, read three ways and
    # each only when asked: the units of `simplecov affected` (whose heads and
    # bodies tell what changed), the tokens each unit and each one-line def
    # mentions (what a test that ran them reaches), and the statics (the names
    # the file defines).
    #
    # A one-line def is no unit, because its call and its definition hit the
    # same line, but a test's own lines never hold a definition: the code that
    # runs while files load is charged to the load and boot contexts. So a hit
    # on a one-line def in a test's lines is a call, and the def is tracked
    # like a unit.
    #
    class Version
      Piece = Struct.new(:id, :name, :first_line, :last_line, :text, :tokens)

      attr_reader :path, :source

      def initialize(path, source)
        @path = path
        @source = source
      end

      def line_of(offset)
        (@source.byteslice(0, offset) || "").count("\n") + 1
      end

      # nil when the source does not parse.
      def outline
        return @outline if defined?(@outline)

        @outline = CLI::Affected::Units.outline(@source)
      end

      def statics
        return @statics if defined?(@statics)

        @statics = Statics.parse(@source, @path)
      end

      # Per unit id, the tokens of the unit's own code (the units nested in it
      # are their own; a one-line block or def is part of it) and the names
      # of the classes and modules around it.
      def reach
        pieces.first
      end

      # Per unit id, the bits of the lines that are the unit's own: from its
      # entry line down, less the units nested in it.
      def own_lines
        @own_lines ||= begin
          units = outline&.units || {} # simplecov:disable branch -- a version a test ran parsed as it loaded
          spans = units.transform_values { |unit| Version.mask(unit.entry_line, unit.last_line) }
          own = spans.dup
          units.each_value { |unit| (parent = unit.parent) && own[parent.id] &= ~spans.fetch(unit.id) }
          own
        end
      end

      def self.mask(first, last)
        ((1 << (last - first + 1)) - 1) << (first - 1)
      end

      # The one-line defs, by an id built the way unit ids are.
      def one_liners
        pieces.last
      end

      private

      def pieces
        @pieces ||= begin
          walker = Walker.new(@source)
          Prism.parse(@source).value.accept(walker)
          [walker.reach, walker.one_liners]
        end
      end

      # Layer 1's unit collector, keeping the node and scope behind each unit
      # so the ids match the outline's exactly.
      class Walker < CLI::Affected::Units::Collector
        UNIT = ->(node) { Statics.unit?(node) }

        attr_reader :reach, :one_liners

        def initialize(source)
          super()
          @lines = source.lines
          @reach = {} #: Hash[String, Set[String]]
          @one_liners = {} #: Hash[String, Piece]
          @seen_one_liners = Hash.new(0) #: Hash[String, Integer]
        end

        def visit_def_node(node)
          one_liner(node) unless node.equal_loc || node.body.nil? || Statics.unit?(node)
          super
        end

        private

        def add(node, label, entry)
          unit = super
          @reach[unit.id] = Tokens.of(node, stop: UNIT).merge(scopes)
          unit
        end

        def one_liner(node)
          base = "#{@stack.last&.id || @scope.join("::")}#{node.receiver ? "." : "#"}#{node.name}"
          count = (@seen_one_liners[base] += 1)
          id = (count > 1) ? "#{base}~#{count}" : base
          location = node.location
          @one_liners[id] = Piece.new(id, node.name.to_s, location.start_line, location.end_line,
            Tokens.digest(node.slice), Tokens.of(node, stop: UNIT).merge(scopes))
        end

        def scopes
          @scope.reject { |name| name.start_with?("<<") }.map { |name| name.split("::").last.to_s }
        end
      end
    end
  end
end
