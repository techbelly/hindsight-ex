# frozen_string_literal: true

module Hindsight
  # Graphviz picture of the ordering: each step's chosen test and the runners-up.
  module Graph
    def self.dot(steps, record)
      lines = []
      lines << "digraph G {"
      lines << '  graph[rankdir=LR, margin=0.2, nodesep=0.1, ranksep=0.4]'
      lines << '  node[shape=rectangle, fontsize=9, style=filled]'
      lines << '  edge[arrowsize=0.6, arrowhead=vee, fontsize=8]'
      prev = "start"
      lines << '  start[label="start", fillcolor="#dddddd"]'
      steps.each_with_index do |step, depth|
        gains = step.candidates.map(&:last)
        min, max = gains.min, gains.max
        step.candidates.each do |id, gain|
          t = (gain - min).to_f / [max - min, 1].max
          red = ([2 * t, 1].min * 255).to_i
          green = ([2 * (1 - t), 1].min * 255).to_i
          node = "n#{depth}_#{id.hash.abs}"
          label = record.test(id).description.gsub('"', '\"')[0, 60]
          lines << %(  #{node}[label="#{label}", fillcolor="##{format('%02x%02x00', red, green)}"])
          lines << %(  #{prev} -> #{node}[label="#{gain}"])
        end
        prev = "n#{depth}_#{step.id.hash.abs}"
      end
      lines << "}"
      lines.join("\n") + "\n"
    end
  end
end
