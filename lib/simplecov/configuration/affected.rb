# frozen_string_literal: true

module SimpleCov
  module Configuration
    AFFECTED_MODES = %i[select all audit off].freeze

    #
    # What `require "simplecov/affected"` does in this run. `:select` runs only
    # the tests the last recording says a change can affect, `:all` runs every
    # test, `:audit` runs every test and writes down which ones the selection
    # would have skipped, and `:off` leaves the run to plain SimpleCov. Every
    # mode but `:off` records. Without that require the setting does nothing.
    #
    # SIMPLECOV_AFFECTED in the environment takes precedence over the
    # configured value, the way SIMPLECOV_MERGE_TIMEOUT does for
    # `merge_timeout`: a CI job or a one-off audit switches the mode without
    # editing the helper every run shares.
    #
    def affected(mode = nil)
      self.affected = mode unless mode.nil?
      env_affected || @affected || :select
    end

    def affected=(mode)
      @affected = affected_mode(mode, "affected")
    end

    # Files whose change reruns every test, as globs against the project
    # root: what a process reads once and keeps (configuration, the schema,
    # fixtures, locales), so that only whichever test came first would show
    # the read. Each call adds to the list.
    def affected_global(*globs)
      affected_globals.concat(globs.flatten.map(&:to_s)).uniq!
      affected_globals
    end

    def affected_globals
      @affected_globals ||= []
    end

    def env_affected
      value = ENV.fetch("SIMPLECOV_AFFECTED", nil)
      affected_mode(value, "SIMPLECOV_AFFECTED") unless value.nil? || value.empty?
    end

    private

    # A misspelt mode is refused rather than ignored: falling back to the
    # default would quietly select tests in a job that asked to run them all.
    def affected_mode(mode, source)
      found = AFFECTED_MODES.find { |known| known.to_s.eql?(mode.to_s.downcase) }
      return found if found

      raise ConfigurationError,
        "Unsupported #{source} mode #{mode.inspect}, supported values are #{AFFECTED_MODES.inspect}"
    end
  end
end
