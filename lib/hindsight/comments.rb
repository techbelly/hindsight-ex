# frozen_string_literal: true

module Hindsight
  # Removes comments from Ruby source. A generated history has no author
  # whose remarks these would be, and comments describing code that is not
  # there yet only mislead. Magic comments stay: they change behaviour.
  module Comments
    MAGIC = /\A#\s*(-\*-|frozen[-_]string[-_]literal|encoding|coding|warn[-_]indent|shareable[-_]constant[-_]value|typed)\b/i

    def self.strip(source)
      _ast, comments = Slicer.parse_with_comments(source)
      lines = source.lines
      doomed = []
      comments.each do |c|
        text = c.text
        next if text =~ MAGIC
        expr = c.loc.expression
        if c.document? # =begin ... =end; the range may run onto the next line
          last = expr.first_line + text.chomp.lines.size - 1
          (expr.first_line..last).each { |l| doomed << l }
        elsif lines[expr.line - 1][0...expr.column].strip.empty?
          doomed << expr.line
        else
          lines[expr.line - 1] = lines[expr.line - 1][0...expr.column].rstrip + "\n"
        end
      end
      doomed.each { |l| lines[l - 1] = nil }
      LineEditor.tidy(lines.compact.join)
    end
  end
end
