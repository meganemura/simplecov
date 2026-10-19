# frozen_string_literal: true

module SimpleCov
  module CLI
    module Affected
      # Narrows a changed file's recorded tests to the ones that ran a changed
      # unit. The recording is the report itself: coverage.json carries each
      # file's source as it was recorded, its per-line hit counts, and per test
      # the lines it ran, so the units the tests ran are derived here rather than
      # stored, and a report without the source still selects as before.
      #
      # A unit changed when its body did or it is gone. A block or lambda that is
      # new changes the body of the unit around it, so that unit is charged. A
      # test ran a unit when it ran a line from the unit's entry line down, so a
      # nested unit's lines count for every unit around it. Anything that cannot
      # be pinned to units answers nil, which means the whole file, the rule
      # before units: a change outside every unit, a changed head, a method added
      # or removed, a unit none of whose lines coverage reports, a unit that ran
      # while no test was being recorded (code run as files load, whose
      # effects any test may read), and a source that is missing, unrecorded, or
      # does not parse.
      module ChangedUnits
        extend self

        def contexts(entry, table, current)
          lines = entry["lines"]
          recorded = recorded_source(entry["source"])
          return nil unless recorded && current && lines.instance_of?(Array)

          before = Units.outline(recorded)
          after = Units.outline(current)
          return nil unless before && after && before.skeleton.eql?(after.skeleton)

          charged = charged_units(before, after)
          charged && reached(charged, lines, table)
        end

        private

        # Lines are stored chomped, and joined back with the newline each one lost.
        def recorded_source(source)
          source.map { |line| "#{line}\n" }.join if source.instance_of?(Array)
        end

        # nil when the change reaches past the units: a head that changed (the
        # parameters run before the entry line reports, so a call that failed in
        # them never reached the unit) or a method that appeared or vanished, which
        # changes what every caller of that name gets, recorded or not.
        def charged_units(before, after)
          kept = before.units.each_value.map { |unit| [unit, after.units[unit.id]] } #: Array[[Units::Unit, Units::Unit?]]
          return nil if kept.any? { |unit, now| now ? !now.head.eql?(unit.head) : unit.method }

          added = after.units.each_value.reject { |unit| before.units.key?(unit.id) }
          return nil if added.any?(&:method)

          # A new block needs no charge of its own: its marker and its call sit in
          # the text around it, so the recorded unit holding it changed too.
          kept.filter_map { |unit, now| unit unless now&.body.eql?(unit.body) }
        end

        def reached(charged, lines, table)
          covered = table.each_value.reduce(0, :|)
          picked = Set.new #: Set[Integer]
          charged.each do |unit|
            span = ((1 << (unit.last_line - unit.entry_line + 1)) - 1) << (unit.entry_line - 1)
            return nil unless traceable?(lines[(unit.entry_line - 1)...unit.last_line].to_a, covered.anybits?(span))

            table.each { |index, bitmap| picked << index if bitmap.anybits?(span) }
          end
          picked
        end

        # Every entry into a unit runs a line inside its span, though not always
        # its entry line: `begin ... end if ready` reports the predicate's line,
        # and a body that opens with a multi-line array literal reports its first
        # element. So a test that ran the unit is on record for some line of it,
        # provided coverage reports any of its lines, and a unit that ran with no
        # test on record for it ran while no test was being recorded.
        def traceable?(hits, recorded)
          hits.any?(Integer) && (recorded || hits.none? { |count| count.is_a?(Integer) && count.positive? })
        end
      end
    end
  end
end
