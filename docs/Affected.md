# Affected tests: `require "simplecov/affected"`

`simplecov affected` on its own selects test files from a `track_tests` report (see [the CLI docs](CLI.md#affected--select-the-tests-that-touch-changed-code)).
`require "simplecov/affected"` adds what that report cannot hold, so a run can select single tests instead of files and
can trust its selection in more places:

```ruby
# spec/spec_helper.rb or test/test_helper.rb
require "simplecov"
require "simplecov/affected"
SimpleCov.start do
  track_tests
  affected :select # :select | :all | :audit | :off
end
```

Without the require, nothing on this page happens, and the `affected` setting is ignored.

## Modes

| Mode | What the run does |
| --- | --- |
| `:select` (default) | Records, and runs only the tests the last recording says the working tree can affect. Without a recording it runs everything. |
| `:all` | Records, and runs every test. |
| `:audit` | Records, runs every test, and writes down which tests the selection would have skipped and whether any of them failed. |
| `:off` | Plain SimpleCov. Nothing is recorded or selected. |

`SIMPLECOV_AFFECTED=<mode>` in the environment takes precedence over the configured mode, the same way
`SIMPLECOV_MERGE_TIMEOUT` takes precedence over `merge_timeout`, so a CI job can switch modes without touching the
helper. An unknown mode in either place is a configuration error rather than a silent fallback.

## What is recorded

Recording sits on top of `track_tests`: SimpleCov still peeks at the coverage counters once per test and never
clears them, so the report's totals are unaffected. Affected changes three things about the recording.

- **Stable test ids.** A context is named by the test, not by `file:line`, which changes for every test below an
  added line. An RSpec example is `spec/a_spec.rb::Group nested example description`, and an example without a
  description gets its position among its group's other undescribed examples (`spec/a_spec.rb::Group {2}`). A
  Minitest test is `test/a_test.rb::Class#test_name`, without the number minitest/spec puts in front of each `it`.
  `coverage.json`'s `contexts` carry these ids too.
- **Code outside the tests.** The code a test file runs while it loads (a class-level `property :x, coerce: Symbol`
  at the top of a spec), and the code of every example group's `before(:context)` and `after(:context)` hooks, are
  charged to the test file, which stands for all of its tests. Everything from the start of tracking to the first
  test file is charged to `(boot)`, which no test owns. RSpec's hooks are reached through its public configuration
  and the example groups' own `prepend_before` and `prepend_after`.
- **What `coverage.json` has no place for**: each test's outcome and time, the data files it read through the File
  API (YAML fixtures, templates, JSON), and the sources of the test files the default profiles filter out of the
  report, because an `it` block is code a change can touch too.

All of it goes to `coverage/.affected.json`, beside the report and independent of its format. One test's record is
one object:

```sh
$ jq '.tests["spec/calc_spec.rb::Calc adds"]' coverage/.affected.json
{
  "file": "spec/calc_spec.rb",
  "line": 12,
  "ok": true,
  "time": 0.000412,
  "must_run": false,
  "reads": ["spec/fixtures/numbers.yml"],
  "lines": {"lib/calc.rb": ["5d8f0c2a91b3e4f7", "f0"], "spec/calc_spec.rb": ["0b1c2d3e4f5a6b7c", "1800"]}
}
```

Each `lines` entry is the version of the file the test ran (a digest of its source) and a bitmap of the lines it ran,
in `coverage.json`'s encoding (bit N is line N+1). The other top-level keys are:

| Key | Holds |
| --- | --- |
| `files` | Each recorded version of each project Ruby file: its source lines and its line hits. |
| `latest` | The newest recorded version of each file. |
| `loads` | Per test file, the lines it ran and the data files it read while it loaded and in its context hooks. |
| `boot` | The same for everything before the first test file. |
| `reads` | A digest of every data file anything read. |
| `unmeasured` | Project files loaded before coverage started, with a digest: their lines are unknown. |
| `env` | A digest of the Ruby version, the platform, and the lockfile. |
