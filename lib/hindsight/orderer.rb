# frozen_string_literal: true

require "json"
require "set"

module Hindsight
  # Greedy ordering: at each step pick the test that adds the fewest new
  # production lines. That is the TDD instinct of taking the smallest step.
  # Ties go to tests near the previous one in the same file so the story
  # walks through one feature at a time.
  class Orderer
    Step = Struct.new(:id, :gain, :candidates, keyword_init: true)

    CANDIDATES_TO_KEEP = 6

    def initialize(record, project)
      @record = record
      @project = project
    end

    def order
      intern = Hash.new { |h, k| h[k] = h.size }
      sets = @record.tests.to_h do |t|
        [t, t.production_lines(@project).flat_map { |f, ls| ls.map { |l| intern["#{f}:#{l}"] } }.to_set]
      end
      gain = sets.transform_values(&:size)
      covered = Set.new
      remaining = @record.tests.dup
      previous = nil
      steps = []

      until remaining.empty?
        best = remaining.min_by { |t| [gain[t], *locality(t, previous), t.file, t.line] }
        ranked = remaining.sort_by { |t| [gain[t], t.file, t.line] }.first(CANDIDATES_TO_KEEP)
        steps << Step.new(id: best.id, gain: gain[best], candidates: ranked.map { |t| [t.id, gain[t]] })

        fresh = sets[best] - covered
        covered.merge(fresh)
        remaining.delete(best)
        remaining.each { |t| gain[t] -= fresh.count { |l| sets[t].include?(l) } }
        previous = best
      end
      steps
    end

    def self.save(steps, path)
      File.write(path, JSON.pretty_generate("steps" => steps.map(&:to_h)))
    end

    def self.load(path)
      JSON.parse(File.read(path))["steps"].map do |s|
        Step.new(id: s["id"], gain: s["gain"], candidates: s["candidates"])
      end
    end

    private

    def locality(test, previous)
      return [1, 0] unless previous && previous.file == test.file
      [0, (test.line - previous.line).abs]
    end
  end
end
