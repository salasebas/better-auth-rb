# frozen_string_literal: true

module BetterAuth
  class CLI
    # Detects Ruby web frameworks under a project directory.
    #
    # `rack` is never auto-detected — generic Rack apps must pass
    # `--framework rack` explicitly because there are no reliable markers.
    module FrameworkDetect
      SUPPORTED = %w[rails hanami sinatra roda rack].freeze

      module_function

      def detect(cwd)
        matches = []
        matches << "rails" if rails?(cwd)
        matches << "hanami" if hanami?(cwd)
        matches << "sinatra" if sinatra?(cwd)
        matches << "roda" if roda?(cwd)

        unique = matches.uniq
        case unique.length
        when 0
          {framework: nil, ambiguous: []}
        when 1
          {framework: unique.first, ambiguous: []}
        else
          {framework: nil, ambiguous: unique.sort}
        end
      end

      def gemfile_content(cwd)
        path = File.join(cwd, "Gemfile")
        File.exist?(path) ? File.read(path) : ""
      end

      def gem_in_gemfile?(cwd, name)
        gemfile_content(cwd).match?(/gem\s+["']#{Regexp.escape(name)}["']/)
      end

      def rails?(cwd)
        File.exist?(File.join(cwd, "config", "application.rb")) ||
          gem_in_gemfile?(cwd, "rails") ||
          gem_in_gemfile?(cwd, "better_auth-rails")
      end

      def hanami?(cwd)
        hanami_gemfile?(cwd) || hanami_structure?(cwd)
      end

      def hanami_gemfile?(cwd)
        gem_in_gemfile?(cwd, "hanami") || gem_in_gemfile?(cwd, "better_auth-hanami")
      end

      def hanami_structure?(cwd)
        File.exist?(File.join(cwd, "config", "app.rb")) &&
          (File.exist?(File.join(cwd, "config", "hanami.rb")) || File.directory?(File.join(cwd, "apps")))
      end

      def sinatra?(cwd)
        (gem_in_gemfile?(cwd, "sinatra") || gem_in_gemfile?(cwd, "better_auth-sinatra")) &&
          !gem_in_gemfile?(cwd, "roda")
      end

      def roda?(cwd)
        gem_in_gemfile?(cwd, "roda") || gem_in_gemfile?(cwd, "better_auth-roda")
      end
    end
  end
end
