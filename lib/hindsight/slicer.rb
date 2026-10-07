# frozen_string_literal: true

require "parser"
require "set"
begin
  require "prism"
  require "prism/translation/parser"
rescue LoadError
  require "parser/current"
end

module Hindsight
  # Cuts a Ruby source file down to the code a set of tests actually needed.
  #
  # Decisions are made on the AST but applied to the original text, line by
  # line, so formatting and comments survive. Two kinds of context matter:
  #
  #   :load  bodies that run when the file is required (class bodies, the top
  #          level, `describe` blocks). Statements here are structure and stay,
  #          except definitions, which are judged on their own merits.
  #   :run   bodies that run when something is called (method bodies, `it`
  #          blocks). A statement stays only if a test executed it.
  class Slicer
    Result = Struct.new(:text, :substantive, keyword_init: true)

    attr_reader :path

    # +runtime_lines+   lines of this file executed by the tests in play
    # +present_files+   project files that exist at this step (for requires)
    # +referenced+      constant names referenced by kept code anywhere
    def initialize(project, path, source, runtime_lines:, present_files:, referenced:, load_lines: Set.new,
                   referenced_methods: Set.new, whole_classes: Set.new)
      @project = project
      @path = path
      @source = source
      @runtime = runtime_lines
      @load = load_lines
      @referenced_methods = referenced_methods
      @whole_classes = whole_classes
      @whole_depth = 0
      @present = present_files
      @referenced = referenced
      @editor = LineEditor.new(source)
      @ast = self.class.parse(source)
      @dropped_defs = Set.new   # [scope, name] of methods dropped anywhere in this file
      @method_refs = []         # kept statements that name methods (alias, private ...)
      @singleton_depth = 0      # inside `class << self`?
    end

    # Parse to a parser-gem AST. Diagnostics are not fatal: Prism has already
    # accepted the file, and the translation layer is stricter than Ruby.
    def self.parse(source)
      @cache ||= {}
      @cache[source] ||= begin
        if defined?(Prism::Translation::Parser)
          parser = Prism::Translation::Parser.new
          parser.diagnostics.all_errors_are_fatal = false
          parser.diagnostics.ignore_warnings = true
          parser.diagnostics.consumer = ->(_d) {}
          parser.parse(Parser::Source::Buffer.new("(src)", source: source))
        else
          Parser::CurrentRuby.parse(source)
        end
      end
    end

    def self.parse_with_comments(source)
      buffer = Parser::Source::Buffer.new("(src)", source: source)
      if defined?(Prism::Translation::Parser)
        parser = Prism::Translation::Parser.new
        parser.diagnostics.all_errors_are_fatal = false
        parser.diagnostics.ignore_warnings = true
        parser.diagnostics.consumer = ->(_d) {}
        parser.parse_with_comments(buffer)
      else
        Parser::CurrentRuby.new.parse_with_comments(buffer)
      end
    end

    # Can this source be sliced at all?
    def self.parseable?(source)
      !parse(source).nil?
    rescue Parser::SyntaxError, StandardError
      false
    end

    def slice
      substantive = process_body(@ast, :load) == :substantive
      # Aliases and visibility calls may name methods dropped in another
      # body (`class << self; alias_method :path, :template_path; end`).
      prune_method_references(@method_refs.map { |s| [s, true] }, @dropped_defs) { |st| delete_node(st) }
      Result.new(text: @editor.result, substantive: substantive)
    end

    # Constant names defined at any level of this file.
    def self.defined_constants(source)
      names = Set.new
      walk(parse(source)) do |n|
        case n.type
        when :class, :module then names << n.children[0].children[1]
        when :casgn then names << n.children[1]
        end
      end
      names
    end

    # Constant names referenced in this source.
    def self.referenced_constants(source)
      names = Set.new
      walk(parse(source)) { |n| names << n.children[1] if n.type == :const }
      names
    end

    REFLECTION = %i[method instance_method public_method singleton_method respond_to? send __send__
                    public_send method_defined? instance_methods private_method_defined?
                    public_method_defined? protected_method_defined? define_method].to_set.freeze

    CLASS_REFLECTION = %i[instance_methods public_instance_methods private_instance_methods
                          protected_instance_methods instance_method public_instance_method
                          method_defined? public_method_defined? private_method_defined?
                          methods public_methods singleton_methods].to_set.freeze

    # Classes whose method list this source reflects over, by name:
    # `Liquid::Drop.public_instance_methods`. Every method of such a class
    # matters, so the class is kept whole.
    def self.whole_classes(source)
      names = Set.new
      walk(parse(source)) do |n|
        next unless n.type == :send && CLASS_REFLECTION.include?(n.children[1])
        recv = n.children[0]
        names << recv.children[1] if recv.is_a?(Parser::AST::Node) && recv.type == :const
      end
      names
    end

    # Method names this source looks up by symbol: `method(:partial)`,
    # `respond_to?(:each)`, `send(:parse)`. Coverage can't see these.
    def self.referenced_methods(source)
      names = Set.new
      walk(parse(source)) do |n|
        next unless n.type == :send && REFLECTION.include?(n.children[1])
        arg = n.children[2]
        names << arg.children[0] if arg.is_a?(Parser::AST::Node) && arg.type == :sym
      end
      names
    end

    def self.walk(node, &blk)
      return unless node.is_a?(Parser::AST::Node)
      blk.call(node)
      node.children.each { |c| walk(c, &blk) }
    end

    private

    # ----- helpers -------------------------------------------------------

    def node?(x) = x.is_a?(Parser::AST::Node)
    def first_line(n) = n.loc.expression.first_line

    # A heredoc's text sits below the statement that owns it, outside the
    # expression range, so a node's last line has to account for any heredoc
    # inside it.
    def last_line(n)
      @last_lines ||= {}
      @last_lines[n.object_id] ||= begin
        last = n.loc.expression.last_line
        self.class.walk(n) do |c|
          last = [last, c.loc.heredoc_end.line].max if c.loc.respond_to?(:heredoc_end) && c.loc.heredoc_end
        end
        last
      end
    end
    # Did a test run any line of this node? Did the file's load? Either?
    def runtime?(n) = node?(n) && (first_line(n)..last_line(n)).any? { |l| @runtime.include?(l) }
    def loaded?(n) = node?(n) && (first_line(n)..last_line(n)).any? { |l| @load.include?(l) }
    def executed?(n) = runtime?(n) || loaded?(n)
    def executed_line?(l) = @runtime.include?(l) || @load.include?(l)

    def statements(body)
      return [] if body.nil?
      body.type == :begin ? body.children : [body]
    end

    # Delete the lines a node owns outright. A line it shares with enclosing
    # code (`module A; class B; end; end`) is left alone.
    def delete_node(n)
      expr = n.loc.expression
      first, last = expr.first_line, last_line(n)
      owns_first = starts_line?(expr)
      owns_last = last > expr.last_line || @editor.line(last)[expr.end.column..].to_s.strip.sub(/\A#.*/, "").empty?
      return if first == last && !(owns_first && owns_last)
      first += 1 unless owns_first
      last -= 1 unless owns_last
      @editor.delete(first, last) if first <= last
    end

    # Does this line hold only the given keyword (plus optional comment)?
    def alone_on_line?(range)
      text = @editor.line(range.line)
      text.strip.sub(/\s*#.*/, "") == range.source
    end

    def starts_line?(range)
      @editor.line(range.line)[0...range.column].strip.empty?
    end

    def indent_of(line_no)
      @editor.line(line_no)[/\A[ \t]*/].size
    end

    # ----- bodies --------------------------------------------------------

    # Process a statement list. Returns :substantive when a needed definition
    # or an executed statement was kept, :structure when only structure was,
    # and false when nothing was.
    def process_body(body, ctx)
      stmts = statements(body)
      kept = stmts.map { |s| [s, process_stmt(s, ctx)] }
      if ctx == :load
        dropped = kept.filter_map { |s, keep| def_key(s) unless keep }.to_set
        @dropped_defs.merge(dropped)
        prune_method_references(kept, dropped) { |st| kept.find { |e| e[0].equal?(st) }[1] = false }
      end
      result = false
      kept.each_with_index do |(s, keep), i|
        if keep
          substantive = keep == :substantive || ctx == :run
          result = substantive ? :substantive : (result || :structure)
          if ctx == :load && method_reference?(s)
            reference_scope(s)
            @method_refs << s
          end
        else
          prev_kept = i > 0 && kept[i - 1][1] && last_line(kept[i - 1][0]) == first_line(s)
          next_kept = kept[i + 1] && kept[i + 1][1] && first_line(kept[i + 1][0]) == last_line(s)
          delete_node(s) unless prev_kept || next_kept
        end
      end
      result
    end

    METHOD_REFERENCING = %i[alias_method private protected public module_function
                            private_class_method public_class_method].freeze

    def method_reference?(s)
      node?(s) && (s.type == :alias ||
        (s.type == :send && s.children[0].nil? && METHOD_REFERENCING.include?(s.children[1])))
    end

    # `alias get []` or `private :foo` are structure, but they name methods.
    # When the method they name has been dropped they must go too, or be
    # trimmed to the names that remain. +drop+ is called for each to remove.
    def prune_method_references(kept, dropped, &drop)
      return if dropped.empty?
      kept.each do |s, keep|
        next unless keep && method_reference?(s)
        scope = reference_scope(s)
        if s.type == :alias
          drop.call(s) if sym_name(s.children[1])&.then { |n| dropped.include?([scope, n]) }
        else
          args = s.children[2..]
          next unless args.any? && args.all? { |a| node?(a) && a.type == :sym }
          if s.children[1] == :alias_method
            drop.call(s) if dropped.include?([scope, sym_name(args.last)])
          else
            keep_args = args.reject { |a| dropped.include?([scope, sym_name(a)]) }
            if keep_args.empty?
              drop.call(s)
            elsif keep_args.size < args.size && !multiline?(s)
              from, to = args.first.loc.expression, args.last.loc.expression
              @editor.replace(from.line, from.column, to.end.column, keep_args.map { |a| a.loc.expression.source }.join(", "))
            end
          end
        end
      end
    end

    def def_name(s)
      return nil unless node?(s)
      case s.type
      when :def then s.children[0]
      when :defs then s.children[1]
      when :send then s.children[2..].filter_map { |c| def_name(c) }.first
      end
    end

    # [:instance | :singleton, name] for a definition statement, or nil.
    def def_key(s)
      name = def_name(s)
      return nil unless name
      node = s.type == :send ? s.children[2..].find { |c| node?(c) && %i[def defs].include?(c.type) } : s
      singleton = node.type == :defs || @singleton_depth > 0
      [singleton ? :singleton : :instance, name]
    end

    # Which kind of method does a reference statement name? Note that a
    # reference's scope is fixed when it is recorded, since the singleton
    # depth changes as the walk proceeds.
    def reference_scope(s)
      @reference_scopes ||= {}
      @reference_scopes[s.object_id] ||=
        if @singleton_depth > 0 || (s.type == :send && %i[private_class_method public_class_method].include?(s.children[1]))
          :singleton
        else
          :instance
        end
    end

    def sym_name(n) = node?(n) && n.type == :sym ? n.children[0] : nil

    # Returns false (drop), true (keep as structure) or :substantive (keep, and it counts).
    def process_stmt(s, ctx)
      return ctx == :load unless node?(s)

      # Inside a method or test body, a definition is just a statement that
      # either ran or did not. Structure rules apply only at load time.
      if ctx == :run && %i[def defs class module sclass].include?(s.type)
        return false unless executed_line?(first_line(s))
        s.type == :def || s.type == :defs ? process_def_body(s.children.last, s.loc.end&.line) : process_body(s.children.last, :load)
        return :substantive
      end

      case s.type
      when :def, :defs then process_def(s)
      when :class, :module, :sclass then process_class(s)
      when :block, :numblock, :itblock then process_block(s, ctx)
      when :send
        if ctx == :load && (target = require_target(s))
          @present.include?(target)
        elsif (d = s.children[2..].find { |c| node?(c) && %i[def defs].include?(c.type) })
          process_def(d) # `private def foo` / `module_function def foo`
        else
          plain(s, ctx)
        end
      when :if then process_if(s, ctx)
      when :case then process_case(s, ctx)
      when :kwbegin then process_kwbegin(s, ctx)
      when :begin then process_body(s, ctx)
      when :while, :until, :for
        return ctx == :load unless executed?(s)
        process_body(s.children.last, :run)
        :substantive
      else
        plain(s, ctx)
      end
    end

    def plain(s, ctx)
      if ctx == :load
        descend(s)
        true
      elsif executed?(s)
        descend(s)
        :substantive
      else
        false
      end
    end

    # A kept statement may still contain blocks or conditionals with dead
    # lines inside (`x = items.map do ... end`). Prune those.
    def descend(n)
      return unless node?(n)
      n.children.each do |c|
        next unless node?(c)
        case c.type
        when :block, :numblock, :itblock
          process_body(c.children.last, :run) if multiline?(c)
        when :if, :case, :kwbegin, :def, :defs, :class, :module
          process_stmt(c, :run) if multiline?(c)
        else
          descend(c)
        end
      end
    end

    def multiline?(n) = first_line(n) != last_line(n)

    # ----- definitions ---------------------------------------------------

    # A method is needed if a test ran it, or if it ran while the file was
    # loading (a class-body helper like `initialize_settings`): that makes
    # it structure.
    def process_def(d)
      body = d.children.last
      if @referenced_methods.include?(def_name(d)) || fixture_method?(d) || @whole_depth > 0
        # Looked up by name somewhere; keep it whole, there is nothing to slice by.
        process_body(body, :load) if body && multiline?(d)
        return :substantive
      end
      needed =
        if body.nil? then true # an empty method is structure
        elsif multiline?(d) then runtime?(body) || loaded?(body)
        else @runtime.include?(first_line(d))
        end
      return false unless needed
      process_def_body(body, d.loc.end&.line)
      :substantive
    end

    # In a test file, a method that is not itself a test is a fixture or a
    # helper: a drop class's accessors, a stub. Tests reach those by
    # reflection as often as by calling them, so they stay whole.
    def fixture_method?(d)
      @project.test_file?(@path) && !def_name(d).to_s.start_with?("test_")
    end

    def process_def_body(body, end_line)
      return if body.nil?
      case body.type
      when :rescue then process_rescue(body, end_line)
      when :ensure then process_ensure(body, end_line)
      else process_body(body, :run)
      end
    end

    # A named class stays if it has needed methods or is referenced by name.
    # A singleton class (`class << self`) has no name: it stays if anything
    # inside it does.
    def process_class(c)
      body = c.children.last
      whole = c.type != :sclass && @whole_classes.include?(c.children[0].children[1])
      @singleton_depth += 1 if c.type == :sclass
      @whole_depth += 1 if whole
      result = process_body(body, :load)
      @whole_depth -= 1 if whole
      @singleton_depth -= 1 if c.type == :sclass
      return :substantive if whole
      return :substantive if result == :substantive
      return result == :structure if c.type == :sclass
      @referenced.include?(c.children[0].children[1])
    end

    # A block at load time is kept when something inside it survives: a body
    # that ran while the file loaded (`Dir[...].each { require }`) is
    # structure, a deferred one (`it`, `before`, `define_method`) lives or
    # dies by the tests, and a `describe` lives only if an `it` inside does.
    def process_block(b, ctx)
      body = b.children.last
      if ctx == :load
        return false unless executed?(body) || runtime_in_call?(b)
        return false unless process_body(body, body_context(body))
      else
        return false unless executed?(b)
        process_body(body, body_context(body))
      end
      :substantive
    end

    # `Struct.new(...) do ... end` or `describe X do` whose body ran at load,
    # but a `before` block inside ran at runtime: judged by descendants.
    def runtime_in_call?(b) = runtime?(b.children[0])

    # A block body is a :run body if a test executed its first statement,
    # otherwise it is more structure (a `describe` block, say). Load-time
    # execution does not count here: a `describe` body runs at load, and its
    # `it` blocks must still be judged individually.
    def body_context(body)
      first = statements(body).first
      return :run if first.nil?
      @runtime.include?(first_line(first)) ? :run : :load
    end

    def require_target(s)
      recv, meth, arg = s.children
      return nil unless recv.nil? && %i[require require_relative].include?(meth)
      return nil unless node?(arg) && arg.type == :str
      @project.resolve_require(meth, arg.children[0], @path)
    end

    # ----- conditionals --------------------------------------------------

    # if / elsif / else chains. Branches no test entered are cut out; if only
    # one branch is left the conditional disappears around it.
    def process_if(n, ctx)
      kw = n.loc.respond_to?(:keyword) ? n.loc.keyword : nil
      surgical = kw && n.loc.end && %w[if unless].include?(kw.source) &&
                 starts_line?(kw) && alone_on_line?(n.loc.end)

      unless surgical
        return ctx == :load unless executed?(n)
        branches(n).each { |b| process_body(b, :run) if node?(b) && multiline?(b) }
        return :substantive
      end
      return ctx == :load unless executed?(n)

      clauses = [] # [keyword_range, body]
      else_kw = nil
      else_body = nil
      cur = n
      loop do
        k = cur.loc.keyword
        if k.source == "unless"
          clauses << [k, cur.children[2]]
          else_body = cur.children[1]
          else_kw = cur.loc.else
          break
        end
        clauses << [k, cur.children[1]]
        rest = cur.children[2]
        if node?(rest) && rest.type == :if && rest.loc.respond_to?(:keyword) && rest.loc.keyword&.source == "elsif"
          cur = rest
        else
          else_kw = cur.loc.else
          else_body = rest
          break
        end
      end
      end_line = n.loc.end.line

      keep_clause = clauses.map { |_, body| node?(body) && executed?(body) }
      keep_else = node?(else_body) && executed?(else_body)

      # Line extents of each clause: from its keyword line to the line before the next part.
      boundaries = clauses.map { |k, _| k.line } + [else_kw&.line, end_line].compact

      if keep_clause.none? && !keep_else
        conds = clauses.map { |_, _| nil }
        conds = chain_conditions(n, clauses.size)
        return false if conds.all? { |c| pure?(c) }
        # The condition does something a test relies on, but no branch was
        # taken yet. Keep the conditions that ran; empty the bodies.
        clauses.each_with_index do |(k, _), i|
          cond = conds[i]
          if executed?(cond)
            @editor.delete(last_line(cond) + 1, boundaries[i + 1] - 1) if last_line(cond) + 1 <= boundaries[i + 1] - 1
          else
            @editor.delete(k.line, boundaries[i + 1] - 1)
          end
        end
        @editor.delete(else_kw.line, end_line - 1) if else_kw
        return :substantive
      end
      clauses.each_with_index do |(k, body), i|
        range = (k.line..(boundaries[i + 1] - 1))
        if keep_clause[i]
          process_body(body, :run)
        else
          @editor.delete(range.first, range.last)
        end
      end

      if keep_clause.any?
        if else_kw
          if keep_else
            process_body(else_body, :run)
          else
            @editor.delete(else_kw.line, end_line - 1)
          end
        end
        unless keep_clause.first
          first_kept = clauses[keep_clause.index(true)][0]
          @editor.replace(first_kept.line, first_kept.column, first_kept.column + first_kept.length, "if")
        end
      else
        # Only the else branch survives: unwrap it.
        @editor.delete(else_kw.line)
        @editor.delete(end_line)
        dedent = indent_of(first_line(else_body)) - kw.column
        @editor.dedent(else_kw.line + 1, end_line - 1, dedent)
        process_body(else_body, :run)
      end
      :substantive
    end

    # The condition expressions of an if/elsif chain, in order.
    def chain_conditions(n, count)
      conds = []
      cur = n
      count.times do
        conds << cur.children[0]
        cur = cur.children[2]
      end
      conds
    end

    # Can this expression be dropped without changing behaviour? Operators,
    # predicates, variables and literals: yes. Other calls and assignments: no.
    def pure?(n)
      return true unless node?(n)
      case n.type
      when :send, :csend
        m = n.children[1].to_s
        return false if %w[=~ !~ match match?].include?(m) # these set $~
        return false unless m.end_with?("?") || m !~ /\A[a-z_]/i
        pure?(n.children[0]) && n.children[2..].all? { |c| pure?(c) }
      when :block, :numblock, :itblock, :lvasgn, :ivasgn, :gvasgn, :cvasgn,
           :op_asgn, :or_asgn, :and_asgn, :masgn, :match_with_lvasgn, :yield, :super, :zsuper
        false
      else
        n.children.all? { |c| pure?(c) }
      end
    end

    def branches(n)
      n.type == :if ? n.children[1..2] : []
    end

    def process_case(n, ctx)
      kw = n.loc.keyword
      surgical = starts_line?(kw) && n.loc.end && alone_on_line?(n.loc.end)
      return ctx == :load unless executed?(n)

      whens = n.children[1..-2]
      else_body = n.children[-1]
      unless surgical
        whens.each { |w| process_body(w.children.last, :run) if node?(w.children.last) && multiline?(w) }
        process_body(else_body, :run) if node?(else_body) && multiline?(else_body)
        return :substantive
      end

      end_line = n.loc.end.line
      keep_when = whens.map { |w| node?(w.children.last) && executed?(w.children.last) }
      keep_else = node?(else_body) && executed?(else_body)
      return false if keep_when.none? && !keep_else

      boundaries = whens.map { |w| w.loc.keyword.line } + [n.loc.else&.line, end_line].compact
      whens.each_with_index do |w, i|
        range = (w.loc.keyword.line..(boundaries[i + 1] - 1))
        if keep_when[i]
          process_body(w.children.last, :run)
        else
          @editor.delete(range.first, range.last)
        end
      end

      if keep_when.any?
        if n.loc.else
          keep_else ? process_body(else_body, :run) : @editor.delete(n.loc.else.line, end_line - 1)
        end
      else
        @editor.delete(kw.line, boundaries.first - 1)
        @editor.delete(n.loc.else.line)
        @editor.delete(end_line)
        dedent = indent_of(first_line(else_body)) - kw.column
        @editor.dedent(n.loc.else.line + 1, end_line - 1, dedent)
        process_body(else_body, :run)
      end
      :substantive
    end

    # ----- begin / rescue / ensure --------------------------------------

    def process_kwbegin(n, ctx)
      return ctx == :load unless executed?(n)
      inner = n.children[0]
      end_line = n.loc.end.line
      if node?(inner) && inner.type == :rescue then process_rescue(inner, end_line)
      elsif node?(inner) && inner.type == :ensure then process_ensure(inner, end_line)
      else process_body(n.updated(:begin), :run) # plain begin/end: just a statement list
      end
      :substantive
    end

    def process_ensure(n, end_line)
      body, ensure_body = n.children
      ensure_line = n.loc.keyword.line
      if node?(body) && body.type == :rescue
        process_rescue(body, ensure_line)
      else
        process_body(body, :run)
      end
      process_body(ensure_body, :run)
    end

    # Rescue clauses no test triggered are removed. A clause with no body is
    # kept: it may be deliberately swallowing something.
    def process_rescue(n, end_line)
      body = n.children[0]
      resbodies = n.children[1..-2]
      else_body = n.children[-1]
      process_body(body, :run)

      boundaries = resbodies.map { |r| r.loc.keyword.line } + [n.loc.else&.line, end_line].compact
      resbodies.each_with_index do |r, i|
        rbody = r.children[2]
        if rbody.nil? || executed?(rbody)
          process_body(rbody, :run)
        else
          @editor.delete(r.loc.keyword.line, boundaries[i + 1] - 1)
        end
      end
      process_body(else_body, :run) if node?(else_body)
    end
  end
end
