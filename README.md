# Hindsight

Hindsight turns a finished, well-tested Ruby project into a fictional git
history that looks as if it had been written test by test. Every commit adds
one test and exactly the production code that test needed, so reading the log
front to back is a guided tour of what the project does and in what order it
could have been built.

The history is fictional but not fake: with `--verify` the tests present at
each commit are run against that commit's code, and the build only moves on
when they pass.

## How it works

Four stages, each leaving a file in `work/<project>/`:

1. **record** runs the suite once with a probe loaded via `RUBYOPT`. The probe
   snapshots Ruby's `Coverage` after every test, so each test gets its own
   runtime footprint, separate from the code that merely ran while files were
   loading. It also records which file required which.
   Output: `coverage.json`.
2. **order** picks the sequence greedily: at each step the test that needs the
   fewest new production lines goes next, the TDD instinct of taking the
   smallest step. Ties go to tests near the previous one in the same file.
   Output: `plan.json` and a Graphviz `graph.dot` of the choices.
3. **build** replays the plan into a fresh repository. For each step it slices
   every source file down to the lines the tests so far have needed, working
   on the AST but editing the original text line by line so comments and
   formatting survive. Conditionals lose the branches no test has entered;
   rescue clauses nobody triggered disappear; classes appear when first
   referenced; `require`s of files that don't exist yet are dropped.
   Output: `repo/`.
4. **verify** (optional, `--verify`) runs the suite at every step. When it
   fails, the builder escalates one rung at a time until it is green again:
   re-record that single test in isolation to pick up lazily initialised code
   another test paid for; keep one file's classes as bare structure; keep one
   file whole. Each escalation is noted in the commit message and sticks for
   later steps.

The first commit holds the non-Ruby scaffolding (gemspec, README, licence).
The last commit adds whatever no test ever reached.

## Usage

```
bin/hindsight run    targets/slop --verify
bin/hindsight record targets/liquid --test-cmd 'ruby -Ilib -Itest -e ...'
bin/hindsight order  targets/liquid
bin/hindsight build  targets/liquid --verify --limit 50
```

Options: `--test-cmd` (defaults to a minitest glob or `bundle exec rspec`),
`--work DIR`, `--out DIR`, `--limit N`, `--isolated` (record every test in its
own process; slow but exact). `bin/hindsight-debug TARGET N` builds up to step
N and runs the tests there, for poking at a failure.

Requires Ruby 3.3 or later and the `parser` gem (`bundle install`). The target
project's own test dependencies must be installed for its Ruby.

## Results so far

| project  | tests | lines | time with verify | escalations | left for the last commit |
|----------|------:|------:|-----------------:|-------------|-------------------------:|
| slop     |   100 |  1.7k |             12 s | 2, both dynamic constant lookups | 26 lines |
| mustache |   112 |  1.9k |             22 s | 3: two isolation re-records, one fixture as structure | 117 lines |
| liquid   | 1,062 |  7.1k |          8 m 14 s | 1 isolation re-record | 226 lines |

Every step of every history above is green. Liquid's first step is large
(about 1,300 lines) because its test helper builds the default Environment at
load, which drags in the tag and filter tables. That is honest: nothing less
boots.

Commit messages are the test descriptions. Improving them, for instance with
a language model reading each diff, is deliberately left as a separate pass
over the finished history.

## Limits worth knowing

- Coverage sees what ran, not what was looked up by name. `const_defined?`,
  `method(:x)`, `send(:x)` are invisible, which is what the escalation ladder
  is for. Symbols passed to reflection calls in kept code are treated as
  references, which catches most of it.
- Code that runs once and is memoised is attributed to whichever test ran
  first. Isolation re-recording fixes this where it bites; `--isolated` fixes
  it everywhere at the cost of one process per test.
- Only whole lines are ever removed, so one-line constructs are kept or
  dropped as a unit.

## History

The `legacy/` directory holds the 2017 prototype this grew from: a greedy
orderer that re-ran the suite for every candidate, and a slicer that
regenerated code from the AST. The ideas are the same; everything else is new.
