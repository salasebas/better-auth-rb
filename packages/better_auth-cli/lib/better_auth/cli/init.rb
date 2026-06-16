# frozen_string_literal: true

require "open3"
require "optparse"
require_relative "errors"
require_relative "framework_detect"
require_relative "rack_scaffold"

module BetterAuth
  class CLI
    class Init
      FRAMEWORK_GEMS = {
        "rails" => "better_auth-rails",
        "hanami" => "better_auth-hanami",
        "sinatra" => "better_auth-sinatra",
        "roda" => "better_auth-roda"
      }.freeze

      class << self
        def run(argv, stdout: $stdout, stderr: $stderr, command_runner: nil)
          new(stdout: stdout, stderr: stderr, command_runner: command_runner || default_command_runner).run(argv)
        end

        def default_command_runner
          lambda do |cwd, *args|
            stdout, stderr, status = Open3.capture3(*args, chdir: cwd)
            [status.exitstatus, stdout, stderr]
          end
        end
      end

      def initialize(stdout:, stderr:, command_runner:)
        @stdout = stdout
        @stderr = stderr
        @command_runner = command_runner
      end

      def run(argv)
        options = parse_options(argv)
        framework = resolve_framework!(options)
        dispatch_framework(framework, options)
      rescue CLI::Error => error
        stderr.puts error.message
        1
      end

      private

      attr_reader :stdout, :stderr, :command_runner

      def parse_options(argv)
        options = {plugins: []}
        OptionParser.new do |parser|
          parser.on("--cwd PATH") { |value| options[:cwd] = File.expand_path(value) }
          parser.on("--framework NAME") { |value| options[:framework] = value.to_s.downcase }
          parser.on("--detect-framework") { options[:detect_framework] = true }
          parser.on("--force") { options[:force] = true }
          parser.on("--secret VALUE") { |value| options[:secret] = value }
          parser.on("--base-url URL") { |value| options[:base_url] = value }
          parser.on("--database-dialect DIALECT") { |value| options[:database_dialect] = value }
          parser.on("--write-env-example") { options[:write_env_example] = true }
          parser.on("--plugin ID") { |value| options[:plugins] << value.to_s }
        end.parse!(argv)

        require_cwd!(options)
        validate_optional_flags!(options)
        validate_framework_flags!(options)
        options[:force] ||= false
        options
      end

      def require_cwd!(options)
        return if options[:cwd]

        raise CLI::Error, Errors.missing_option("init", "--cwd", [
          "Pass --framework rails|hanami|sinatra|roda|rack or --detect-framework.",
          "Example: better-auth init --cwd . --framework rack"
        ])
      end

      def validate_optional_flags!(options)
        %i[secret base_url database_dialect].each do |key|
          next unless options.key?(key) && options[key].to_s.strip.empty?

          flag = key.to_s.tr("_", "-")
          raise CLI::Error, Errors.missing_option("init", "--#{flag}", [
            "Example: better-auth init --cwd . --framework rack --#{flag} <value>"
          ])
        end
      end

      def validate_framework_flags!(options)
        if options[:framework] && options[:detect_framework]
          raise CLI::Error, "Pass only one of --framework or --detect-framework"
        end

        return if options[:framework] || options[:detect_framework]

        raise CLI::Error, <<~MSG.strip
          init requires --framework or --detect-framework.

          Supported frameworks: #{FrameworkDetect::SUPPORTED.join(", ")}
          Example: better-auth init --cwd . --framework rails
          Example: better-auth init --cwd . --detect-framework
        MSG
      end

      def resolve_framework!(options)
        if options[:framework]
          framework = options[:framework]
          unless FrameworkDetect::SUPPORTED.include?(framework)
            raise CLI::Error, "Unsupported framework #{framework.inspect}. Pass one of: #{FrameworkDetect::SUPPORTED.join(", ")}"
          end
          return framework
        end

        result = FrameworkDetect.detect(options[:cwd])
        if result[:ambiguous].any?
          raise CLI::Error, <<~MSG.strip
            Ambiguous framework detection: #{result[:ambiguous].join(", ")}.

            Pass --framework <name> to choose explicitly.
          MSG
        end

        unless result[:framework]
          raise CLI::Error, <<~MSG.strip
            Could not detect a supported Ruby framework under #{options[:cwd]}.

            Pass --framework rails|hanami|sinatra|roda|rack
          MSG
        end

        result[:framework]
      end

      def dispatch_framework(framework, options)
        case framework
        when "rack"
          RackScaffold.write(
            cwd: options[:cwd],
            force: options[:force],
            database_dialect: options[:database_dialect],
            plugins: options[:plugins],
            write_env_example: options[:write_env_example],
            stdout: stdout
          )
          0
        else
          require_framework_gem!(framework, options[:cwd])
          run_framework_install(framework, options)
        end
      end

      def require_framework_gem!(framework, cwd)
        gem_name = FRAMEWORK_GEMS.fetch(framework)
        return if FrameworkDetect.gem_in_gemfile?(cwd, gem_name)

        raise CLI::Error, <<~MSG.strip
          #{gem_name} is not listed in the Gemfile under #{cwd}.

          Add `gem "#{gem_name}"` to your Gemfile, run bundle install, then retry.
          Example: better-auth init --cwd . --framework #{framework}
        MSG
      end

      def run_framework_install(framework, options)
        cwd = options[:cwd]
        force_flag = options[:force] ? ["--force"] : []

        case framework
        when "rails"
          status, out, err = command_runner.call(cwd, "bundle", "exec", "rails", "generate", "better_auth:install", *force_flag)
        when "hanami"
          status, out, err = run_hanami_install(cwd)
        when "sinatra", "roda"
          status, out, err = command_runner.call(cwd, "bundle", "exec", "rake", "better_auth:install")
        else
          raise CLI::Error, "Unsupported framework #{framework.inspect}"
        end

        stdout.print(out)
        stderr.print(err)
        raise CLI::Error, "Framework install failed with exit status #{status}" unless status.zero?

        0
      end

      def run_hanami_install(cwd)
        status, out, err = command_runner.call(cwd, "bundle", "exec", "rake", "better_auth:init")
        return [status, out, err] if status.zero?

        script = <<~RUBY
          require "better_auth/hanami/generators/install_generator"
          BetterAuth::Hanami::Generators::InstallGenerator.new(destination_root: #{cwd.inspect}).run
        RUBY
        command_runner.call(cwd, "bundle", "exec", "ruby", "-e", script)
      end
    end
  end
end
