# frozen_string_literal: true

require "better_auth/env"

module BetterAuth
  module Telemetry
    # Telemetry-side wrapper around {BetterAuth::Env} that exposes the
    # two helpers the rest of the telemetry pipeline depends on:
    #
    # - {.get} — read a `BETTER_AUTH_*` environment variable while
    #   transparently honoring the `OPEN_AUTH_*` alias prefix.
    # - {.truthy?} — classify a resolved env string as truthy using the
    #   same rules upstream applies in
    #   `packages/core/src/env/env-impl.ts:getBooleanEnvVar`.
    #
    # The wrapper is intentionally thin: {BetterAuth::Env.get} already
    # implements the dual-prefix resolution, so {.get} just delegates.
    # Wrapping it here gives the telemetry package a single, named seam
    # the orchestrator code can reach for and the tests can drive against,
    # without leaking the core env module into every detector.
    #
    # ## Truthy semantics
    #
    # An environment value is considered a `Truthy_Env_Value`
    # (Requirement 3.6) when **all three** of these conditions hold for
    # the resolved string:
    #
    # 1. it is not empty,
    # 2. it is not the literal `"0"`, and
    # 3. `value.casecmp("false") != 0` (i.e. not `"false"` / `"FALSE"`
    #    / `"False"` / etc).
    #
    # Anything else — including `nil`, `""`, `"0"`, and any casing of
    # `"false"` — is falsy. This mirrors the upstream behavior so the
    # Ruby port classifies opt-in toggles identically to the Node port.
    #
    # The classifier accepts any input type: non-string values are
    # coerced via `#to_s` before classification. That makes it safe to
    # forward boolean defaults straight from option hashes
    # (`Env.truthy?(options[:telemetry][:debug])`) without callers
    # having to type-check first.
    module Env
      module_function

      # Resolve the value of a telemetry environment variable.
      #
      # Accepts the canonical `BETTER_AUTH_*` name and delegates to
      # {BetterAuth::Env.get}, which checks the `OPEN_AUTH_*` alias
      # first and falls back to the canonical name. Returns `nil` when
      # neither variant is set (or both are empty).
      #
      # @param name [String, Symbol] canonical `BETTER_AUTH_*`
      #   environment variable name (e.g. `"BETTER_AUTH_TELEMETRY"`).
      # @return [String, nil] the resolved value, or `nil` when absent.
      def get(name)
        ::BetterAuth::Env.get(name)
      end

      # Classify an environment value as truthy.
      #
      # @param value [Object, nil] typically a `String` returned from
      #   {.get}, but any value is accepted; non-strings are coerced via
      #   `#to_s`. `nil` coerces to `""` and is falsy.
      # @return [Boolean] `true` when the resolved string is non-empty,
      #   not `"0"`, and not (case-insensitively) `"false"`. `false`
      #   otherwise.
      def truthy?(value)
        string = value.to_s
        return false if string.empty?
        return false if string == "0"
        return false if string.casecmp("false") == 0

        true
      end
    end
  end
end
