# frozen_string_literal: true

require "open3"
require "set"

module Hindsight
  # The target project: where it is, which files it has, how to run its tests,
  # and how a `require` inside it resolves to one of its own files.
  class Project
    TEST_DIRS = %w[test spec features].freeze
    LOAD_DIRS = %w[lib test spec .].freeze

    attr_reader :root

    def initialize(root)
      @root = File.expand_path(root)
      raise Error, "no such directory: #{@root}" unless File.directory?(@root)
    end

    def name
      File.basename(root)
    end

    # Every file that belongs to the project, relative to root.
    def files
      @files ||= begin
        out, status = Open3.capture2("git", "-C", root, "ls-files", "-z")
        if status.success? && !out.empty?
          out.split("\0").select { |f| File.file?(File.join(root, f)) }
        else
          Dir.chdir(root) { Dir["**/*"].select { |f| File.file?(f) } }
        end
      end
    end

    def ruby_files = files.select { |f| ruby_file?(f) }

    # Files that exist before any test: everything that is not Ruby, plus the
    # Ruby that the build system itself loads (version files required by
    # gemspecs, and so on), followed transitively.
    def scaffold_files(except: [])
      files.reject { |f| ruby_file?(f) } + build_support_files(except: except)
    end

    BUILD_FILES = /(\A|\/)(Gemfile|Rakefile|.*\.gemspec)\z/

    # +except+: files the test suite loads; those belong to the story, and
    # the search does not continue through them.
    def build_support_files(except: [])
      skip = except.to_set
      found = Set.new
      queue = files.grep(BUILD_FILES)
      until queue.empty?
        f = queue.shift
        static_requires(f).each do |t|
          next if found.include?(t) || skip.include?(t)
          found << t
          queue << t
        end
      end
      found.to_a.sort
    end

    # Project files a file requires, from its source alone.
    def static_requires(file)
      src = read(file)
      found = []
      src.scan(/^\s*require(_relative)?\s*\(?\s*(['"])([^'"]+)\2/) do |rel, _q, arg|
        t = resolve_require(rel ? :require_relative : :require, arg, file)
        found << t if t
      end
      found
    rescue StandardError
      []
    end

    def ruby_file?(path) = path.end_with?(".rb")

    def test_file?(path)
      TEST_DIRS.any? { |d| path.start_with?("#{d}/") }
    end

    def read(path) = File.read(File.join(root, path))

    # Resolve `require "x"` / `require_relative "x"` written in +from+ to a
    # project-relative path, or nil when it names something outside the project.
    def resolve_require(method, arg, from)
      candidates =
        if arg.start_with?("/")
          [arg]
        elsif method == :require_relative
          [File.expand_path(arg, File.join(root, File.dirname(from)))]
        else
          LOAD_DIRS.map { |d| File.expand_path(arg, File.join(root, d)) }
        end
      candidates.each do |abs|
        abs = "#{abs}.rb" unless abs.end_with?(".rb")
        next unless abs.start_with?("#{root}/")
        rel = abs.delete_prefix("#{root}/")
        return rel if files.include?(rel)
      end
      nil
    end

    # Run a command inside the project with none of our own Bundler
    # environment leaking into it. Returns [output, status].
    # A sliced tree can loop forever (a loop whose body was cut away), so
    # every run has a timeout; on expiry the whole process group is killed
    # and the status is nil.
    def self.run_in(dir, command, env: {}, rubyopt: nil, timeout: 120)
      runner = lambda do
        env = env.merge("RUBYOPT" => "#{rubyopt} #{ENV['RUBYOPT']}".strip) if rubyopt
        reader, writer = IO.pipe
        pid = Process.spawn(env, command, chdir: dir, pgroup: true, out: writer, err: writer)
        writer.close
        output = +""
        collector = Thread.new { output << reader.read }
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
        status = nil
        loop do
          _, status = Process.wait2(pid, Process::WNOHANG)
          break if status
          if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            Process.kill("KILL", -pid) rescue nil
            Process.wait2(pid) rescue nil
            output << "\nhindsight: timed out after #{timeout}s\n"
            break
          end
          sleep 0.05
        end
        collector.join
        reader.close
        [output, status]
      end
      defined?(Bundler) ? Bundler.with_unbundled_env(&runner) : runner.call
    end

    # A sensible default for projects we haven't been told how to test.
    def default_test_command
      if File.directory?(File.join(root, "spec"))
        "bundle exec rspec"
      else
        %q{ruby -Ilib -Itest -e 'Dir["test/**/*_test.rb"].sort.each { |f| require File.expand_path(f) }'}
      end
    end
  end
end
