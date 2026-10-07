# frozen_string_literal: true

require "set"

module Hindsight
  # Describes a step in words, from the code: which classes and methods
  # appeared or grew. No language model, just the syntax tree before and
  # after.
  module Narrator
    Entry = Struct.new(:kind, :name, :lines)

    # +before+ and +after+ map file => source (nil when absent).
    def self.describe(before, after, project)
      a = aggregate(after, project)
      b = aggregate(before, project)
      added_classes = (a[:classes] - b[:classes]).to_a
      added_methods = []
      grown_methods = []
      a[:methods].each do |m, size|
        if !b[:methods].key?(m) then added_methods << [m, size]
        elsif size > b[:methods][m] then grown_methods << [m, size - b[:methods][m]]
        end
      end
      lines = []
      lines << "Introduces #{list(added_classes)}." if added_classes.any?
      lines << "Adds #{list(added_methods.map(&:first))}." if added_methods.any?
      lines << "Extends #{list(grown_methods.map { |m, d| "#{m} (+#{d})" })}." if grown_methods.any?
      lines
    end

    def self.list(items, limit = 6)
      return items.join(", ") if items.size <= limit
      "#{items.first(limit).join(', ')} and #{items.size - limit} more"
    end

    # One index over all production files, so a module reopened in several
    # files counts once.
    def self.aggregate(files, project)
      out = { classes: Set.new, methods: {} }
      files.sort.each do |f, src|
        next if project.test_file?(f) || !project.ruby_file?(f)
        i = index(src)
        out[:classes].merge(i[:classes])
        i[:methods].each { |m, n| out[:methods][m] = (out[:methods][m] || 0) + n }
      end
      out
    end

    # Qualified class names and method names (with body line counts) in a source.
    def self.index(source)
      out = { classes: Set.new, methods: {} }
      return out if source.nil? || !Slicer.parseable?(source)
      visit(Slicer.parse(source), [], out)
      out
    end

    def self.visit(node, scope, out, singleton: false)
      return unless node.is_a?(Parser::AST::Node)
      case node.type
      when :class, :module
        name = const_name(node.children[0])
        full = (scope + [name]).join("::")
        out[:classes] << full
        visit(node.children.last, scope + [name], out)
      when :sclass
        visit(node.children.last, scope, out, singleton: true)
      when :def
        out[:methods][method_label(scope, node.children[0], singleton)] = span(node)
      when :defs
        out[:methods][method_label(scope, node.children[1], true)] = span(node)
      else
        node.children.each { |c| visit(c, scope, out, singleton: singleton) }
      end
    end

    def self.method_label(scope, name, singleton)
      owner = scope.empty? ? "(main)" : scope.join("::")
      "#{owner}#{singleton ? '.' : '#'}#{name}"
    end

    def self.const_name(node)
      parts = []
      while node.is_a?(Parser::AST::Node) && node.type == :const
        parts.unshift(node.children[1])
        node = node.children[0]
      end
      parts.join("::")
    end

    def self.span(node) = node.loc.expression.last_line - node.loc.expression.first_line + 1
  end
end
