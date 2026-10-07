# frozen_string_literal: true

require "set"

module Hindsight
  # Edits a source file by whole lines only: delete lines, dedent lines, swap a
  # keyword within a line. Every surviving line keeps its identity, so edits
  # from different parts of the AST never conflict and compose additively.
  class LineEditor
    attr_reader :lines

    def initialize(source)
      @lines = source.lines
      @deleted = Set.new
      @dedent = Hash.new(0)
      @replacements = Hash.new { |h, k| h[k] = [] }
    end

    def line(n) = @lines[n - 1]
    def line_count = @lines.size
    def deleted?(n) = @deleted.include?(n)

    def delete(first, last = first)
      (first..last).each { |n| @deleted << n }
      delete_leading_comments(first)
    end

    def dedent(first, last, columns)
      return if columns <= 0
      (first..last).each { |n| @dedent[n] += columns }
    end

    # Replace columns [col_begin, col_end) of line n (0-based columns).
    def replace(n, col_begin, col_end, text)
      edit = [col_begin, col_end, text]
      @replacements[n] << edit unless @replacements[n].include?(edit)
    end

    def result
      out = []
      @lines.each_with_index do |text, i|
        n = i + 1
        next if @deleted.include?(n)
        @replacements[n].sort_by { |b, _, _| -b }.each do |b, e, t|
          text = text[0...b] + t + text[e..]
        end
        if @dedent[n] > 0
          indent = text[/\A[ \t]*/].size
          text = text[[@dedent[n], indent].min..]
        end
        out << text
      end
      tidy(out)
    end

    private

    # A comment sitting directly above deleted code describes that code.
    def delete_leading_comments(first)
      n = first - 1
      while n >= 1 && @lines[n - 1] =~ /\A\s*#(?!\s*(frozen_string_literal|encoding|rubocop|typed):)/
        @deleted << n
        n -= 1
      end
    end

    def tidy(out)
      text = out.join
      text = text.gsub(/\n{3,}/, "\n\n")                       # squeeze blank runs
      text = text.gsub(/\n\n(\s*end\b)/, "\n\\1")              # no blank line before end
      text = text.gsub(/^([ \t]*(?:class|module|def)\b[^\n]*\n|[^\n]*\bdo(?: \|[^|\n]*\|)?\n)\n+/, "\\1") # none after opener
      text = text.sub(/\A\n+/, "")
      text.rstrip + "\n"
    end
  end
end
