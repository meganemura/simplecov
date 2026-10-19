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
- **Code that loads after boot.** A project file loaded later, by its absolute path (Zeitwerk's autoload inside a
  test, a test file's `require File.expand_path(...)`), runs its class body once per process, for whichever test
  comes first, though it serves every later test as much. Its first load is charged to `(boot)`, as if the file had
  loaded before the first test, and so are the data files it reads. A forked worker's setup before its first test
  (Rails' `parallelize` preparing its database) is charged to `(boot)` too, rather than to the test file the parent
  loaded last.
- **What `coverage.json` has no place for**: each test's outcome and time, the data files it read through the File
  API (YAML fixtures, templates, JSON), and the sources of the test files the default profiles filter out of the
  report, because an `it` block is code a change can touch too. Under `cover_views`, a template a context ran lines
  of is a read of that context too: eval coverage charges a compiled template's lines to the test that rendered it,
  even after the first render read the file and compiled it.

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
| `runs` | Per run id, the version of each file that run loaded: the tree its tests ran against. |
| `unloaded` | The project's other Ruby files, which no process loaded, with a digest. |
| `global` | Per glob of `affected_global`, every file it matched, with a digest. |
| `complete` | Only in a process's part (see below): the test files whose every test ran. |

## How the selection decides

The selection needs the recording and the working tree, nothing else: no git, and no base ref. Each recorded
version of a file is compared with the file as it is now, so the answer holds whatever the last run was.

Some changes reach every test, and then the whole suite runs, with the reason:

| Reason | When |
| --- | --- |
| `env` | The Ruby version, the platform, or the lockfile changed. |
| `global <path>` | A file under a glob of `affected_global` changed, appeared, or is gone. |
| `read <path>` | A data file read before the first test file (by a helper, say) changed. |
| `unmeasured <path>` | A project file loaded before coverage started changed. |
| `unparsable <path>` | A changed file no longer parses. |
| `boot <path> [<unit>]` | Code that ran before the first test file, or as a project file loaded after it, changed (an `RSpec.configure` block, a method a library calls as it loads, an autoloaded concern's `included` block). |
| `deleted <path>` | A file that ran before the first test file is gone. |
| `no parser` | Prism cannot load on this platform. |

Otherwise each recorded test gets the first reason that applies, cheapest first, or none:

| Reason | When |
| --- | --- |
| `new` | The test has no record yet (only a run in progress can tell). |
| `failed` | It failed last time. |
| `must_run` | It is marked to run every time. |
| `deleted <path>` | A file it ran is gone. |
| `def <path> <unit>`, `block <path> <unit>` | A unit it ran changed or is gone: a multi-line `def`, block, or lambda, or a one-line `def` it called. `def <path>` alone means the unit could not be pinned down (no line of it is one coverage reports), and every test that ran a line of the file is selected. |
| `read <path>` | A data file it read changed. |
| `name <name>` | A name it reaches was defined differently. |

A unit is what `simplecov affected` already compares (see [the CLI docs](CLI.md#affected--select-the-tests-that-touch-changed-code)).
The code a test file's load and context hooks ran counts for that file's tests: a unit of the test file itself
selects the tests written inside it (an example group's body selects its examples), and a unit of another file
selects every test of the file.

**Names** cover what runs once, as files load, so that no test's lines show it: constants, class and module headers,
macros (`attr_reader :name`, `validates :email`), `def name = value`, methods with an empty body, and requires.
Each is keyed by the name it defines, with a digest per key; a statement that defines no name (`include
Comparable`) is keyed by its class or module. A test reaches a name when code it ran mentions it, read off the syntax
tree: a unit's own code (the other examples of its `describe` are not), a one-line `def` it called, the classes and
modules around them, the files they are in (`path:lib/a.rb`), and the templates it read. A few rules keep the set
small:

- Only files the run loaded define names. A new file counts as loaded unless it sits in a test directory, and its
  names count only when no loaded file knew them, so reopening `module Rack` changes nothing.
- A name defined in a test file is local to that file's tests.
- A require counts only when it changes whether its target loads at all, so moving one changes nothing.
- A changed name spreads to every static that mentions it (`FACES = [*NUMBERS]`).
- `def name = value` and empty methods are also keyed by their class, and so is adding a method Ruby calls without
  the project spelling its name (`initialize`, `==`, `each`, `to_s`, `method_missing`, ...): a library may call them
  by a name no test mentions.
- Operators are not names here: nearly every test calls `==`.

## Partial runs, forked workers, and CI shards

A run that ran some of the tests says nothing about the rest, so the recording is never rewritten from one run
alone. Each process of a run (the main process, each forked worker, each parallel_tests worker) writes its own part
to `coverage/.affected-parts/<run id>/<pid>.json` when it collects its coverage, and the process that writes the final
report folds the run's parts into `coverage/.affected.json` under a lock:

- A test the run ran is recorded afresh. A test it did not run keeps its record, against the versions of the files it
  was recorded with; that is why `files` can hold several versions of one file, and a version is dropped once no
  record names it and it is not the latest.
- A test file whose every test ran drops the ids it no longer defines (a renamed or deleted test). A file narrowed by
  the selection, or a run filtered by the runner (`rspec -e`, a `:focus` filter, `--tag`, Minitest's `-n`, `-i`, or
  `-e`), drops nothing.
- A test that was not rerun and read a data file the run saw at another version is dropped, because no digest of
  the version it read is kept; dropped, it counts as new and is selected again.
- Tests whose test file is gone are dropped.
- A recording made under another Ruby or lockfile is replaced, not merged.

A part directory that a crashed run left behind is removed once it is older than `merge_timeout`. Forked workers
report only under `merge_subprocesses`, as for the coverage report itself.

CI shards each write their own `coverage/.affected.json`. Gather them and fold them into one with
`simplecov affected merge shard-*/coverage/.affected.json`, then keep the result where the next build finds it.

## Running only the affected tests

Under `:select` the run decides its plan once, as tracking starts and before any test file loads: it reads
`coverage/.affected.json`, compares it with the working tree as described above, and prints one line on stderr.

```
SimpleCov affected: running 3 of 412 recorded tests, and any new ones
SimpleCov affected: running every test (no recording)
```

RSpec then leaves the other examples out through an exclusion filter on the example's id, the way `--tag ~slow`
leaves examples out: a left-out example runs no hook of its own, and a group none of whose examples run runs no
`before(:context)`. Minitest leaves the other test methods out of each class's `runnable_methods`, after the seed has
shuffled them, so the order of the rest stays the order the seed gives. Both still load every test file. A test the
recording does not know (new, renamed, or dropped as stale) always runs, and so does every test when the plan is a
full run. A file with tests left out is narrowed, so the recording keeps the records of the tests it skipped.

Outside a run, `simplecov affected` reads the same recording and prints the same selection, per test with
`--json` (see [the CLI docs](CLI.md#affected--select-the-tests-that-touch-changed-code)).

Runner filters apply on top of the plan: `rspec spec/a_spec.rb` or `-n /parse/` narrows further, and the recording
treats the run as filtered.

## Auditing the selection

`:audit` (or `SIMPLECOV_AFFECTED=audit` in a CI job) decides the same plan but runs every test. Once the final
result exists it writes `coverage/.affected-audit.json` and prints a summary on stderr:

```json
{
  "full": null,
  "ran": 412,
  "selected": 3,
  "skipped": ["spec/a_spec.rb::A parses", "..."],
  "skipped_failures": [],
  "reasons": {"spec/calc_spec.rb::Calc adds": "def lib/calc.rb Calc#add", "...": "..."}
}
```

`skipped_failures` lists the tests the selection would have skipped that failed in this run. Any entry there is a
change the selection missed, so a job that audits before the team relies on `:select` checks exactly that. `full`
is the reason the selection would have run every test, if any (`env`, `no recording`, ...). A test this run ran that
the recording did not know is selected as `new`.

## Global files

Some files a process reads once and keeps: configuration, a schema, fixtures, locales. Whichever test needs one
first reads it, so only that test's record shows the read, though every later test depends on it. Name them as
globs against the project root, and a change to any file they match, a file added under them, or a file removed
reruns every test with the reason `global <path>`:

```ruby
SimpleCov.start do
  track_tests
  affected_global "spec/fixtures/**/*", "data/schema.json"
end
```

Each call adds to the list, which `SimpleCov.affected_globals` holds. Every file the globs match is recorded with a
digest when a run records, so the files need not have been read by any test.

## Rails: `require "simplecov/affected/rails"`

```ruby
# test/test_helper.rb or spec/rails_helper.rb, before the application loads
require "simplecov"
require "simplecov/affected/rails"
SimpleCov.start "rails" do
  track_tests
end
```

It loads `simplecov/affected` and adds what a Rails application keeps across tests, which per-test recording cannot
see. Nothing in it loads Rails; each rule looks at what is already defined when it is needed.

- **Global files.** `config/**/*`, the schema (`db/schema.rb`, `db/structure.sql`, and their per-database
  variants), migrations, seeds, and `test/fixtures/**/*` and `spec/fixtures/**/*` are added to `affected_global`,
  and so is every locale file of the project that `I18n.load_path` names at the end of the run (an engine's, a
  `lib/locales`). A process reads all of them once. To leave one out, remove it from `SimpleCov.affected_globals`
  inside `SimpleCov.start`.
- **Autoloading.** Zeitwerk loads a class inside whichever test uses it first. Like every project file loaded after
  boot, its class body is charged to `(boot)` (see [What is recorded](#what-is-recorded)), so the test is not
  credited with the definitions and a change to code that runs as the class loads reruns every test, as it would
  with `eager_load`.
- **Forked workers.** `parallelize` forks workers after the test files load. Each worker's setup before its first
  test is charged to `(boot)`, and its part is folded into the recording with the others.

