# frozen_string_literal: true

require "optparse"
require "fileutils"

module Hindsight
  class CLI
    USAGE = <<~TXT
      Usage: hindsight <command> <target-dir> [options]

      Commands:
        record   run the target's tests once, recording per-test coverage
        order    choose the order the tests would have been written in
        build    replay that order into a fresh git repository
        run      all three

      Options:
    TXT

    def self.start(argv) = new.run(argv)

    def run(argv)
      opts = { verify: false }
      parser = OptionParser.new do |o|
        o.banner = USAGE
        o.on("--test-cmd CMD", "command that runs the target's test suite") { |v| opts[:test_cmd] = v }
        o.on("--work DIR", "working directory for intermediate files (default: work/<name>)") { |v| opts[:work] = v }
        o.on("--out DIR", "where to build the repository (default: <work>/repo)") { |v| opts[:out] = v }
        o.on("--verify", "run the tests at every commit") { opts[:verify] = true }
        o.on("--limit N", Integer, "only build the first N steps") { |v| opts[:limit] = v }
        o.on("--fast", "record the whole suite in one process instead of one per test") { opts[:fast] = true }
      end
      rest = parser.parse(argv)
      command, target = rest
      abort(parser.help) unless command && target

      project = Project.new(target)
      work = File.expand_path(opts[:work] || File.join(__dir__, "../../work", project.name))
      FileUtils.mkdir_p(work)
      paths = {
        coverage: File.join(work, "coverage.json"),
        plan: File.join(work, "plan.json"),
        graph: File.join(work, "graph.dot"),
        repo: opts[:out] ? File.expand_path(opts[:out]) : File.join(work, "repo"),
      }
      test_cmd = opts[:test_cmd] || project.default_test_command

      case command
      when "record" then record(project, paths, test_cmd, opts)
      when "order" then order(project, paths)
      when "build" then build(project, paths, test_cmd, opts)
      when "run"
        record(project, paths, test_cmd, opts)
        order(project, paths)
        build(project, paths, test_cmd, opts)
      else abort(parser.help)
      end
    end

    private

    def record(project, paths, test_cmd, opts)
      $stderr.puts "Recording: #{test_cmd}#{opts[:fast] ? ' (one process)' : ' (one process per test)'}"
      rec = if opts[:fast]
        Recorder.record(project, test_cmd, out: paths[:coverage], log: $stderr)
      else
        Recorder.record_isolated(project, test_cmd, out: paths[:coverage], log: $stderr)
      end
      $stderr.puts "Recorded #{rec.tests.size} tests over #{rec.runtime_files.size} files -> #{paths[:coverage]}"
    end

    def order(project, paths)
      rec = Record.load(paths[:coverage]).restrict_to(project.files)
      steps = Orderer.new(rec, project).order
      Orderer.save(steps, paths[:plan])
      File.write(paths[:graph], Graph.dot(steps, rec))
      $stderr.puts "Ordered #{steps.size} tests -> #{paths[:plan]}"
    end

    def build(project, paths, test_cmd, opts)
      rec = Record.load(paths[:coverage]).restrict_to(project.files)
      steps = Orderer.load(paths[:plan])
      Builder.new(project: project, record: rec, steps: steps, out: paths[:repo],
                  test_command: test_cmd, verify: opts[:verify], limit: opts[:limit]).build
    end
  end
end
