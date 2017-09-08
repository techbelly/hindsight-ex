Hindsight
=========

Two main tools:

./hindsight_order.rb - uses greedy algo to work out a 'good' order in which to run the tests. Prints out a list of test names that can be fed into hindsight.rb.

./hindsight.rb [testnames] - create a fictional project history by running tests one after the other, checking in the code that's covered at each step. Creates a git repo in a temporary directory and opens it at the end

Other bits:

./hindsight_coverage.rb [tally|results] [testnames] - used by the other tools to run tests and get either total lines covered or a hash of coverage results

hindsight_slicer.rb - library code to mess around to tidy up the AST after we've deleted all the uncovered lines in it.
