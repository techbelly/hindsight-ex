# frozen_string_literal: true

require "bundler/setup"
require "minitest/autorun"
require "set"
require_relative "../lib/hindsight"

# Slices inline sources. Runtime lines are marked in the source with a
# trailing `#R` comment, load-time lines with `#L`, so each case reads as a
# picture of what ran.
class SlicerTest < Minitest::Test
  FakeProject = Struct.new(:present) do
    def resolve_require(_method, arg, _from)
      arg.start_with?("lib/") ? arg + ".rb" : nil
    end

    def test_file?(path) = path.start_with?("test/")
  end

  def slice(src, present: [], referenced: [], methods: [], whole: [], used: nil, missing: [], path: "lib/x.rb")
    runtime = Set.new
    load = Set.new
    clean = src.lines.each_with_index.map do |line, i|
      runtime << i + 1 if line =~ /\s*#R\s*$/
      load << i + 1 if line =~ /\s*#L\s*$/
      line.sub(/\s*#[RL]\s*$/, "\n")
    end.join
    Hindsight::Slicer.new(FakeProject.new(present), path, clean,
                          runtime_lines: runtime, present_files: present.to_set,
                          referenced: referenced.to_set, referenced_methods: methods.to_set,
                          whole_classes: whole.to_set, used_methods: used&.to_set, missing_methods: missing.to_set,
                          load_lines: load).slice.text
  end

  def test_untaken_branches_are_cut_and_the_chain_rejoined
    out = slice(<<~RUBY)
      class A
        def f(x)
          if x > 1      #R
            "big"
          elsif x < 0
            "neg"       #R
          else
            "small"
          end
        end
      end
    RUBY
    assert_equal <<~RUBY, out
      class A
        def f(x)
          if x < 0
            "neg"
          end
        end
      end
    RUBY
  end

  def test_only_else_taken_unwraps_the_conditional
    out = slice(<<~RUBY)
      def f(x)
        if x.nil?       #R
          1
        else
          2             #R
        end
      end
    RUBY
    assert_equal "def f(x)\n  2\nend\n", out
  end

  def test_pure_condition_with_no_branch_taken_is_dropped
    out = slice(<<~RUBY)
      def f(x)
        y = 1           #R
        if x.nil?       #R
          raise "no"
        end
        y               #R
      end
    RUBY
    assert_equal "def f(x)\n  y = 1\n  y\nend\n", out
  end

  def test_impure_condition_with_no_branch_taken_keeps_an_empty_if
    out = slice(<<~RUBY)
      def f(x)
        if opt = try(x) #R
          use(opt)
        end
      end
    RUBY
    assert_equal "def f(x)\n  if opt = try(x)\n  end\nend\n", out
  end

  def test_match_operators_are_side_effects_so_their_conditional_stays
    out = slice(<<~RUBY)
      def f(markup)
        unless markup =~ /x/ #R
          raise "no"
        end
        Regexp.last_match(1)  #R
      end
    RUBY
    assert_includes out, "unless markup =~ /x/\n  end"
  end

  def test_untriggered_rescue_clauses_go
    out = slice(<<~RUBY)
      def f
        begin           #R
          work          #R
        rescue IOError
          retry
        rescue ArgumentError => e
          log(e)        #R
        end
      end
    RUBY
    assert_equal <<~RUBY, out
      def f
        begin
          work
        rescue ArgumentError => e
          log(e)
        end
      end
    RUBY
  end

  def test_plain_begin_blocks_are_statement_lists
    out = slice(<<~RUBY)
      def f
        begin           #R
          a             #R
          b
        end
      end
    RUBY
    assert_equal "def f\n  begin\n    a\n  end\nend\n", out
  end

  def test_dropping_a_method_takes_its_heredoc_and_comment
    out = slice(<<~RUBY)
      class E
        def used         #L
          1              #R
        end

        # Renders the error.
        def to_s
          <<-EOF
      #{@message}
        Line 1
      EOF
        end
      end
    RUBY
    assert_equal "class E\n  def used\n    1\n  end\nend\n", out
  end

  def test_heredoc_body_lines_count_as_the_methods_lines
    out = slice(<<~RUBY)
      class E
        def to_s
          <<-EOF
      text               #R
      EOF
        end
      end
    RUBY
    assert_includes out, "def to_s"
  end

  def test_aliases_follow_their_methods_by_scope
    out = slice(<<~RUBY)
      class R
        def self.path    #L
          1              #R
        end
        def path
          2
        end
        alias get path
        class << self
          alias_method :p, :path
        end
      end
    RUBY
    refute_includes out, "alias get path"
    assert_includes out, "alias_method :p, :path"
    assert_includes out, "class << self"
  end

  def test_visibility_lists_are_trimmed
    out = slice(<<~RUBY)
      class V
        def a            #L
          1              #R
        end
        def b
          2
        end
        private :a, :b
      end
    RUBY
    assert_includes out, "private :a\n"
  end

  def test_one_line_class_defined_inside_a_test_body_survives
    out = slice(<<~RUBY)
      describe "x" do                                  #L
        it "works" do                                  #L
          module Slop; class FooOption < Base; end; end  #R
          assert Slop.option_defined?(:foo)            #R
        end
        it "later" do                                  #L
          assert false
        end
      end
    RUBY
    assert_includes out, "class FooOption"
    refute_includes out, "later"
  end

  def test_load_time_blocks_are_structure_and_deferred_ones_are_not
    out = slice(<<~RUBY)
      Dir["*.rb"].each do |f|   #L
        require f               #L
      end
      at_exit do                #L
        cleanup
      end
      class A
        def go                  #L
          1                     #R
        end
      end
    RUBY
    assert_includes out, "require f"
    refute_includes out, "cleanup"
  end

  def test_requires_of_absent_project_files_are_dropped
    out = slice(<<~RUBY, present: ["lib/here.rb"])
      require "lib/here"        #L
      require "lib/gone"        #L
      require "json"            #L
      class A
        def go                  #L
          1                     #R
        end
      end
    RUBY
    assert_includes out, 'require "lib/here"'
    assert_includes out, 'require "json"'
    refute_includes out, "gone"
  end

  def test_unreferenced_classes_without_needed_methods_vanish_and_referenced_ones_stay
    src = <<~RUBY
      module M
        class Used < Base
          def go              #L
            1                 #R
          end
        end
        class Error < StandardError; end
        class Other < Error
          def x
            2
          end
        end
      end
    RUBY
    out = slice(src)
    refute_includes out, "Error"
    out = slice(src, referenced: [:Other])
    assert_includes out, "class Other < Error\n  end"
    refute_includes out, "def x"
  end

  def test_methods_looked_up_by_symbol_are_kept_whole
    out = slice(<<~RUBY, methods: [:partial])
      class T
        def partial(name)
          read(name)
        end
        def other
          1
        end
      end
    RUBY
    assert_includes out, "read(name)"
    refute_includes out, "def other"
  end

  def test_fixture_methods_in_test_files_stay_whole_but_tests_do_not
    out = slice(<<~RUBY, path: "test/drop_test.rb")
      class TextDrop < Liquid::Drop
        def texts
          ["text1"]
        end
      end
      class DropsTest < Minitest::Test
        def test_texts            #L
          assert TextDrop.new     #R
        end
        def test_other
          assert false
        end
      end
    RUBY
    assert_includes out, '["text1"]'
    assert_includes out, "test_texts"
    refute_includes out, "test_other"
  end

  def test_classes_reflected_over_are_kept_whole
    src = <<~RUBY
      class Drop
        def used          #L
          1               #R
        end
        def liquid_method_missing(m)
          nil
        end
      end
    RUBY
    refute_includes slice(src), "liquid_method_missing"
    assert_includes slice(src, whole: [:Drop]), "liquid_method_missing"
    assert_equal Set[:Drop], Hindsight::Slicer.whole_classes("x = Liquid::Drop.public_instance_methods")
  end

  def test_methods_that_ran_at_load_time_are_structure
    out = slice(<<~RUBY)
      class S
        def self.setup     #L
          @x = 1           #L
        end
        setup              #L
        def unused
          2
        end
      end
    RUBY
    assert_includes out, "def self.setup"
    refute_includes out, "unused"
  end

  def test_comments_are_stripped_except_magic_ones
    src = <<~RUBY
      # frozen_string_literal: true
      # Describes the class.
      class A
        X = "a # not a comment" # trailing
      =begin
      block
      =end
        def go; end
      end
    RUBY
    assert_equal <<~RUBY, Hindsight::Comments.strip(src)
      # frozen_string_literal: true
      class A
        X = "a # not a comment"
        def go; end
      end
    RUBY
  end

  def test_namespace_wrappers_do_not_count_as_definitions
    defs = Hindsight::Slicer.defined_constants(<<~RUBY)
      module Slop
        class Error < StandardError; end
        module Util
          class Thing
            def go; end
          end
        end
        VERSION = "1"
      end
    RUBY
    assert_equal Set[:Error, :Thing, :VERSION], defs
    assert Hindsight::Slicer.hollow?("require 'x'\nmodule Slop\nend\n")
    refute Hindsight::Slicer.hollow?("module Slop\n  class E < StandardError; end\nend\n")
  end

  def test_constant_aliases_follow_their_classes
    out = slice(<<~RUBY)
      module Slop
        class BoolOption < Option
          def call; end
        end
        BooleanOption = BoolOption
        class Used < Option
          def go       #L
            1          #R
          end
        end
      end
    RUBY
    refute_includes out, "BooleanOption"
    assert_includes out, "class Used"
  end

  def test_attributes_and_constants_wait_until_used
    src = <<~RUBY
      class Option
        DEFAULT = { a: 1 }
        LIMIT = 3
        attr_reader :flags, :desc
        attr_accessor :value
        def go              #L
          flags             #R
        end
      end
    RUBY
    out = slice(src, used: [:flags, :value=], referenced: [:LIMIT])
    assert_includes out, "attr_reader :flags\n"
    refute_includes out, "desc"
    assert_includes out, "attr_writer :value"
    assert_includes out, "LIMIT = 3"
    refute_includes out, "DEFAULT"
    assert_includes slice(src), "attr_reader :flags, :desc" # no usage info: keep all
  end

  def test_constant_visibility_follows_the_constants
    out = slice(<<~RUBY, referenced: [:KEEP])
      class F
        KEEP = 1
        GONE = 2
        private_constant :KEEP, :GONE
        def go     #L
          1        #R
        end
      end
    RUBY
    assert_includes out, "private_constant :KEEP\n"
    refute_includes out, "GONE"
  end

  def test_aliases_keep_their_attribute_alive_and_follow_it_when_pruned
    src = <<~RUBY
      class Tag
        attr_reader :nodelist, :parse_context
        alias_method :options, :parse_context
        def go      #L
          1         #R
        end
      end
    RUBY
    out = slice(src, used: [:options, :parse_context])
    assert_includes out, "attr_reader :parse_context"
    assert_includes out, "alias_method :options, :parse_context"
    out = slice(src, used: [:nodelist])
    refute_includes out, "alias_method"
    assert_equal Set[:options, :parse_context], Hindsight::Slicer.used_methods("alias_method :options, :parse_context\nx.options\n") & Set[:options, :parse_context]
  end

  def test_aliases_to_methods_missing_from_other_files_are_pruned
    out = slice(<<~RUBY, missing: [:options])
      class Include < Tag
        alias_method :parse_context, :options
        def go     #L
          1        #R
        end
      end
    RUBY
    refute_includes out, "alias_method"
    assert_equal Set[:a, :b, :b=, :c, :d], Hindsight::Slicer.defined_methods("def a; end\nattr_accessor :b\nalias_method :c, :a\nalias d a\n")
  end
end
