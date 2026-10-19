# frozen_string_literal: true

require "simplecov/affected"

# Requiring Affected prepends its lifecycle hooks into SimpleCov for the rest
# of this worker. They stay inert without a recorder, and `:off` keeps any
# other spec that starts test tracking from creating one, which would wire
# Affected into this very suite's RSpec configuration.
SimpleCov.affected(:off)

module AffectedHelpers
  # Runs the example with a live recorder, and puts the process back the way
  # it was afterwards.
  def with_recorder(root, coverage_path = File.join(root, "coverage"))
    recorder = SimpleCov::Affected::Recorder.new(root, coverage_path)
    SimpleCov::Affected.instance_variable_set(:@recorder, recorder)
    yield recorder
  ensure
    SimpleCov::Affected.instance_variable_set(:@recorder, nil)
  end
end

# A temporary project and a recording of it, built by hand so each example
# states exactly which lines each test ran.
module AffectedProject
  def project_root = (@project_root ||= Dir.mktmpdir)

  def write_source(path, text)
    full = File.join(project_root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  def source_digest(text) = SimpleCov::Affected::Sidecar.digest(text)

  # Every line that holds code reports a hit, as Coverage does for a file
  # that loaded and ran.
  def hits_of(text) = text.lines.map { |line| (line.strip.empty? || line.strip.eql?("end")) ? nil : 1 }

  # `sources` are the recorded versions, also written to disk; `tests` and
  # `loads` name the lines each ran per file.
  def recording(sources, tests: {}, loads: {}, boot: {}, **rest)
    sources.each { |path, text| write_source(path, text) }
    latest = sources.transform_values { |text| source_digest(text) }
    {"version" => 1, "root" => project_root, "env" => SimpleCov::Affected::Sidecar.env(project_root),
     "files" => sources.to_h { |path, text| [path, {latest.fetch(path) => {"source" => text.lines(chomp: true), "lines" => hits_of(text)}}] },
     "latest" => latest, "runs" => {"run" => latest},
     "tests" => tests.transform_values { |test| test_record(test, latest) },
     "loads" => loads.transform_values { |load| {"lines" => bitmaps(load.fetch(:lines, {}), latest), "reads" => load.fetch(:reads, []), "run" => "run"} },
     "boot" => {"lines" => bitmaps(boot.fetch(:lines, {}), latest), "reads" => boot.fetch(:reads, [])},
     "reads" => {}, "unmeasured" => {}, "unloaded" => {}, "global" => {}}.merge(rest.transform_keys(&:to_s))
  end

  def test_record(test, latest)
    {"file" => test.fetch(:file), "line" => test.fetch(:line, 1), "ok" => test.fetch(:ok, true), "time" => 0.1,
     "must_run" => test.fetch(:must_run, false), "reads" => test.fetch(:reads, []),
     "lines" => bitmaps(test.fetch(:lines, {}), latest), "run" => "run"}
  end

  def bitmaps(lines, latest)
    lines.to_h { |path, numbers| [path, [latest.fetch(path), numbers.sum { |number| 1 << (number - 1) }.to_s(16)]] }
  end

  def tree = SimpleCov::Affected::Tree.new(project_root, File.join(project_root, "coverage"))
end
