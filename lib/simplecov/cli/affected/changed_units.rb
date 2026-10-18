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
      # A unit changed when its body did or it is gone, and a block or lambda that
      # is new charges the nearest recorded unit holding it. A test ran a unit
      # when it ran a line from the unit's entry line down, so a nested unit's
      # lines count for every unit around it. Anything that cannot be pinned to
      # units answers nil, which means the whole file, the rule before units: a
      # change outside every unit, a changed head, a method added or removed, a
      # block with no recorded unit around it, a unit whose entry line coverage
      # does not report, a unit that ran while no test was being recorded (code
      # run as files load, whose effects any test may read), and a source that is
      # missing, unrecorded, or does not parse.
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
          source.map { |line| "#{line}\n" }.join if source.instance_of?(Array) && source.all?(String)
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

          changed = kept.filter_map { |unit, now| unit unless now&.body.eql?(unit.body) }
          changed + added.map { |unit| recorded_ancestor(unit, before) }
        end

        # A new block always has a recorded unit around it once the skeletons
        # match: its call, and so its name, sits in the text that encloses it, so
        # a new block directly in the skeleton would have changed the skeleton.
        def recorded_ancestor(unit, before)
          unit = _ = unit.parent until before.units.key?(unit.id)
          before.units.fetch(unit.id)
        end

        def reached(charged, lines, table)
          covered = table.each_value.reduce(0, :|)
          picked = Set.new #: Set[Integer]
          charged.each do |unit|
            return nil unless traceable?(unit, lines, covered)

            span = ((1 << (unit.last_line - unit.entry_line + 1)) - 1) << (unit.entry_line - 1)
            table.each { |index, bitmap| picked << index if bitmap.anybits?(span) }
          end
          picked
        end

        # Every entry into a unit runs its entry line first, so a test that ran the
        # unit is on record for that line, provided coverage reports the line at
        # all and no hit on it came while no test was being recorded.
        def traceable?(unit, lines, covered)
          index = unit.entry_line - 1
          hits = lines[index]
          hits.is_a?(Integer) && (hits.zero? || covered[index].positive?)
        end
      end
    end
  end
end
