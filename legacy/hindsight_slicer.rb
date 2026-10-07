require 'parser/current'
require 'pry'

class HindsightSlicer < Struct.new(:coverage)

  class Noop
    def process(parse_tree)
      return parse_tree
    end
  end

  EMPTY = Object.new()

  def empty_node?(c)
    c == EMPTY
  end

  def node_span(node)
    [node.location.first_line - 1, node.location.last_line - 1]
  end

  def node_coverage(node)
    first_line, last_line = node_span(node)
    coverage[first_line..last_line]
  end

  def coverage_count(node)
    node_coverage(node).compact.max || 0
  end

  def same_line?(node1, node2)
    return node_span(node1) == node_span(node2)
  end

  def remove_empty_methods(node, children)
    body = children[2]
    return EMPTY if body.nil? || empty_node?(body)
  end

  def remove_empty_branches(node, children)
    if_branch, else_branch = children[1], children[2]
    covered_branches = [if_branch, else_branch].select {|b| b && !empty_node?(b) }
    case covered_branches.length
    when 0
      return EMPTY
    when 1
      non_empty_branch = covered_branches.first
      if coverage_count(non_empty_branch) == coverage_count(node)
        return non_empty_branch
      end
    end
  end

  def node_with_updated_children(node, children)
    node.updated(node.type, children, {location: node.location})
  end

  def fix_up_case_statements(node, children)
    last_return_value = children.last.children[1]

    if children.length == 2
      return last_return_value
    end

    if children.length > 2 && children.last.type == :when
      new_children = children[0..-2].push(last_return_value)
      return node_with_updated_children(node, new_children)
   end
  end

  def postprocess(node, children)
    children = children.reject {|c| empty_node?(c)}

    new_node = case node.type
      when :begin
        EMPTY if children.empty?
      when :def
        remove_empty_methods(node, children)
      when :if
        remove_empty_branches(node, children)
      when :case
        fix_up_case_statements(node, children)
      end
    new_node || node_with_updated_children(node, children)
  end

  def process(node)
    return node unless node.is_a? Parser::AST::Node
    return node unless node.location.expression #????
    return node if node.type == :str
    
    return EMPTY if node.type != :begin && coverage_count(node) == 0

    children = node.children.map { |child| process(child) }
    postprocess(node, children)
  end

end
