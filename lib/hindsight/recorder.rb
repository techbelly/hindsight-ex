# frozen_string_literal: true

require "tmpdir"
require "etc"

module Hindsight
  # Runs the target's test suite with the probe loaded and returns the Record.
  module Recorder
    LIB = File.expand_path("..", __dir__)

    # Record the whole suite in one process. With +only+, run just that test.
    def self.record(project, test_command, out:, only: nil, log: nil)
      env = { "HINDSIGHT_ROOT" => project.root, "HINDSIGHT_OUT" => out }
      env["HINDSIGHT_ONLY"] = only if only
      output, status = Project.run_in(project.root, test_command, env: env, rubyopt: "-I#{LIB} -rhindsight/probe")
      log&.puts(output.lines.last(3).join)
      raise Error, "test command failed while recording:\n#{output.lines.last(30).join}" unless status.success?
      Record.load(out)
    end

    # Record every test in its own process, so each footprint is exactly what
    # that test needs, including any lazy initialisation another test would
    # otherwise have paid for. One whole-suite run first supplies the
    # load-time baseline and the require graph. Runs are independent, so they
    # go in parallel.
    def self.record_isolated(project, test_command, out:, log: nil, workers: Etc.nprocessors)
      Dir.mktmpdir("hindsight") do |tmp|
        whole = record(project, test_command, out: File.join(tmp, "all.json"), log: log)
        queue = Queue.new
        whole.tests.each_with_index { |t, i| queue << [t, i] }
        results = Array.new(whole.tests.size)
        done = 0
        mutex = Mutex.new
        not_alone = []
        threads = Array.new([workers, whole.tests.size].min) do
          Thread.new do
            while (job = (queue.pop(true) rescue nil))
              t, i = job
              one = begin
                record(project, test_command, out: File.join(tmp, "one-#{i}.json"), only: t.id)
                      .tests.find { |x| x.id == t.id }
              rescue Error
                nil
              end
              mutex.synchronize do
                if one&.passed
                  results[i] = one
                else
                  results[i] = t # keep the whole-run footprint for a test that can't run alone
                  not_alone << t.id
                end
                done += 1
                log&.print("\r  isolating #{done}/#{whole.tests.size}")
              end
            end
          end
        end
        threads.each(&:join)
        log&.puts
        log&.puts("  #{not_alone.size} test(s) do not pass alone; used their whole-run footprint: #{not_alone.first(5).join(', ')}#{'...' if not_alone.size > 5}") if not_alone.any?
        whole.replace_tests(results)
        whole.save(out)
        whole
      end
    end
  end
end
