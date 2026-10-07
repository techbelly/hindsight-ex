#!/usr/bin/env ruby

require 'coverage'
require 'test/unit'
require 'test/unit/testresult.rb'
require 'test/unit/collector/descendant'

Test::Unit::AutoRunner.need_auto_run=false
Coverage.start

require './tests.rb'

def each_test_method(collector)
  tests = collector.collect
  tests.tests.each do |suite|
    suite.tests.each do |test|
      yield [suite, test]
    end
  end
end

def parse_opts
  [ARGV.shift, ARGV.map { |method| method.split("#") }]
end

output, tests_to_run = parse_opts
collector = Test::Unit::Collector::Descendant.new
suite = Test::Unit::TestSuite.new

each_test_method(collector) do |testcase, test|
  suite << test if tests_to_run.include?([testcase.name, test.method_name])
end

suite.run(Test::Unit::TestResult.new) { |a| }

if output == "tally"
  total_lines = Coverage.result.inject(0) do |i, (file, coverage)|
    file.start_with?(Dir.pwd) ? i + coverage.compact.inject(:+) : i
  end
  puts total_lines
else
  filtered_coverage = Coverage.result.select do |file, coverage|
    file.start_with?(Dir.pwd)
  end
  puts filtered_coverage.inspect
end
