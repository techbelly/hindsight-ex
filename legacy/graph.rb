require 'stringio'
require 'css_color'

module Graph
  def self.add(smallest_candidate, results)
    @previous_node ||= "start"
    @depth ||= 0

    ordered = results
      .map { |test, lines| [test, lines.to_i] }
      .sort_by(&:last)

    min = ordered.first.last
    max = ordered.last.last

    colormap = ordered.each.with_object({}) do |(test, lines), hash|
      normalised = (lines - min).to_f  / [max - min, 1].max

      red = ([2 * normalised, 1].min * 255).to_i
      green = ([2 * (1 - normalised), 1].min * 255).to_i

      hash[test] = CSSColor.parse("rgb(#{red}, #{green}, 0)")
    end

    results.each do |test, lines|
      color = colormap[test]
      io.puts "#{name(@previous_node, @depth)} -> #{name(test, @depth + 1)}[label=#{lines}]"
      io.puts %{#{name(test, @depth + 1)}[style=filled fillcolor="##{color.hex}"]}
    end


    @previous_node = smallest_candidate
    @depth += 1
  end

  def self.name(test, depth)
    "#{test.split("#").last}_#{depth}"
  end

  def self.write(path)
    File.open(path, "w") do |f|
      f.write <<-DOT
        digraph G {
          graph[rankdir=LR, center=true, margin=0.2, nodesep=0.1, ranksep=0.3]
          node[shape=rectangle, fontsize=10, width=1.5, height=0.4, fixedsize=true]
          edge[arrowsize=0.6, arrowhead=vee, fontsize=10]
          #{io.string}
        }
      DOT
    end
  end

  def self.io
    @io ||= StringIO.new
  end
end
