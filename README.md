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

1. **record** runs the suite with a probe loaded via `RUBYOPT`. One whole run
   gives the load-time baseline and the require graph; then every test runs
   in its own process, in parallel, so its footprint is exactly the lines it
   needs, lazy initialisation included. (`--fast` records the whole suite in
   one process instead, attributing shared setup to whichever test ran first.)
   Output: `coverage.json`.
2. **order** picks the sequence greedily: at each step the test that needs the
   fewest new production lines goes next, the TDD instinct of taking the
   smallest step. An affinity penalty keeps the story in one test file and
   one area of the code until a test elsewhere is clearly cheaper.
   Output: `plan.json` and a Graphviz `graph.dot` of the choices.
3. **build** replays the plan into a fresh repository. For each step it slices
   every source file down to the lines the tests so far have needed, working
   on the AST but editing the original text line by line so comments and
   formatting survive. Conditionals lose the branches no test has entered;
   rescue clauses nobody triggered disappear; classes appear when first
   referenced; `require`s of files that don't exist yet are dropped.
   Attributes and constants appear when something uses them. Comments go.
   Output: `repo/`.
4. **verify** (optional, `--verify`) runs the suite at every step. After a
   green step every not-yet-added test is tried against the new code, and
   those that already pass are folded into the commit as further examples,
   so each commit changes production code. When verification
   fails, the builder escalates one rung at a time until it is green again:
   merge the recorded footprint of a folded test the new code has broken;
   re-record that single test in isolation (only useful after `--fast`);
   treat one class or constant as referenced, trying each the suspect files
   declare in turn; keep one file's classes as bare structure; keep one file
   whole. Each escalation is noted in the commit message and sticks.

Commit subjects are the test descriptions. Bodies say what the step did in
code terms (classes introduced, methods added or extended), list the tests
folded in, and record verification. Dates are spread across the original
project's lifetime in proportion to lines added. The first commit holds the
non-Ruby scaffolding; the last adds whatever no test ever reached.

`bin/hindsight-score REPO` measures a history: commits, commits adding no
code, step-size percentiles, hops between test files, escalations, and lines
left for the final commit. Every change to the slicer or orderer is judged
against those numbers on the exemplars below.

## Usage

```
bin/hindsight run    targets/slop --verify
bin/hindsight record targets/liquid --test-cmd 'ruby -Ilib -Itest -e ...'
bin/hindsight order  targets/liquid
bin/hindsight build  targets/liquid --verify --limit 50
```

Options: `--test-cmd` (defaults to a minitest glob or `bundle exec rspec`),
`--work DIR`, `--out DIR`, `--limit N`, `--fast` (one recording process). `bin/hindsight-debug TARGET N` builds up to step
N and runs the tests there, for poking at a failure.

Requires Ruby 3.3 or later and the `parser` gem (`bundle install`). The target
project's own test dependencies must be installed for its Ruby.

## Results so far

| project  | tests | lines | commits | median step | p90 | hops | escalations | time |
|----------|------:|------:|--------:|------------:|----:|-----:|------------:|-----:|
| slop     |   100 |  1.7k |      43 |           7 |  36 |    9 | 3 | 35 s |
| mustache |   112 |  1.9k |      49 |          12 |  55 |   12 | 2 | 45 s |
| sinatra  |   805 |  2.8k |     111 |           4 |  20 |   41 | 4 | 25 m |
| liquid   | 1,062 |  7.1k |     358 |           7 |  31 |  134 | 18 | 50 m |

Every commit in every history above passes the tests it contains. "Step"
is the production lines a commit adds; escalations are places the ladder
had to intervene. The first step of a project is its boot cost: requiring
liquid or sinatra executes hundreds of lines of class-level setup, which is
load-time structure and arrives together.

Sinatra's core tests run with
`bundle exec ruby -Ilib -Itest -e 'ARGV.each { |f| require File.expand_path(f) }' test/{base,...}_test.rb`
after `bundle config set --local path vendor/bundle && bundle install` in the
clone. Published histories: github.com/techbelly/{slop,mustache,sinatra,liquid}-hindsight.

Improving the prose further, for instance with a language model reading each
diff, is deliberately left as a separate pass over the finished history.

## Limits worth knowing

- Coverage sees what ran, not what was looked up by name. `const_defined?`,
  `method(:x)`, `send(:x)` are invisible, which is what the escalation ladder
  is for. Symbols passed to reflection calls in kept code are treated as
  references, which catches most of it.
- Comments are stripped from generated code. A synthetic history has no
  author whose remarks they would be, and comments about code that is not
  there yet mislead. Magic comments stay.
- Only whole lines are ever removed, so one-line constructs are kept or
  dropped as a unit.

## History

The `legacy/` directory holds the 2017 prototype this grew from: a greedy
orderer that re-ran the suite for every candidate, and a slicer that
regenerated code from the AST. The ideas are the same; everything else is new.
