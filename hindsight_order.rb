#!/usr/bin/env ruby

require './tests.rb'
require 'test/unit/collector/descendant'

Test::Unit::AutoRunner.need_auto_run=false

def test_enumerator
  collector = Test::Unit::Collector::Descendant.new
  Enumerator.new do |enum|
    tests = collector.collect
    tests.tests.  each do |suite|
      suite.tests.each do |test|
        enum.yield "#{suite.name}##{test.method_name}"
      end
    end
  end
end

def tally_coverage(tests)
  results = `./hindsight_coverage.rb tally #{tests.join(" ")}`
end

ordered_tests = []
candidate_tests = test_enumerator.to_a

while !candidate_tests.empty?
  results = candidate_tests.map do |candidate|
    tests_to_run = ordered_tests + [candidate]
    lines_covered = tally_coverage(tests_to_run)
    [candidate, lines_covered]
  end
  smallest_candidate, lines_covered = results.min_by { |(_, lines)| lines.to_i }
  ordered_tests << smallest_candidate
  candidate_tests.delete(smallest_candidate)
end

puts ordered_tests.join(" ")
