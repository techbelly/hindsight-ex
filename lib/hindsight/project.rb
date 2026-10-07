# frozen_string_literal: true

require "open3"

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
    def scaffold_files = files.reject { |f| ruby_file?(f) }

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
    def self.run_in(dir, command, env: {}, rubyopt: nil)
      runner = lambda do
        env = env.merge("RUBYOPT" => "#{rubyopt} #{ENV['RUBYOPT']}".strip) if rubyopt
        Open3.capture2e(env, command, chdir: dir)
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
