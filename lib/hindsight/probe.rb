# frozen_string_literal: true

# Loaded into the target project's test process via RUBYOPT=-rhindsight/probe.
# Starts Ruby's Coverage before anything else loads, then snapshots coverage
# after every test so each test's runtime footprint can be told apart from
# load-time execution and from every other test.
#
# Environment:
#   HINDSIGHT_OUT   path to write the JSON record to
#   HINDSIGHT_ROOT  only files under this directory are recorded

require "coverage"
require "json"
require "timeout"

Coverage.start(lines: true, branches: true)

module Hindsight
  module Probe
    # Other tools in the target's test setup (SimpleCov, typically) also want
    # the Coverage module. Only one party can own it, and it has to be us, so
    # their calls become no-ops and they see empty results.
    module CoverageGuard
      def start(*) = nil
      def setup(*) = nil
      def resume = nil
      def suspend = nil
      def running? = Hindsight::Probe.owner? ? super : false
      def result(**opts) = Hindsight::Probe.owner? ? super : {}
      def peek_result = Hindsight::Probe.owner? ? super : {}
    end

    class << self
      def owner? = Thread.current[:hindsight_coverage_owner]

      def owning
        Thread.current[:hindsight_coverage_owner] = true
        yield
      ensure
        Thread.current[:hindsight_coverage_owner] = false
      end
    end
    Coverage.singleton_class.prepend(CoverageGuard)

    ROOT = File.expand_path(ENV.fetch("HINDSIGHT_ROOT", Dir.pwd)) + "/"
    OUT  = ENV.fetch("HINDSIGHT_OUT", "hindsight-coverage.json")
    ONLY = ENV["HINDSIGHT_ONLY"]           # run just this test id
    ONLY_FILE = ENV["HINDSIGHT_ONLY_FILE"] # run just the tests defined in this file (relative to ROOT)
    # Seconds a single test may take. In a partial tree a loop whose body was
    # cut away never ends; this turns that into one failed test instead of a
    # hung process.
    TEST_TIMEOUT = ENV["HINDSIGHT_TEST_TIMEOUT"]&.to_f

    def self.bounded
      return yield unless TEST_TIMEOUT && TEST_TIMEOUT > 0
      Timeout.timeout(TEST_TIMEOUT, TestTimedOut) { yield }
    end

    class TestTimedOut < StandardError; end

    def self.selected?(id, file = nil)
      return false if ONLY && ONLY != id
      return false if ONLY_FILE && file && relative(file) != ONLY_FILE
      true
    end

    @tests = []
    @baseline = nil
    @requires = {}

    class << self
      def before_test
        @baseline ||= compact(owning { Coverage.result(stop: false, clear: true) })
      end

      def after_test(id:, file:, line:, passed:, description: nil)
        cov = compact(owning { Coverage.result(stop: false, clear: true) })
        @tests << {
          "id" => id,
          "description" => description || id,
          "file" => relative(file),
          "line" => line,
          "passed" => passed,
          "coverage" => cov,
        }
      end

      # Remember that +from+ (an absolute path) required +arg+ via +method+,
      # when +from+ is a project file. Resolved to files later, offline.
      def note_require(from, method, arg)
        return unless from.start_with?(ROOT) && arg.is_a?(String)
        @requires[[relative(from), method.to_s, arg]] = true
      end

      def write
        # Anything still in the counters is post-test teardown; fold it into
        # the baseline so nothing gets lost. In practice it is negligible.
        trailing = compact(owning { Coverage.result(stop: true, clear: true) })
        @baseline ||= {}
        merge!(@baseline, trailing)
        data = {
          "root" => ROOT.chomp("/"),
          "ruby" => RUBY_VERSION,
          "baseline" => @baseline,
          "requires" => @requires.keys,
          "tests" => @tests,
        }
        File.write(OUT, JSON.generate(data))
      end

      def relative(path)
        path.start_with?(ROOT) ? path.delete_prefix(ROOT) : path
      end

      private

      # Keep only project files and only lines/branches that executed.
      # lines:    { "12" => count, ... }
      # branches: { "then:12:4:14:7" => count } keyed by the branch *target*
      #           location (type:first_line:first_col:last_line:last_col).
      def compact(result)
        out = {}
        result.each do |path, cov|
          next unless path.start_with?(ROOT)
          lines = {}
          cov[:lines].each_with_index do |count, i|
            lines[(i + 1).to_s] = count if count && count > 0
          end
          branches = {}
          cov[:branches].each_value do |targets|
            targets.each do |(type, _id, fl, fc, ll, lc), count|
              branches["#{type}:#{fl}:#{fc}:#{ll}:#{lc}"] = count if count > 0
            end
          end
          next if lines.empty? && branches.empty?
          out[relative(path)] = { "lines" => lines, "branches" => branches }
        end
        out
      end

      def merge!(into, from)
        from.each do |file, cov|
          target = into[file] ||= { "lines" => {}, "branches" => {} }
          cov["lines"].each { |l, c| target["lines"][l] = (target["lines"][l] || 0) + c }
          cov["branches"].each { |b, c| target["branches"][b] = (target["branches"][b] || 0) + c }
        end
      end
    end

    # --- Require graph -----------------------------------------------------

    # With HINDSIGHT_LENIENT set, a test file that fails to load is skipped
    # rather than aborting the run (Minitest's autorun would otherwise run
    # nothing). Used when probing which pending tests already pass.
    LENIENT = ENV["HINDSIGHT_LENIENT"] == "1"

    module RequireHook
      def require(path)
        loc = caller_locations(1, 1)&.first
        Hindsight::Probe.note_require(loc.absolute_path || loc.path, :require, path) if loc
        super
      rescue StandardError, ScriptError => e
        test_path = path.to_s.start_with?(ROOT) && path.to_s.match?(%r{/(test|spec|features)/})
        # A test file that does not exist yet is not an error in a sliced
        # tree; any other failure to load one is, unless we are being lenient.
        missing = e.is_a?(LoadError) && e.path.to_s == path.to_s && !File.exist?(path.to_s) && !File.exist?("#{path}.rb")
        raise unless test_path && (LENIENT || missing)
        warn "hindsight: skipped #{path}: #{e.class}: #{e.message.lines.first}" unless missing
        false
      end

      def require_relative(path)
        loc = caller_locations(1, 1)&.first
        if loc
          Hindsight::Probe.note_require(loc.absolute_path || loc.path, :require_relative, path)
          # require_relative resolves against the caller, which is now us.
          return super(File.expand_path(path, File.dirname(loc.absolute_path || loc.path)))
        end
        super
      end
    end
    Kernel.prepend(RequireHook)
    Kernel.singleton_class.prepend(RequireHook)

    # --- Framework hooks -------------------------------------------------

    module MinitestHook
      def run
        id = "#{self.class.name}##{name}"
        unless Hindsight::Probe.selected?(id, method(name).source_location&.first)
          failures << Minitest::Skip.new("not selected by hindsight")
          return Minitest::Result.from(self)
        end
        Hindsight::Probe.before_test
        result = begin
          Hindsight::Probe.bounded { super }
        rescue Hindsight::Probe::TestTimedOut => e
          failures << Minitest::UnexpectedError.new(e)
          Minitest::Result.from(self)
        end
        file, line = method(name).source_location
        desc = self.class.respond_to?(:desc) ? "#{self.class.desc} #{name.sub(/\Atest_\d+_/, "")}" : "#{self.class.name}##{name}"
        Hindsight::Probe.after_test(
          id: "#{self.class.name}##{name}",
          description: desc,
          file: file, line: line,
          passed: passed?,
        )
        result
      end
    end

    def self.install_minitest
      require "minitest"
      Minitest::Test.prepend(MinitestHook)
      true
    rescue LoadError
      false
    end

    def self.install_rspec
      require "rspec/core"
      RSpec.configure do |config|
        config.around(:each) do |example|
          next example.skip("not selected by hindsight") unless Hindsight::Probe.selected?(example.id, example.metadata[:absolute_file_path])
          Hindsight::Probe.before_test
          Hindsight::Probe.bounded { example.run }
          Hindsight::Probe.after_test(
            id: example.id,
            description: example.full_description,
            file: example.metadata[:absolute_file_path],
            line: example.metadata[:line_number],
            passed: example.exception.nil?,
          )
        end
      end
      true
    rescue LoadError
      false
    end
  end
end

Hindsight::Probe.install_minitest
Hindsight::Probe.install_rspec

# Registered before the test framework's own at_exit, so it runs after the suite.
at_exit { Hindsight::Probe.write }
