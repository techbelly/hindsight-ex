# frozen_string_literal: true

require "fileutils"
require "open3"
require "json"
require "set"
require "tmpdir"

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
      @sources = {}
      @written = Set.new
    end

    def build
      reset_repo
      write_scaffold
      commit("Project scaffolding", "Build files, documentation and licences. No code yet.")

      union = Hash.new { |h, k| h[k] = Set.new }
      previous_sizes = {}
      @steps.each_with_index do |step, i|
        n = i + 1
        test = @record.test(step.id)
        test.lines.each { |f, ls| union[f].merge(ls) }
        outputs = slice_all(union)
        sync(outputs)
        ok = nil
        escalated = []
        if @verify
          ok = verify(n, test)
          unless ok
            ok, escalated, outputs = escalate(n, test, union)
          end
        end
        sizes = outputs.transform_values { |t| t.lines.size }
        commit(test.description, step_body(n, test, sizes, previous_sizes, ok, escalated))
        previous_sizes = sizes
        progress(n, test, step.gain, ok, escalated)
      end

      write_everything
      commit("Everything else", "Code no test reached, and files the test suite never loaded.")
      @log.puts "\nBuilt #{@steps.size + 2} commits in #{@out}"
      @log.puts "Escalations: #{@escalations.map { |n, f, l| "#{f} to #{l} at step #{n}" }.join('; ')}" if @escalations.any?
      @log.puts "#{@failures.size} step(s) still failing: #{@failures.map(&:first).join(', ')}" if @failures.any?
      @out
    end

    # Slice every file that should exist at this point. Iterates because what
    # is referenced depends on what is kept, and vice versa.
    def slice_all(union)
      referenced = Set.new
      methods = Set.new
      whole = Set.new
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
            new_outputs[f] = source(f)
            next
          when :structure
            refs = EVERYTHING
          else
            refs = referenced
          end
          refs = EVERYTHING if @structural_now.include?(f)
          res = Slicer.new(@project, f, source(f), runtime_lines: union[f], present_files: exists,
                           referenced: refs, referenced_methods: methods, whole_classes: whole,
                           load_lines: @record.baseline[f] || Set.new).slice
          keep = union[f].any? || res.substantive || @project.test_file?(f) || @levels[f] != :sliced ||
                 @structural_now.include?(f) ||
                 (Slicer.parseable?(source(f)) && (Slicer.defined_constants(source(f)) & referenced).any?)
          new_outputs[f] = res.text if keep
        end
        refs = new_outputs.values.map { |t| Slicer.referenced_constants(t) }.reduce(Set.new, :|)
        meths = new_outputs.values.map { |t| Slicer.referenced_methods(t) }.reduce(Set.new, :|)
        wholes = new_outputs.values.map { |t| Slicer.whole_classes(t) }.reduce(Set.new, :|)
        changed = new_outputs != outputs || refs != referenced || meths != methods || wholes != whole
        outputs = new_outputs
        kept = outputs.keys.to_set
        referenced = refs
        methods = meths
        whole = wholes
        break unless changed
      end
      outputs
    end

    private

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

    # ----- escalation ----------------------------------------------------

    # Try progressively more generous slicing until the step goes green.
    # Returns [ok, escalations_made, outputs].
    def escalate(n, test, union)
      made = []
      last_log = read_log(n)
      candidates = candidate_files(last_log, test)

      # First rung: the recorded footprint may be missing lazily initialised
      # code another test paid for. Re-record this test alone and merge.
      if isolate!(test, union)
        outputs = slice_all(union)
        sync(outputs)
        if verify(n, test, quiet: true, label: "isolated")
          made << ["#{test.file}:#{test.line}", :isolated]
          @escalations << [n, test.id, :isolated]
          @failures.reject! { |fn, _| fn == n }
          return [true, made, outputs]
        end
      end

      # One file at a time, most suspicious first; every file as structure
      # before any file in full, so the smallest fix wins.
      LEVELS.drop(1).each do |level|
        candidates.each do |f|
          next if LEVELS.index(level) <= LEVELS.index(@levels[f]) || !allowed_level?(f, level)
          saved = @levels[f]
          @levels[f] = level
          outputs = slice_all(union)
          sync(outputs)
          if verify(n, test, quiet: true, label: "#{level}-#{f.tr('/', '_')}")
            made << [f, level]
            @escalations << [n, f, level]
            @failures.reject! { |fn, _| fn == n }
            return [true, made, outputs]
          end
          @levels[f] = saved
        end
      end

      # Everything the suite loaded, as structure, then in full.
      LEVELS.drop(1).each do |level|
        changed = @record.loaded_files.reject { |f| LEVELS.index(@levels[f]) >= LEVELS.index(level) }
        next if changed.empty?
        saved = changed.to_h { |f| [f, @levels[f]] }
        changed.each { |f| @levels[f] = level }
        outputs = slice_all(union)
        sync(outputs)
        if verify(n, test, quiet: true, label: "all-#{level}")
          changed.each { |f| made << [f, level]; @escalations << [n, f, level] }
          @failures.reject! { |fn, _| fn == n }
          return [true, made, outputs]
        end
        saved.each { |f, l| @levels[f] = l }
      end

      outputs = slice_all(union)
      sync(outputs)
      [false, made, outputs]
    end

    # Returns true when isolation added lines to the union.
    def isolate!(test, union)
      return false if @isolated&.include?(test.id)
      (@isolated ||= Set.new) << test.id
      Dir.mktmpdir("hindsight") do |tmp|
        rec = Recorder.record(@project, @test_command, out: File.join(tmp, "one.json"), only: test.id)
        alone = rec.tests.find { |t| t.id == test.id } or return false
        added = false
        alone.lines.each do |f, ls|
          fresh = ls - union[f]
          next if fresh.empty?
          added = true
          union[f].merge(fresh)
          test.lines[f] = (test.lines[f] || Set.new) | fresh
        end
        added
      end
    rescue Error
      false
    end

    MAX_CANDIDATES = 15

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
    end

    def write_scaffold
      @project.scaffold_files.each { |f| copy(f) }
    end

    def write_everything
      @project.files.each { |f| copy(f) }
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

    def git(*args)
      out, status = Open3.capture2e("git", "-C", @out, *args)
      raise Error, "git #{args.first} failed: #{out}" unless status.success?
      out
    end

    def commit(subject, body)
      git("add", "-A")
      git("commit", "-q", "--allow-empty", "-m", subject, "-m", body)
    end

    def step_body(n, test, sizes, previous, ok, escalated)
      deltas = sizes.map { |f, s| [f, s - (previous[f] || 0)] }.reject { |_, d| d.zero? }
      prod = deltas.reject { |f, _| @project.test_file?(f) }.sum(&:last)
      lines = []
      lines << "Step #{n} of #{@steps.size}. #{prod} line#{'s' unless prod == 1} of production code."
      lines << "Test: #{test.file}:#{test.line}"
      unless deltas.empty?
        lines << ""
        lines << "Changed:"
        deltas.sort.each { |f, d| lines << format("  %-40s %+d", f, d) }
      end
      unless ok.nil?
        lines << "" << "Verification: #{ok ? 'green' : 'RED'}"
        escalated.each { |f, level| lines << "  needed #{f} as #{level}" }
      end
      lines.join("\n")
    end

    # ----- verification --------------------------------------------------

    def log_dir = File.join(File.dirname(@out), "verify")

    def verify(n, test, quiet: false, label: nil)
      out, status = Project.run_in(@out, @test_command)
      return true if status.success?
      @failures << [n, test.id] unless quiet || @failures.any? { |fn, _| fn == n }
      FileUtils.mkdir_p(log_dir)
      File.write(File.join(log_dir, format("step-%04d%s.log", n, label ? "-#{label}" : "")), "#{test.id}\n\n#{out}")
      false
    end

    def read_log(n)
      path = File.join(log_dir, format("step-%04d.log", n))
      File.exist?(path) ? File.read(path) : ""
    end

    def progress(n, test, gain, ok, escalated)
      mark = ok.nil? ? " " : (ok ? "✓" : "✗")
      note = escalated.map { |f, l| " [#{f} -> #{l}]" }.join
      @log.puts format("%s %3d/%-3d +%-4d %s%s", mark, n, @steps.size, gain, test.description[0, 80], note)
    end
  end
end
