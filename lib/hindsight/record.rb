# frozen_string_literal: true

require "json"
require "set"

module Hindsight
  # One test's runtime footprint: which lines of which files it executed.
  TestRun = Struct.new(:id, :description, :file, :line, :passed, :lines, keyword_init: true) do
    def production_lines(project)
      lines.reject { |file, _| project.test_file?(file) }
    end

    def to_data
      { "id" => id, "description" => description, "file" => file, "line" => line, "passed" => passed,
        "coverage" => lines.transform_values { |ls| { "lines" => ls.to_h { |l| [l.to_s, 1] }, "branches" => {} } } }
    end
  end

  # The output of the probe, loaded.
  class Record
    attr_reader :root, :ruby_version, :baseline, :baseline_counts, :tests, :require_edges

    def self.load(path)
      new(JSON.parse(File.read(path)))
    end

    def initialize(data)
      @data = data
      @root = data["root"]
      @ruby_version = data["ruby"]
      @baseline = data["baseline"].transform_values { |c| c["lines"].keys.map(&:to_i).to_set }
      # How often each line ran at load: a one-line method whose line ran
      # more than once was called, not just defined.
      @baseline_counts = data["baseline"].transform_values { |c| c["lines"].to_h { |l, n| [l.to_i, n] } }
      # [from_file, method, argument] as recorded; resolved by the builder.
      @require_edges = (data["requires"] || []).map { |from, m, arg| [from, m.to_sym, arg] }
      @tests = data["tests"].map do |t|
        TestRun.new(
          id: t["id"], description: t["description"], file: t["file"], line: t["line"],
          passed: t["passed"],
          lines: t["coverage"].transform_values { |c| c["lines"].keys.map(&:to_i).to_set },
        )
      end
      @by_id = @tests.to_h { |t| [t.id, t] }
    end

    def test(id) = @by_id.fetch(id)

    # Forget files outside the project's own tree (a vendored bundle inside
    # the target directory, say).
    def restrict_to(files)
      keep = files.to_set
      @baseline.select! { |f, _| keep.include?(f) }
      @baseline_counts.select! { |f, _| keep.include?(f) }
      @tests.each { |t| t.lines.select! { |f, _| keep.include?(f) } }
      @require_edges.select! { |from, _, _| keep.include?(from) }
      self
    end

    def replace_tests(tests)
      @tests = tests
      @by_id = tests.to_h { |t| [t.id, t] }
      @data["tests"] = tests.map { |t| t.to_data }
    end

    def save(path) = File.write(path, JSON.generate(@data))

    # Files that were loaded by the suite at all.
    def loaded_files
      (baseline.keys + tests.flat_map { |t| t.lines.keys }).uniq
    end

    # Files some test actually executed code in, as opposed to merely loaded.
    def runtime_files
      tests.flat_map { |t| t.lines.keys }.uniq
    end
  end
end
