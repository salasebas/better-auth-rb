# frozen_string_literal: true

module BetterAuth
  module Telemetry
    module Detectors
      # Runtime detector. Returns a small hash describing the Ruby
      # interpreter currently executing the host application.
      #
      # This is the Ruby-specific replacement for upstream's
      # `detect-runtime.ts`, which classified Node, Deno, Bun, Cloudflare
      # Workers, and other JavaScript runtimes. The Ruby port is
      # server-only, so all of those branches collapse into a single
      # `"ruby"` case. The `:engine` field preserves enough information
      # for telemetry consumers to distinguish MRI, JRuby, TruffleRuby,
      # etc.
      #
      # The whole detector is wrapped in `rescue StandardError` so a
      # surprise from `RUBY_VERSION`/`RUBY_ENGINE` (very unlikely, but
      # possible under exotic patched interpreters) cannot bubble out
      # of the init payload composition in
      # {BetterAuth::Telemetry.create}.
      #
      # @example
      #   BetterAuth::Telemetry::Detectors::Runtime.call
      #   # => {name: "ruby", version: "3.3.0", engine: "ruby"}
      module Runtime
        module_function

        # @return [Hash{Symbol => String, nil}] hash with `:name`,
        #   `:version`, and `:engine` keys. `:name` is always `"ruby"`.
        #   `:version` is `RUBY_VERSION`. `:engine` is `RUBY_ENGINE`
        #   when defined, otherwise the literal string `"ruby"`.
        def call
          {
            name: "ruby",
            version: RUBY_VERSION,
            engine: defined?(RUBY_ENGINE) ? RUBY_ENGINE : "ruby"
          }
        rescue
          {name: "ruby", version: nil, engine: nil}
        end
      end
    end
  end
end
