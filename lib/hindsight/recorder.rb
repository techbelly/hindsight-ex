# frozen_string_literal: true

require "tmpdir"

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

    # Record every test in its own process, so each footprint includes any
    # lazy initialisation it relies on. Slower, but exact.
    def self.record_isolated(project, test_command, out:, log: nil)
      Dir.mktmpdir("hindsight") do |tmp|
        whole = record(project, test_command, out: File.join(tmp, "all.json"))
        tests = whole.tests.each_with_index.map do |t, i|
          log&.print("\r  isolating #{i + 1}/#{whole.tests.size}")
          rec = record(project, test_command, out: File.join(tmp, "one.json"), only: t.id)
          rec.tests.find { |x| x.id == t.id } || t
        end
        log&.puts
        whole.replace_tests(tests)
        whole.save(out)
        whole
      end
    end
  end
end
