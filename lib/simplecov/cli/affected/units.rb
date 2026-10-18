# frozen_string_literal: true

require_relative "../../static_coverage_extractor"

module SimpleCov
  module CLI
    module Affected
      # The units of one version of a Ruby source: every `def`, block, and lambda
      # whose body starts below its opening line, so that entering the unit runs a
      # line of its own that line coverage reports. A one-line or empty method
      # gives line coverage nothing to tell a call from the definition, so it is
      # no unit and stays in the text around it. Each unit keeps its text with the
      # units nested in it elided, and the file keeps its skeleton, the text
      # outside every unit, so a change lands on the innermost unit holding it or,
      # outside all of them, on the file.
      #
      # Texts are Prism's tokens rather than characters, with comments and line
      # breaks collapsed into one break, so comments, indentation, blank lines,
      # and position change nothing, while a token whose meaning depends on its
      # spacing (`foo -1` against `foo - 1`) lexes as a different type. Ids carry
      # no position either: the enclosing class or module, the method or call
      # name, and an occurrence count for repeats, so moving a unit keeps its id,
      # and moving it into another scope makes it another unit.
      #
      # Prism loads on the first outline, through the static extractor's probe,
      # not with the CLI: where it cannot load at all (JRuby on Windows), the
      # answer is nil like any other failure.
      module Units
        Unit = Struct.new(:id, :method, :parent, :last_line, :entry_line, :start_offset, :end_offset, :head, :body)
        Outline = Struct.new(:units, :skeleton)

        BREAKS = %i[NEWLINE IGNORED_NEWLINE COMMENT EMBDOC_BEGIN EMBDOC_LINE EMBDOC_END].freeze

        extend self

        # nil when Prism cannot load or the source does not parse, which callers
        # read as "judge the whole file".
        def outline(source)
          return nil unless StaticCoverageExtractor.prism_loaded?

          require_relative "units/collector"
          result = Prism.parse_lex(source)
          return nil if result.failure?

          program, tokens = result.value
          units = Collector.new.collect(program)
          skeleton = Text.new
          result.magic_comments.each { |comment| skeleton.add(:MAGIC, "#{comment.key}:#{comment.value}") }
          fill(units, tokens.map(&:first).sort_by { |token| token.location.start_offset }, skeleton)
          Outline.new(units.to_h { |unit| [unit.id, unit] }, skeleton.to_s)
        end

        private

        # Units arrive in source order with parents before children, so one pass
        # over the tokens keeps a stack of the open units: a token goes to the
        # innermost one, and a unit that opens leaves a marker in the text of
        # whatever encloses it.
        def fill(units, tokens, skeleton)
          heads = units.map { Text.new }
          bodies = units.map { Text.new }
          pending = 0
          open = [] #: Array[Integer]
          tokens.each do |token|
            location = token.location
            open.pop while open.last && location.start_offset >= units.fetch(open.fetch(-1)).end_offset
            while pending < units.size && units.fetch(pending).start_offset <= location.start_offset
              innermost(open, location.start_line, units, heads, bodies, skeleton).add(:UNIT, "")
              open.push(pending)
              pending += 1
            end
            text = innermost(open, location.start_line, units, heads, bodies, skeleton)
            text.add(token.type, token.value) unless token.type.equal?(:EOF)
          end
          units.each_with_index do |unit, index|
            unit.head = heads.fetch(index).to_s
            unit.body = bodies.fetch(index).to_s
          end
        end

        # A unit's head is everything above its entry line: the parameters, whose
        # defaults and arity run, or fail, before any line of the body reports.
        def innermost(open, line, units, heads, bodies, skeleton)
          return skeleton if open.empty?

          index = open.fetch(-1)
          (line < units.fetch(index).entry_line) ? heads.fetch(index) : bodies.fetch(index)
        end

        # One text being built: tokens as `TYPE value`, with each run of breaks
        # kept as a single line break between the tokens around it.
        class Text
          def initialize
            @parts = [] #: Array[String]
            @broken = false
          end

          def add(type, value)
            if BREAKS.include?(type)
              @broken = !@parts.empty?
            else
              @parts << "\n" if @broken
              @broken = false
              @parts << "#{type} #{value}"
            end
          end

          def to_s
            @parts.join(" ")
          end
        end
      end
    end
  end
end
