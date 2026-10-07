# frozen_string_literal: true

require "fileutils"
require "open3"
require "json"
require "set"
require "tmpdir"
require "etc"

module Hindsight
  # Replays the plan into a fresh git repository, one commit per test.
  #
  # With verification on, each step's tests are run before committing. When
  # they fail, the slicer is told to be more generous with one file at a time
  # until they pass: first keeping all of a file's classes and constants
  # (structure), then the whole file. Those decisions stick for later steps.
  class Builder
    MAX_PASSES = 6
    LEVELS = %i[sliced structure full].freeze

    # Lets `referenced.include?(anything)` be true.
    EVERYTHING = Object.new.tap { |o| def o.include?(_) = true }

    attr_reader :failures, :escalations

    def initialize(project:, record:, steps:, out:, test_command: nil, verify: false, limit: nil, log: $stderr)
      @project = project
      @record = record
      @steps = limit ? steps.first(limit) : steps
      @out = File.expand_path(out)
      @test_command = test_command || project.default_test_command
      @verify = verify
      @log = log
      @failures = []
      @escalations = []
      @levels = Hash.new(:sliced)
      @structural_now = Set.new
      @forced = Set.new # constants to treat as referenced from now on
      @folded = {}      # tests folded into earlier steps, by id
      @included = []    # tests committed as steps so far
      @full_ids = Set.new # tests whose library footprint is in the union
      @deferred = []    # tests nothing short of everything would satisfy
      @last_failures = []
      @red = {}         # test id => true if the previous fold run saw it fail
      @sources = {}
      @written = Set.new
    end

    def build
      reset_repo
      @clock = Clock.new(@project, @steps.size)
      write_scaffold
      commit("Project scaffolding", "Build files, documentation and licences. No code yet.", date: @clock.start)

      previous_sizes = {}
      previous_outputs = {}
      pending = @steps.map { |st| @record.test(st.id) }
      n = 0
      until pending.empty?
        test = pending.shift
        n += 1
        @step_now = n
        was_red = @red.key?(test.id) # seen failing on the previous tree
        @included << test
        @full_ids << test.id
        outputs = timed("slice") { slice_all(union_now) }
        sync(outputs)
        ok = nil
        escalated = []
        folded = []
        if @verify
          ok = timed("verify") { verify(n, test) }
          unless ok
            ok, escalated, outputs = timed("escalate") { escalate(n, test, pending) }
          end
          unless ok
            # Nothing short of the whole project satisfies this test. Leave it
            # for the end rather than let it swallow the story.
            @included.delete(test)
            @full_ids.delete(test.id)
            @deferred << test
            @failures.reject! { |fn, _| fn == n }
            outputs = slice_all(union_now)
            sync(outputs)
            @log.puts format("⊘ %4d  %4d left  %s (deferred: cannot be satisfied incrementally)", n, pending.size, test.description[0, 70])
            n -= 1
            next
          end
          if pending.any?
            folded = timed("fold") { fold_passing(union_now, pending) }
            unless folded.empty?
              pending -= folded
              # Only their test code joins now. If a later step routes one of
              # them down a path that needs more, its footprint is merged then.
              folded.each { |t| @folded[t.id] = t }
              outputs = slice_all(union_now)
              sync(outputs)
            end
          end
        end
        sizes = outputs.transform_values { |t| t.lines.size }
        story = Narrator.describe(previous_outputs, outputs, @project)
        commit(subject_for(test), step_body(n, test, sizes, previous_sizes, ok, escalated, folded, story, was_red), date: @clock.tick(sizes, previous_sizes))
        previous_sizes = sizes
        previous_outputs = outputs
        progress(n, pending.size, test, ok, escalated, folded)
      end
      @step_count = n

      write_everything
      body = +"Code no test reached, and files the test suite never loaded."
      body << "\n\nTests that could not be satisfied incrementally:\n" << @deferred.map { |t| "  #{humanise(t.description)} (#{t.file}:#{t.line})" }.join("\n") if @deferred.any?
      commit("Everything else", body, date: @clock.finish)
      File.write(File.join(@out, "HINDSIGHT.md"), Story.new(@project, @out, @record, deferred: @deferred.map { |t| humanise(t.description) }).render)
      commit("Explain where this history came from", "Provenance and a table of contents, generated.", date: @clock.finish)
      @log.puts "\nBuilt #{@step_count + 2} commits in #{@out} (#{@steps.size} tests)"
      @log.puts "Escalations: #{@escalations.map { |n, f, l| l == :class || l == :footprint || l == :unfold ? "#{l} #{f[0, 50]} at step #{n}" : "#{f} to #{l} at step #{n}" }.join('; ')}" if @escalations.any?
      @log.puts "Deferred: #{@deferred.map(&:id).join(', ')}" if @deferred.any?
      @log.puts "#{@failures.size} step(s) still failing: #{@failures.map(&:first).join(', ')}" if @failures.any?
      @out
    end

    # The lines the current set of tests accounts for: test code for every
    # included or folded test, library code only for tests whose footprint
    # has been admitted (every step's own test; a folded test once the code
    # grew past it).
    def union_now
      union = Hash.new { |h, k| h[k] = Set.new }
      (@included + @folded.values).each do |t|
        full = @full_ids.include?(t.id)
        t.lines.each { |f, ls| union[f].merge(ls) if full || @project.test_file?(f) }
      end
      union
    end

    # Slice every file that should exist at this point. Iterates because what
    # is referenced depends on what is kept, and vice versa.
    def slice_all(union)
      referenced = @forced.dup
      methods = Set.new
      whole = Set.new
      used = Set.new
      missing = Set.new
      outputs = {}
      kept = nil
      MAX_PASSES.times do
        present = present_files(union, referenced)
        # A file can be judged present and then have nothing to say. Requires
        # must point at files that actually exist, so after the first pass
        # they are checked against what was really kept.
        exists = kept ? (present & kept) | present.select { |f| !outputs.key?(f) && !kept.include?(f) && union[f].any? }.to_set : present
        new_outputs = {}
        present.each do |f|
          case Slicer.parseable?(source(f)) ? @levels[f] : :full
          when :full
            new_outputs[f] = Comments.strip(source(f))
            next
          when :structure
            refs = EVERYTHING
          else
            refs = referenced
          end
          refs = EVERYTHING if @structural_now.include?(f)
          res = Slicer.new(@project, f, source(f), runtime_lines: union[f], present_files: exists,
                           referenced: refs, referenced_methods: methods, whole_classes: whole,
                           used_methods: refs.equal?(EVERYTHING) ? nil : used, missing_methods: missing,
                           load_lines: @record.baseline[f] || Set.new,
                           load_counts: @record.baseline_counts[f] || {}).slice
          text = Comments.strip(res.text)
          # A file stays if a test ran code in it, if it was forced, or if what
          # survived slicing still defines something.
          keep = union[f].any? || res.substantive || @project.test_file?(f) || @levels[f] != :sliced ||
                 @structural_now.include?(f) || Slicer.defined_constants(text).any? ||
                 (Slicer.declared_constants(text) & refs).any? # an empty module someone mixes in
          next unless keep
          new_outputs[f] = text
        end
        drop_hollow(new_outputs)
        refs = new_outputs.values.map { |t| Slicer.referenced_constants(t) }.reduce(Set.new, :|)
        meths = new_outputs.values.map { |t| Slicer.referenced_methods(t, defined: project_defined_methods) }.reduce(Set.new, :|)
        wholes = new_outputs.values.map { |t| Slicer.whole_classes(t) }.reduce(Set.new, :|)
        uses = new_outputs.values.map { |t| Slicer.used_methods(t) }.reduce(Set.new, :|)
        kept_defined = new_outputs.values.map { |t| Slicer.defined_methods(t) }.reduce(Set.new, :|)
        gone = project_defined_methods - kept_defined
        changed = new_outputs != outputs || refs != referenced || meths != methods || wholes != whole || uses != used || gone != missing
        used = uses
        missing = gone
        outputs = new_outputs
        kept = outputs.keys.to_set
        referenced = refs | @forced
        methods = meths
        whole = wholes
        break unless changed
      end
      outputs
    end

    private

    # An output that is nothing but `module Slop; end` exists only to satisfy
    # a require. Leave it out when every constant it declares is defined with
    # content elsewhere; the next pass drops the require too. An empty module
    # nothing else defines (a mixin with no methods yet) stays.
    def drop_hollow(outputs)
      defined = outputs.values.map { |t| Slicer.defined_constants(t) }.reduce(Set.new, :|)
      outputs.delete_if do |f, text|
        next false if @project.test_file?(f) || @levels[f] != :sliced
        Slicer.hollow?(text) && Slicer.declared_constants(text).subset?(defined - Slicer.defined_constants(text))
      end
    end

    # Which Ruby files exist at this step, before slicing.
    def present_files(union, referenced)
      @structural_now = Set.new
      present = union.keys.select { |f| union[f].any? }.to_set
      present.merge(@levels.keys.select { |f| @levels[f] != :sliced })
      loop do
        added = @record.loaded_files.select do |f|
          next false if present.include?(f)
          (Slicer.parseable?(source(f)) && (Slicer.defined_constants(source(f)) & referenced).any?) ||
            present.any? { |p| requires(p).include?(f) }
        end
        added += orphans(present)
        break if added.empty?
        present.merge(added)
      end
      present
    end

    # A library file nothing present requires will never load. Bring in the
    # file that required it when the suite really ran, as bare structure.
    def orphans(present)
      present.each_with_object([]) do |f, add|
        next if @project.test_file?(f) || present.any? { |p| p != f && requires(p).include?(f) }
        loader = recorded_requirers(f).find { |r| !present.include?(r) }
        next unless loader
        @structural_now << loader
        add << loader
      end
    end

    def recorded_requirers(file)
      @recorded ||= begin
        graph = Hash.new { |h, k| h[k] = [] }
        @record.require_edges.each do |from, method, arg|
          target = @project.resolve_require(method, arg, from)
          graph[target] << from if target && target != from
        end
        graph
      end
      @recorded[file]
    end

    # Files +file+ requires, statically. Dynamic requires the probe saw are
    # only used to find a loader for orphans; see #recorded_requirers.
    def requires(file)
      @requires ||= {}
      @requires[file] ||= begin
        found = Set.new
        Slicer.walk(Slicer.parseable?(source(file)) ? Slicer.parse(source(file)) : nil) do |n|
          next unless n.type == :send && n.children[0].nil? && %i[require require_relative].include?(n.children[1])
          arg = n.children[2]
          next unless arg.is_a?(Parser::AST::Node) && arg.type == :str
          t = @project.resolve_require(n.children[1], arg.children[0], file)
          found << t if t
        end
        found
      end
    end

    def source(f) = @sources[f] ||= @project.read(f)

    # HINDSIGHT_TRACE=1 prints how long each phase of a step takes.
    def timed(label)
      return yield unless ENV["HINDSIGHT_TRACE"]
      t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      @log.puts format("    %-14s %6.2fs", label, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t)
      result
    end

    # Every method name defined anywhere in the project's own Ruby.
    def project_defined_methods
      @project_defined_methods ||= @project.ruby_files
        .select { |f| Slicer.parseable?(source(f)) }
        .map { |f| Slicer.defined_methods(source(f)) }.reduce(Set.new, :|)
    end

    # Spreads commit dates across the original project's real lifetime, in
    # proportion to lines added, so the log reads like a history.
    class Clock
      def initialize(project, steps)
        first, = Open3.capture2("git", "-C", project.root, "log", "--reverse", "--format=%at")
        last, = Open3.capture2("git", "-C", project.root, "log", "-1", "--format=%at")
        @start = first.lines.first.to_i
        @finish = last.strip.to_i
        @start = @finish - 365 * 86_400 if @start.zero? || @start >= @finish
        @total = nil
        @steps = [steps, 1].max
        @done = 0
        @now = @start
      end

      def start = fmt(@start)
      def finish = fmt(@finish)
      def fmt(t) = Time.at(t).utc.strftime("%Y-%m-%dT%H:%M:%S +0000")

      def tick(sizes, previous)
        added = sizes.sum { |f, s| [s - (previous[f] || 0), 0].max } + 5
        @done += 1
        # Advance by a share of the remaining span weighted toward step size.
        share = (@finish - @now) * (1.0 / [(@steps - @done + 1), 1].max) * (0.5 + [added, 60].min / 60.0)
        @now = [@now + share.to_i + 3600, @finish - 3600].min
        fmt(@now)
      end
    end

    # ----- folding -------------------------------------------------------

    # A test that already passes against this step's code was not what drove
    # it; it is another example of the same behaviour and belongs in this
    # commit. Try every pending test against the current library with all
    # their test code present, and return those that pass.
    def fold_passing(union, pending)
      trial = Hash.new { |h, k| h[k] = Set.new }
      union.each { |f, ls| trial[f] = ls.dup }
      pending.each { |t| t.lines.each { |f, ls| trial[f].merge(ls) if @project.test_file?(f) } }
      trial_outputs = slice_all(trial)
      # Library files exactly as committed; only the test files are richer.
      committed = slice_all(union)
      tree = committed.merge(trial_outputs.select { |f, _| @project.test_file?(f) })
      sync(tree)
      # One run per test file, in parallel, each with a short timeout: a
      # pending test that loops forever in this tree must not stall the step.
      # A file that timed out recently loops forever in this tree; leave it
      # out for a while, doubling the wait each time it happens again.
      @fold_skip ||= {}
      counts = pending.group_by(&:file).transform_values(&:size)
      files = counts.keys.reject { |f| (@fold_skip[f] || 0) > @step_now }
      results = parallel_map(files) do |f|
        out, status, rec = run_with_probe(only_file: f, timeout: fold_timeout(counts[f]))
        if status.nil? && out.include?("timed out")
          @fold_backoff ||= Hash.new(1)
          @fold_skip[f] = @step_now + @fold_backoff[f]
          @fold_backoff[f] = [@fold_backoff[f] * 2, MAX_FOLD_BACKOFF].min
          @log.puts "    fold: #{f} timed out; skipping it for #{@fold_skip[f] - @step_now} step(s)" if ENV["HINDSIGHT_TRACE"]
        end
        rec
      end.compact
      tests = results.flat_map(&:tests)
      passed = tests.select(&:passed).map(&:id).to_set
      @red = tests.reject(&:passed).to_h { |t| [t.id, true] }
      pending.select { |t| passed.include?(t.id) }
    ensure
      sync(committed) if committed
    end

    FOLD_TIMEOUT = 15
    VERIFY_TIMEOUT = 120
    MAX_FOLD_BACKOFF = 8
    TEST_TIMEOUT = 10 # seconds per test inside a probe run

    # A fold run's budget scales with the file: a few hundred tests all
    # exercising error paths in a partial tree take a while, and that is not
    # a hang. Also scaled by how long verification takes here.
    def fold_timeout(tests_in_file)
      per_test = [(@last_verify_seconds || 0) / [@included.size, 1].max, 0.05].max
      [FOLD_TIMEOUT + per_test * 10 * tests_in_file, FOLD_TIMEOUT].max.clamp(FOLD_TIMEOUT, 240)
    end

    def parallel_map(items, workers: Etc.nprocessors)
      queue = Queue.new
      items.each_with_index { |x, i| queue << [x, i] }
      out = Array.new(items.size)
      Array.new([workers, items.size].min) do
        Thread.new do
          while (job = (queue.pop(true) rescue nil))
            out[job[1]] = yield(job[0])
          end
        end
      end.each(&:join)
      out
    end

    # Run the suite in the output directory under the probe.
    # Returns [output, status, record_or_nil].
    def run_with_probe(lenient: true, only_file: nil, timeout: VERIFY_TIMEOUT)
      Dir.mktmpdir("hindsight") do |tmp|
        out = File.join(tmp, "run.json")
        env = { "HINDSIGHT_ROOT" => @out, "HINDSIGHT_OUT" => out, "HINDSIGHT_TEST_TIMEOUT" => TEST_TIMEOUT.to_s }
        env["HINDSIGHT_LENIENT"] = "1" if lenient
        env["HINDSIGHT_ONLY_FILE"] = only_file if only_file
        output, status = Project.run_in(@out, @test_command, env: env, rubyopt: "-I#{Recorder::LIB} -rhindsight/probe", timeout: timeout)
        record = File.exist?(out) ? (Record.load(out) rescue nil) : nil
        [output, status, record]
      end
    end

    # ----- escalation ----------------------------------------------------

    # Try progressively more generous slicing until the step goes green.
    # Returns [ok, escalations_made, outputs].
    def escalate(n, test, pending)
      made = []
      last_log = read_log(n)
      candidates = candidate_files(last_log, test)
      green = lambda do |label|
        outputs = slice_all(union_now)
        sync(outputs)
        verify(n, test, quiet: true, label: label) ? outputs : nil
      end
      succeed = lambda do |outputs|
        @failures.reject! { |fn, _| fn == n }
        [true, made, outputs]
      end

      # Zeroth rung: a test folded into an earlier step now fails because the
      # code has grown around it. Give it the lines it recorded.
      broken = @last_failures.filter_map { |id| @folded[id] }
      if broken.any?
        broken.each { |t| @full_ids << t.id }
        if (outputs = green.call("folded"))
          broken.each { |t| made << [t.description[0, 60], :footprint]; @escalations << [n, t.id, :footprint] }
          return succeed.call(outputs)
        end
      end

      # First rung: the recorded footprint may be missing lazily initialised
      # code another test paid for. Re-record this test alone and merge.
      if isolate!(test) && (outputs = green.call("isolated"))
        made << ["#{test.file}:#{test.line}", :isolated]
        @escalations << [n, test.id, :isolated]
        return succeed.call(outputs)
      end

      # One class at a time: something looked a class up by name
      # (`const_defined?`), so try each class the suspect files declare.
      tried = 0
      candidates.each do |f|
        break if tried >= MAX_CLASS_ATTEMPTS
        next unless @levels[f] == :sliced && Slicer.parseable?(source(f))
        already = outputs_declare(f)
        (Slicer.declared_constants(source(f)) | Slicer.defined_constants(source(f))).subtract(already).subtract(@forced).each do |name|
          break if tried >= MAX_CLASS_ATTEMPTS
          tried += 1
          @forced << name
          if (outputs = green.call("class-#{name}"))
            made << [name, :class]
            @escalations << [n, name, :class]
            return succeed.call(outputs)
          end
          @forced.delete(name)
        end
      end

      # One file at a time, most suspicious first; every file as structure
      # before any file in full, so the smallest fix wins.
      LEVELS.drop(1).each do |level|
        candidates.each do |f|
          next if LEVELS.index(level) <= LEVELS.index(@levels[f]) || !allowed_level?(f, level)
          saved = @levels[f]
          @levels[f] = level
          if (outputs = green.call("#{level}-#{f.tr('/', '_')}"))
            made << [f, level]
            @escalations << [n, f, level]
            return succeed.call(outputs)
          end
          @levels[f] = saved
        end
      end

      # Un-fold: tests folded earlier that fail now go back to the queue to
      # be tried at a step of their own.
      broken = @last_failures.filter_map { |id| @folded[id] }
      if broken.any?
        broken.each { |t| @folded.delete(t.id); @full_ids.delete(t.id); pending << t }
        if (outputs = green.call("unfolded"))
          broken.each { |t| made << [t.description[0, 60], :unfold]; @escalations << [n, t.id, :unfold] }
          return succeed.call(outputs)
        end
      end

      # Everything the suite loaded, as structure.
      changed = @record.loaded_files.select { |f| @levels[f] == :sliced }
      if changed.any?
        changed.each { |f| @levels[f] = :structure }
        if (outputs = green.call("all-structure"))
          changed.each { |f| made << [f, :structure]; @escalations << [n, f, :structure] }
          return succeed.call(outputs)
        end
        changed.each { |f| @levels[f] = :sliced }
      end

      outputs = slice_all(union_now)
      sync(outputs)
      [false, made, outputs]
    end

    # Returns true when isolation added lines to the test's footprint.
    def isolate!(test)
      return false if @isolated&.include?(test.id)
      (@isolated ||= Set.new) << test.id
      Dir.mktmpdir("hindsight") do |tmp|
        rec = Recorder.record(@project, @test_command, out: File.join(tmp, "one.json"), only: test.id).restrict_to(@project.files)
        alone = rec.tests.find { |t| t.id == test.id } or return false
        added = false
        alone.lines.each do |f, ls|
          fresh = ls - (test.lines[f] || Set.new)
          next if fresh.empty?
          added = true
          test.lines[f] = (test.lines[f] || Set.new) | fresh
        end
        added
      end
    rescue Error
      false
    end

    MAX_CANDIDATES = 15
    MAX_CLASS_ATTEMPTS = 40

    # Classes the current output for +f+ already declares.
    def outputs_declare(f)
      path = File.join(@out, f)
      File.exist?(path) ? Slicer.declared_constants(File.read(path)) : Set.new
    end

    # Files to suspect, in order: those named in the failure output, those
    # defining a constant the output names, those the failing test itself
    # touched, then the rest of the library. Test files are never escalated
    # to full, since that would add every test in the file at once.
    def candidate_files(log, test)
      loaded = @record.loaded_files
      named = loaded.select { |f| log.include?(f) }
      consts = log.scan(/(?:uninitialized constant|for (?:an instance of|class|module) |for nil)\s*([A-Z]\w*(?:::[A-Z]\w*)*)/).flatten
                  .flat_map { |c| c.split("::") }.map(&:to_sym).to_set
      defined_by = loaded.to_h { |f| [f, Slicer.parseable?(source(f)) ? Slicer.defined_constants(source(f)) : Set.new] }
      defining = loaded.select { |f| (defined_by[f] & consts).any? }
      # A constant no project file defines comes from a gem or the standard
      # library, required by some file that isn't present yet.
      undefined = consts - defined_by.values.reduce(Set.new, :|)
      providers = undefined.any? ? loaded.select { |f| !@written.include?(f) && external_requires?(f) } : []
      touched = test.lines.keys.select { |f| loaded.include?(f) }
      lib = loaded.reject { |f| @project.test_file?(f) }
      ((named + defining + providers + touched).uniq + lib).uniq.first(MAX_CANDIDATES + providers.size)
    end

    def external_requires?(file)
      return false unless Slicer.parseable?(source(file))
      found = false
      Slicer.walk(Slicer.parse(source(file))) do |n|
        next unless n.type == :send && n.children[0].nil? && n.children[1] == :require
        arg = n.children[2]
        next unless arg.is_a?(Parser::AST::Node) && arg.type == :str
        found ||= @project.resolve_require(:require, arg.children[0], file).nil?
      end
      found
    end

    def allowed_level?(f, level)
      !(level == :full && @project.test_file?(f))
    end

    # ----- filesystem ----------------------------------------------------

    def reset_repo
      FileUtils.rm_rf(@out)
      FileUtils.rm_rf(log_dir)
      FileUtils.mkdir_p(@out)
      git("init", "-q")
      git("config", "user.name", "Hindsight")
      git("config", "user.email", "hindsight@example.invalid")
      # Verification runs leave droppings; keep them out of the history.
      File.write(File.join(@out, ".git", "info", "exclude"), %w[coverage/ tmp/ log/ pkg/ .bundle/ .rspec_status .byebug_history].join("\n") + "\n")
      share_bundle_config
    end

    # If the target keeps its gems in a local path (`bundle config path
    # vendor/bundle`), point the output tree at the same gems so `bundle
    # exec` works there too. Lives under .bundle/, which the history ignores.
    def share_bundle_config
      config = File.join(@project.root, ".bundle", "config")
      return unless File.exist?(config)
      text = File.read(config).gsub(/^(BUNDLE_PATH:\s*)"?([^"\n]+)"?$/) do
        path = Regexp.last_match(2)
        "#{Regexp.last_match(1)}\"#{File.expand_path(path, @project.root)}\""
      end
      FileUtils.mkdir_p(File.join(@out, ".bundle"))
      File.write(File.join(@out, ".bundle", "config"), text)
    end

    def write_scaffold
      @project.scaffold_files(except: @record.loaded_files).each do |f|
        if @project.ruby_file?(f) && Slicer.parseable?(source(f))
          dest = File.join(@out, f)
          FileUtils.mkdir_p(File.dirname(dest))
          File.write(dest, Comments.strip(source(f)))
        else
          copy(f)
        end
      end
    end

    def write_everything
      @project.files.each do |f|
        if @project.ruby_file?(f) && Slicer.parseable?(source(f))
          dest = File.join(@out, f)
          FileUtils.mkdir_p(File.dirname(dest))
          File.write(dest, Comments.strip(source(f)))
        else
          copy(f)
        end
      end
    end

    def copy(f)
      dest = File.join(@out, f)
      FileUtils.mkdir_p(File.dirname(dest))
      FileUtils.cp(File.join(@project.root, f), dest)
    end

    # Make the Ruby files in the output match +outputs+ exactly.
    def sync(outputs)
      (@written - outputs.keys).each { |f| FileUtils.rm_f(File.join(@out, f)) }
      outputs.each do |f, text|
        dest = File.join(@out, f)
        FileUtils.mkdir_p(File.dirname(dest))
        File.write(dest, text) unless File.exist?(dest) && File.read(dest) == text
      end
      @written = outputs.keys.to_set
    end

    def git(*args, env: {})
      out, status = Open3.capture2e(env, "git", "-C", @out, *args)
      raise Error, "git #{args.first} failed: #{out}" unless status.success?
      out
    end

    def commit(subject, body, date: nil)
      git("add", "-A")
      env = date ? { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date } : {}
      git("commit", "-q", "--allow-empty", "-m", subject, "-m", body, env: env)
    end

    # "FooTest#test_does_a_thing" reads better as "Foo: does a thing".
    # Spec-style descriptions are already prose and pass through.
    def subject_for(test)
      humanise(test.description)
    end

    def humanise(desc)
      if (m = desc.match(/\A([\w:]+)#test_(?:\d+_)?(.+)\z/))
        "#{m[1].sub(/Test\z/, '')}: #{m[2].tr('_', ' ')}"
      else
        desc
      end
    end

    def step_body(n, test, sizes, previous, ok, escalated, folded = [], story = [], was_red = false)
      deltas = sizes.map { |f, s| [f, s - (previous[f] || 0)] }.reject { |_, d| d.zero? }
      prod = deltas.reject { |f, _| @project.test_file?(f) }.sum(&:last)
      lines = []
      lines.concat(story) << "" if story.any?
      lines << "Step #{n}. #{prod} line#{'s' unless prod == 1} of production code."
      lines << "Test: #{test.file}:#{test.line}"
      unless folded.empty?
        lines << "" << "Also passing now:"
        folded.each { |t| lines << "  #{humanise(t.description)} (#{t.file}:#{t.line})" }
      end
      unless deltas.empty?
        lines << ""
        lines << "Changed:"
        deltas.sort.each { |f, d| lines << format("  %-40s %+d", f, d) }
      end
      unless ok.nil?
        before = was_red ? "red before, " : ""
        lines << "" << "Verification: #{before}#{ok ? 'green' : 'RED'}#{' after' unless before.empty?}"
        escalated.each do |f, level|
          lines << case level
                   when :class then "  needed class #{f}"
                   when :footprint then "  needed the code recorded for: #{f}"
                   when :unfold then "  no longer passes, retried later: #{f}"
                   else "  needed #{f} as #{level}"
                   end
        end
      end
      lines.join("\n")
    end

    # ----- verification --------------------------------------------------

    def log_dir = File.join(File.dirname(@out), "verify")

    # Run the suite in the output tree. Green means every test passed. The
    # probe rides along so we know which tests failed, for the ladder.
    def verify(n, test, quiet: false, label: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, status, results = run_with_probe(lenient: false)
      @last_verify_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      @last_failures = results ? results.tests.reject(&:passed).map(&:id) : []
      return true if status&.success?
      @failures << [n, test.id] unless quiet || @failures.any? { |fn, _| fn == n }
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, format("step-%04d%s.log", n, label ? "-#{label}" : "")), "#{test.id}\n\n#{out}")
      false
    end

    def read_log(n)
      path = File.join(log_dir, format("step-%04d.log", n))
      File.exist?(path) ? File.read(path) : ""
    end

    def progress(n, remaining, test, ok, escalated, folded)
      mark = ok.nil? ? " " : (ok ? "✓" : "✗")
      note = escalated.map { |f, l| " [#{f} -> #{l}]" }.join
      note += " (+#{folded.size} folded)" unless folded.empty?
      @log.puts format("%s %4d  %4d left  %s%s", mark, n, remaining, test.description[0, 80], note)
    end
  end
end
