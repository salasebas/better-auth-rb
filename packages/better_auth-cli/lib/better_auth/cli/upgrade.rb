# frozen_string_literal: true

require "optparse"
require_relative "errors"
require_relative "framework_detect"

module BetterAuth
  class CLI
    module Upgrade
      BETTER_AUTH_GEM_PATTERN = /
        \bgem\s+["'](better_auth(?:-[a-z0-9_]+)?)["']
      /ix

      module_function

      def run(argv, stdout: $stdout, stderr: $stderr)
        options = parse_options(argv)
        gems = gems_from_gemfile(options.fetch(:cwd))
        raise CLI::Error, "No Gemfile found under #{options[:cwd]}" if gems.empty?

        command = "bundle update #{gems.join(" ")}"
        if options[:yes]
          stdout.puts command
          stdout.puts "Run the command above in your project to upgrade Better Auth gems."
        else
          stdout.puts "Planned upgrade (dry run):"
          gems.each { |gem| stdout.puts "  - #{gem}" }
          stdout.puts
          stdout.puts "Run with --yes to print the bundle update command:"
          stdout.puts "  better-auth upgrade --cwd . --yes"
          stdout.puts
          stdout.puts "Suggested command:"
          stdout.puts "  #{command}"
        end
        0
      rescue CLI::Error => error
        stderr.puts error.message
        1
      end

      def parse_options(argv)
        options = {}
        OptionParser.new do |parser|
          parser.on("--cwd PATH") { |value| options[:cwd] = File.expand_path(value) }
          parser.on("--yes", "-y") { options[:yes] = true }
        end.parse!(argv)

        unless options[:cwd]
          raise CLI::Error, Errors.missing_option("upgrade", "--cwd", [
            "Example: better-auth upgrade --cwd . --yes"
          ])
        end

        unless File.directory?(options[:cwd])
          raise CLI::Error, "--cwd is not a directory: #{options[:cwd]}"
        end

        options[:yes] ||= false
        options
      end

      def gems_from_gemfile(cwd)
        path = File.join(cwd, "Gemfile")
        return [] unless File.exist?(path)

        File.read(path).scan(BETTER_AUTH_GEM_PATTERN).flatten.uniq.sort
      end
    end
  end
end
