#!/usr/bin/env ruby
require './hindsight_slicer'
require 'unparser'
require 'parser/current'

test_order = ARGV
file_paths = []

out_dir = Dir.mktmpdir
`cd #{out_dir} && git init`

def slice_code(paths, out_dir)
  paths.each do |path|
    ruby_source = File.read(path)
    parse_tree = Parser::CurrentRuby.parse(ruby_source)
    slicer = yield path
    sliced = slicer.process(parse_tree)
    tmp_path = path.gsub Dir.pwd, out_dir
    `mkdir -p #{File.dirname(tmp_path)}`
    File.write(tmp_path, Unparser.unparse(sliced))
  end
end

def get_coverage(test_names)
  raw_coverage = `./hindsight_coverage.rb results #{test_names.join(" ")}`
  eval(raw_coverage)
end

def checkin(dir, message)
  `cd #{dir} && git add . && git commit -m\"#{message}\"`
end

def run_and_check_in(out_dir, tests, message)
  coverage = get_coverage(tests)
  slice_code(coverage.keys, out_dir) { |path|
    HindsightSlicer.new(coverage[path])
  }
  checkin(out_dir, message)
end

run_and_check_in(out_dir, [], "Initial check-in")

test_order.each_with_index do |test, i|
  run_and_check_in(out_dir, test_order.take(i+1), test)
end

coverage = get_coverage([])
slice_code(coverage.keys, out_dir) { |path|
  HindsightSlicer::Noop.new
}
checkin(out_dir, "Uncovered code")


`open #{out_dir}`
