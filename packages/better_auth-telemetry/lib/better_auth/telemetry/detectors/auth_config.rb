# frozen_string_literal: true

module BetterAuth
  module Telemetry
    module Detectors
      # AuthConfig detector / redactor. Produces the redacted
      # `payload.config` hash emitted by the init event, mirroring
      # upstream `getTelemetryAuthConfig`.
      #
      # The whole {call} entry point is wrapped in `rescue
      # StandardError; nil` so any failure during redaction degrades
      # the entire `config` payload to `nil` rather than escaping out
      # of the init payload composition in {BetterAuth::Telemetry.create}.
      module AuthConfig
        # Top-level keys emitted in the redacted config payload, in
        # the order produced by upstream `getTelemetryAuthConfig`.
        TOP_LEVEL_KEYS = %i[
          database
          adapter
          emailVerification
          emailAndPassword
          socialProviders
          plugins
          user
          verification
          session
          account
          hooks
          secondaryStorage
          advanced
          trustedOrigins
          rateLimit
          onAPIError
          logger
          databaseHooks
        ].freeze

        # Models covered by the `databaseHooks` redaction map. The
        # order is fixed to mirror the upstream shape produced by
        # `getTelemetryAuthConfig` so the wire-format key order is
        # stable across runs.
        DATABASE_HOOK_MODELS = %i[user session account verification].freeze

        # Database operations covered for each model.
        DATABASE_HOOK_OPERATIONS = %i[create update].freeze

        # Phases covered for each (model, operation) pair. The
        # order is `after` then `before` to match upstream.
        DATABASE_HOOK_PHASES = %i[after before].freeze

        module_function

        # ------------------------------------------------------------------
        # Public entry point
        # ------------------------------------------------------------------

        # Build the redacted `payload.config` hash for the init event.
        #
        # @param options [BetterAuth::Configuration, Hash, nil] the
        #   options passed to {BetterAuth::Telemetry.create}. May be
        #   a {BetterAuth::Configuration} (production path), the raw
        #   options hash that {BetterAuth::Auth.new} would consume,
        #   or `nil`. Both shapes are descended via {fetch_path}, so
        #   the same redaction pipeline produces deep-equal payloads
        #   for matching inputs (Requirement 13.1).
        # @param context [BetterAuth::Telemetry::NormalizedContext, Hash, nil]
        #   the normalized context. Only `:database` and `:adapter`
        #   overrides are surfaced into the payload as raw
        #   pass-through values (Requirement 13.9). The accessor
        #   tolerates either a {NormalizedContext} (production path),
        #   a raw hash with snake_case or camelCase / symbol or
        #   string keys (test seams), or `nil` (top-level keys
        #   collapse to `nil`).
        # @return [Hash{Symbol => Object}, nil] the redacted config
        #   hash with the upstream top-level key set, or `nil` if
        #   anything in the redaction pipeline raises.
        def call(options, context)
          {
            database: context_value(context, :database),
            adapter: sanitize_adapter(context_value(context, :adapter)),
            emailVerification: redact_email_verification(options),
            emailAndPassword: redact_email_and_password(options),
            socialProviders: redact_social_providers(options),
            plugins: redact_plugins(options),
            user: redact_user(options),
            verification: redact_verification(options),
            session: redact_session(options),
            account: redact_account(options),
            hooks: redact_hooks(options),
            secondaryStorage: redact_secondary_storage(options),
            advanced: redact_advanced(options),
            trustedOrigins: redact_trusted_origins(options),
            rateLimit: redact_rate_limit(options),
            onAPIError: redact_on_api_error(options),
            logger: redact_logger(options),
            databaseHooks: redact_database_hooks(options)
          }
        rescue
          nil
        end

        # ------------------------------------------------------------------
        # Redaction primitives
        # ------------------------------------------------------------------

        # Boolean redaction: collapse any value into a strict
        # `true`/`false`. Used for callable/secret leaves where the
        # actual value must never reach the wire (Requirement 13.3).
        #
        # @param value [Object]
        # @return [Boolean]
        def bool(value)
          !!value
        end

        # Pass-through helper: emit the value as-is. Used for raw
        # scalars that are safe to ship verbatim (timeouts, lengths,
        # field maps, …).
        #
        # @param value [Object]
        # @return [Object]
        def raw(value)
          value
        end

        # Presence-aware boolean redaction. Returns `true` only when
        # the value is non-`nil`, not `false`, and not the empty
        # string. Mirrors upstream's `!!value && value !== ""`
        # idiom for fields like `advanced.cookiePrefix` where a
        # missing/empty value is meaningfully different from a set
        # one.
        #
        # @param value [Object]
        # @return [Boolean]
        def bool_present(value)
          !value.nil? && value != "" && value != false
        end

        # Length helper. Returns the integer length of any
        # `Array`-coercible input, with `nil` and non-array values
        # treated as the empty list. Used for `trustedOrigins`,
        # which is emitted as an integer count (never the contents).
        #
        # @param array [Array, nil, Object]
        # @return [Integer]
        def count(array)
          Array(array).length
        end

        def count_metadata(value)
          return nil if value.nil?
          return value.length if value.is_a?(Hash) || value.is_a?(Array)

          raw(value)
        end

        # ------------------------------------------------------------------
        # Unified accessor
        # ------------------------------------------------------------------

        # Read a nested value from either a {BetterAuth::Configuration}
        # instance or a raw options hash, using the same snake_case
        # path. Symbol/string key shapes in nested hashes are both
        # accepted.
        #
        # The path's first segment is treated as the
        # {BetterAuth::Configuration} reader name (snake_case). When
        # the source is a Configuration, the first segment is sent
        # via `public_send`; the remainder of the path is descended
        # into the returned value as if it were a hash. When the
        # source is a Hash, every segment is looked up as a hash
        # key, trying both symbol and string forms at each level.
        #
        # Any failure (a missing reader, a missing key, an
        # intermediate non-hash value) returns `nil` so the redaction
        # map can short-circuit cleanly without rescuing per-leaf.
        #
        # @example Configuration source
        #   cfg = BetterAuth::Configuration.new(
        #     secret: "0"*40,
        #     email_verification: { expires_in: 3600 }
        #   )
        #   AuthConfig.fetch_path(cfg, [:email_verification, :expires_in])
        #   # => 3600
        #
        # @example Raw hash source with mixed symbol/string keys
        #   opts = { "email_verification" => { send_verification_email: ->{} } }
        #   AuthConfig.fetch_path(opts, [:email_verification, :send_verification_email])
        #   # => #<Proc:...>
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @param path [Array<Symbol>] non-empty snake_case path. Each
        #   segment is matched against either a `Configuration`
        #   reader (first segment only) or a hash key (subsequent
        #   segments).
        # @return [Object, nil] the value at `path`, or `nil` when
        #   any segment is missing or the source is `nil`.
        def fetch_path(opts, path)
          return nil if opts.nil?
          return nil if path.nil? || path.empty?

          head, *tail = path
          current = read_root(opts, head)
          return current if tail.empty?

          tail.reduce(current) do |value, key|
            break nil unless value.is_a?(Hash)

            hash_lookup(value, key)
          end
        rescue
          nil
        end

        # ------------------------------------------------------------------
        # Per-section stubs (filled by 4.8 / 4.9 / 4.10 / 4.11)
        # ------------------------------------------------------------------

        # Build the redacted `payload.config.emailVerification` hash.
        #
        # Every callable leaf is `bool`-redacted (Requirement 13.3) so
        # the actual proc/lambda/object never reaches the wire. The
        # only raw scalar in this section is `expiresIn`.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_email_verification(opts)
          {
            sendVerificationEmail: bool(fetch_path(opts, [:email_verification, :send_verification_email])),
            sendOnSignUp: bool(fetch_path(opts, [:email_verification, :send_on_sign_up])),
            sendOnSignIn: bool(fetch_path(opts, [:email_verification, :send_on_sign_in])),
            autoSignInAfterVerification: bool(fetch_path(opts, [:email_verification, :auto_sign_in_after_verification])),
            expiresIn: raw(fetch_path(opts, [:email_verification, :expires_in])),
            beforeEmailVerification: bool(fetch_path(opts, [:email_verification, :before_email_verification])),
            afterEmailVerification: bool(fetch_path(opts, [:email_verification, :after_email_verification]))
          }
        end

        # Build the redacted `payload.config.emailAndPassword` hash.
        #
        # All callables (`sendResetPassword`, `onPasswordReset`,
        # `password.hash`, `password.verify`, …) are `bool`-redacted
        # per Requirement 13.4. Numeric configuration scalars
        # (`maxPasswordLength`, `minPasswordLength`,
        # `resetPasswordTokenExpiresIn`) are emitted raw.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_email_and_password(opts)
          {
            enabled: bool(fetch_path(opts, [:email_and_password, :enabled])),
            disableSignUp: bool(fetch_path(opts, [:email_and_password, :disable_sign_up])),
            requireEmailVerification: bool(fetch_path(opts, [:email_and_password, :require_email_verification])),
            maxPasswordLength: raw(fetch_path(opts, [:email_and_password, :max_password_length])),
            minPasswordLength: raw(fetch_path(opts, [:email_and_password, :min_password_length])),
            sendResetPassword: bool(fetch_path(opts, [:email_and_password, :send_reset_password])),
            resetPasswordTokenExpiresIn: raw(fetch_path(opts, [:email_and_password, :reset_password_token_expires_in])),
            onPasswordReset: bool(fetch_path(opts, [:email_and_password, :on_password_reset])),
            password: {
              hash: bool(fetch_path(opts, [:email_and_password, :password, :hash])),
              verify: bool(fetch_path(opts, [:email_and_password, :password, :verify]))
            },
            autoSignIn: bool(fetch_path(opts, [:email_and_password, :auto_sign_in])),
            revokeSessionsOnPasswordReset: bool(fetch_path(opts, [:email_and_password, :revoke_sessions_on_password_reset]))
          }
        end

        # Build the redacted `payload.config.socialProviders` array.
        #
        # The Ruby port stores `social_providers` as a `Hash` keyed
        # by provider id (`:github`, `:google`, …) where each value
        # is the per-provider options hash. Upstream emits an
        # `Array` of redacted-provider hashes, so we walk the source
        # hash and rebuild the wire shape one entry at a time.
        #
        # Mapping of keys (Ruby snake_case → upstream camelCase):
        #   bool leaves (callable / presence indicators):
        #     map_profile_to_user        → mapProfileToUser
        #     disable_default_scope      → disableDefaultScope
        #     disable_id_token_sign_in   → disableIdTokenSignIn
        #     get_user_info              → getUserInfo
        #     override_user_info_on_sign_in → overrideUserInfoOnSignIn
        #     verify_id_token            → verifyIdToken
        #     refresh_access_token       → refreshAccessToken
        #   raw pass-through scalars:
        #     disable_implicit_sign_up   → disableImplicitSignUp
        #     disable_sign_up            → disableSignUp
        #     prompt                     → prompt
        #     scope                      → scope
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Array<Hash{Symbol => Object}>]
        def redact_social_providers(opts)
          providers = fetch_path(opts, [:social_providers])
          return [] unless providers.is_a?(Hash)

          providers.map do |provider_id, raw_provider|
            provider = raw_provider.is_a?(Hash) ? raw_provider : {}
            {
              id: provider_id.to_s,
              mapProfileToUser: bool(provider[:map_profile_to_user]),
              disableDefaultScope: bool(provider[:disable_default_scope]),
              disableIdTokenSignIn: bool(provider[:disable_id_token_sign_in]),
              disableImplicitSignUp: provider[:disable_implicit_sign_up],
              disableSignUp: provider[:disable_sign_up],
              getUserInfo: bool(provider[:get_user_info]),
              overrideUserInfoOnSignIn: bool(provider[:override_user_info_on_sign_in]),
              prompt: provider[:prompt],
              verifyIdToken: bool(provider[:verify_id_token]),
              scope: provider[:scope],
              refreshAccessToken: bool(provider[:refresh_access_token])
            }
          end
        end

        # Build the redacted `payload.config.plugins` value.
        #
        # Upstream emits an array of plugin id strings, or `null`
        # (Ruby `nil`) when no plugins are configured. We mirror
        # that exactly: each configured plugin is asked for its
        # `id`, the result is stringified, blanks (nil / empty) are
        # dropped, and the empty-list case collapses to `nil`.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Array<String>, nil]
        def redact_plugins(opts)
          plugins = fetch_path(opts, [:plugins])
          ids = Array(plugins).map { |plugin| plugin.respond_to?(:id) ? plugin.id.to_s : nil }
          ids = ids.reject { |id| id.nil? || id.empty? }
          ids.empty? ? nil : ids
        end

        # Build the redacted `payload.config.user` hash.
        #
        # Every leaf except `changeEmail.sendChangeEmailConfirmation`
        # is a raw pass-through. The send-change-email confirmation
        # callback is `bool`-redacted per Requirement 13.4 so the
        # callable never reaches the wire.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_user(opts)
          {
            modelName: raw(fetch_path(opts, [:user, :model_name])),
            fields: count_metadata(fetch_path(opts, [:user, :fields])),
            additionalFields: count_metadata(fetch_path(opts, [:user, :additional_fields])),
            changeEmail: {
              enabled: raw(fetch_path(opts, [:user, :change_email, :enabled])),
              sendChangeEmailConfirmation: bool(fetch_path(opts, [:user, :change_email, :send_change_email_confirmation]))
            }
          }
        end

        # Build the redacted `payload.config.verification` hash. All
        # leaves are raw pass-throughs (no callables in this section).
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_verification(opts)
          {
            modelName: raw(fetch_path(opts, [:verification, :model_name])),
            disableCleanup: raw(fetch_path(opts, [:verification, :disable_cleanup])),
            fields: count_metadata(fetch_path(opts, [:verification, :fields]))
          }
        end

        # Build the redacted `payload.config.session` hash. Every
        # documented leaf is a raw pass-through; nested
        # `cookieCache.*` keys are emitted as their own sub-hash
        # mirroring upstream.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_session(opts)
          {
            modelName: raw(fetch_path(opts, [:session, :model_name])),
            additionalFields: count_metadata(fetch_path(opts, [:session, :additional_fields])),
            cookieCache: {
              enabled: raw(fetch_path(opts, [:session, :cookie_cache, :enabled])),
              maxAge: raw(fetch_path(opts, [:session, :cookie_cache, :max_age])),
              strategy: raw(fetch_path(opts, [:session, :cookie_cache, :strategy]))
            },
            disableSessionRefresh: raw(fetch_path(opts, [:session, :disable_session_refresh])),
            expiresIn: raw(fetch_path(opts, [:session, :expires_in])),
            fields: count_metadata(fetch_path(opts, [:session, :fields])),
            freshAge: raw(fetch_path(opts, [:session, :fresh_age])),
            preserveSessionInDatabase: raw(fetch_path(opts, [:session, :preserve_session_in_database])),
            storeSessionInDatabase: raw(fetch_path(opts, [:session, :store_session_in_database])),
            updateAge: raw(fetch_path(opts, [:session, :update_age]))
          }
        end

        # Build the redacted `payload.config.account` hash. Every
        # documented leaf is a raw pass-through; nested
        # `accountLinking.*` keys are emitted as their own sub-hash
        # mirroring upstream.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_account(opts)
          {
            modelName: raw(fetch_path(opts, [:account, :model_name])),
            fields: count_metadata(fetch_path(opts, [:account, :fields])),
            encryptOAuthTokens: raw(fetch_path(opts, [:account, :encrypt_oauth_tokens])),
            updateAccountOnSignIn: raw(fetch_path(opts, [:account, :update_account_on_sign_in])),
            accountLinking: {
              enabled: raw(fetch_path(opts, [:account, :account_linking, :enabled])),
              trustedProviders: count_metadata(fetch_path(opts, [:account, :account_linking, :trusted_providers])),
              updateUserInfoOnLink: raw(fetch_path(opts, [:account, :account_linking, :update_user_info_on_link])),
              allowUnlinkingAll: raw(fetch_path(opts, [:account, :account_linking, :allow_unlinking_all]))
            }
          }
        end

        # Build the redacted `payload.config.hooks` hash.
        #
        # Both `before` and `after` may be a single proc, an array
        # of procs, or `nil`. The redaction collapses any non-nil/
        # non-false value into `true`, so callable references never
        # leak (Requirement 13.4).
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_hooks(opts)
          {
            after: bool(fetch_path(opts, [:hooks, :after])),
            before: bool(fetch_path(opts, [:hooks, :before]))
          }
        end

        # Build the redacted `payload.config.secondaryStorage` value.
        #
        # Upstream emits `!!options.secondaryStorage`: a strict
        # boolean indicating whether a secondary storage backend has
        # been wired up, never the storage object itself
        # (Requirement 13.4 — callable / object references must not
        # reach the wire).
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Boolean]
        def redact_secondary_storage(opts)
          bool(fetch_path(opts, [:secondary_storage]))
        end

        # Build the redacted `payload.config.advanced` hash.
        #
        # The shape mirrors upstream `getTelemetryAuthConfig`'s
        # `advanced` block, including the rename from the Ruby
        # source key `default_cookie_attributes` to the upstream
        # wire key `cookieAttributes` (Requirement 13.7).
        #
        # The four boolean-redacted leaves protect host-identifying
        # values from leaking onto the wire (Requirement 13.3 /
        # 13.4):
        #
        #   * `cookiePrefix` — the literal cookie name prefix.
        #   * `cookies` — the per-cookie configuration hash.
        #   * `crossSubDomainCookies.domain` — host-identifying
        #     domain string for cross-subdomain cookies.
        #   * `cookieAttributes.domain` — host-identifying domain
        #     string for the default cookie attributes.
        #
        # Every other leaf is a raw pass-through scalar.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_advanced(opts)
          {
            cookiePrefix: bool(fetch_path(opts, [:advanced, :cookie_prefix])),
            cookies: bool(fetch_path(opts, [:advanced, :cookies])),
            crossSubDomainCookies: {
              domain: bool(fetch_path(opts, [:advanced, :cross_sub_domain_cookies, :domain])),
              enabled: raw(fetch_path(opts, [:advanced, :cross_sub_domain_cookies, :enabled])),
              additionalCookies: count_metadata(fetch_path(opts, [:advanced, :cross_sub_domain_cookies, :additional_cookies]))
            },
            database: {
              generateId: bool(fetch_path(opts, [:advanced, :database, :generate_id])),
              defaultFindManyLimit: raw(fetch_path(opts, [:advanced, :database, :default_find_many_limit]))
            },
            useSecureCookies: raw(fetch_path(opts, [:advanced, :use_secure_cookies])),
            ipAddress: {
              disableIpTracking: raw(fetch_path(opts, [:advanced, :ip_address, :disable_ip_tracking])),
              ipAddressHeaders: count_metadata(fetch_path(opts, [:advanced, :ip_address, :ip_address_headers]))
            },
            disableCSRFCheck: raw(fetch_path(opts, [:advanced, :disable_csrf_check])),
            cookieAttributes: {
              expires: raw(fetch_path(opts, [:advanced, :default_cookie_attributes, :expires])),
              secure: raw(fetch_path(opts, [:advanced, :default_cookie_attributes, :secure])),
              sameSite: raw(fetch_path(opts, [:advanced, :default_cookie_attributes, :same_site])),
              domain: bool(fetch_path(opts, [:advanced, :default_cookie_attributes, :domain])),
              path: raw(fetch_path(opts, [:advanced, :default_cookie_attributes, :path])),
              httpOnly: raw(fetch_path(opts, [:advanced, :default_cookie_attributes, :http_only]))
            }
          }
        end

        # Build the redacted `payload.config.trustedOrigins` value.
        #
        # Upstream emits `options.trustedOrigins?.length`: an integer
        # count of configured origins, or `nil` when the key is
        # absent. We never emit the origin strings themselves, since
        # they identify customer hosts (Requirement 13.7).
        #
        # The Ruby `Configuration#trusted_origins` reader normalizes
        # the input into an array (folding in `base_url`,
        # dynamic-base-url hosts, and the
        # `BETTER_AUTH_TRUSTED_ORIGINS` env list); the count we emit
        # matches whatever that normalization produced. When the
        # source is a raw hash, we count the literal value at
        # `:trusted_origins`.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Integer, nil]
        def redact_trusted_origins(opts)
          value = fetch_path(opts, [:trusted_origins])
          return nil if value.nil?

          count(value)
        end

        # Build the redacted `payload.config.rateLimit` hash.
        #
        # `customStorage` is callable in the upstream type and is
        # therefore boolean-redacted (Requirement 13.4); every other
        # leaf is a raw pass-through scalar.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_rate_limit(opts)
          {
            storage: raw(fetch_path(opts, [:rate_limit, :storage])),
            modelName: raw(fetch_path(opts, [:rate_limit, :model_name])),
            window: raw(fetch_path(opts, [:rate_limit, :window])),
            customStorage: bool(fetch_path(opts, [:rate_limit, :custom_storage])),
            enabled: raw(fetch_path(opts, [:rate_limit, :enabled])),
            max: raw(fetch_path(opts, [:rate_limit, :max]))
          }
        end

        # Build the redacted `payload.config.onAPIError` hash.
        #
        # `onError` is callable in the upstream type and is
        # therefore boolean-redacted (Requirement 13.4). `errorURL`
        # and `throw` are raw pass-through scalars.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_on_api_error(opts)
          {
            errorURL: bool_present(fetch_path(opts, [:on_api_error, :error_url])),
            onError: bool(fetch_path(opts, [:on_api_error, :on_error])),
            throw: raw(fetch_path(opts, [:on_api_error, :throw]))
          }
        end

        # Build the redacted `payload.config.logger` hash.
        #
        # `log` is callable in the upstream type and is therefore
        # boolean-redacted (Requirement 13.4). `disabled` and
        # `level` are raw pass-through scalars.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Object}]
        def redact_logger(opts)
          {
            disabled: raw(fetch_path(opts, [:logger, :disabled])),
            level: raw(fetch_path(opts, [:logger, :level])),
            log: bool(fetch_path(opts, [:logger, :log]))
          }
        end

        # Build the redacted `payload.config.databaseHooks` tree.
        #
        # The full upstream shape is a 4 × 2 × 2 nested tree:
        #
        #   { user, session, account, verification } ×
        #     { create, update } ×
        #       { before, after }
        #
        # giving sixteen leaves total. Every leaf is a callable in
        # the upstream type, so every leaf is boolean-redacted
        # (Requirement 13.8). The full tree is always emitted with
        # the same shape so downstream consumers can rely on the
        # key set being stable; missing leaves collapse to `false`.
        #
        # @param opts [BetterAuth::Configuration, Hash, nil]
        # @return [Hash{Symbol => Hash}]
        def redact_database_hooks(opts)
          DATABASE_HOOK_MODELS.each_with_object({}) do |model, result|
            result[model] = DATABASE_HOOK_OPERATIONS.each_with_object({}) do |operation, ops|
              ops[operation] = DATABASE_HOOK_PHASES.each_with_object({}) do |phase, phases|
                phases[phase] = bool(fetch_path(opts, [:database_hooks, model, operation, phase]))
              end
            end
          end
        end

        # ------------------------------------------------------------------
        # Internal helpers
        # ------------------------------------------------------------------

        # Read a single override key from the {NormalizedContext}
        # surface, accepting either a {NormalizedContext} instance
        # (the production path), a raw hash with snake_case or
        # camelCase keys in symbol or string form (test seams), or
        # `nil`. Returns the raw value when present, `nil`
        # otherwise. Used to inject `payload[:database]` and
        # `payload[:adapter]` from the call-site context override
        # without going through the redaction map (Requirement
        # 13.9 — context overrides are pass-through).
        #
        # @param context [Object, nil]
        # @param key [Symbol] one of `:database` or `:adapter`.
        # @return [Object, nil]
        def context_value(context, key)
          return nil if context.nil?
          return context.public_send(key) if context.respond_to?(key)
          return nil unless context.is_a?(Hash)

          symbol_key = key.is_a?(Symbol) ? key : key.to_s.to_sym
          return context[symbol_key] if context.key?(symbol_key)

          string_key = key.to_s
          return context[string_key] if context.key?(string_key)

          nil
        rescue
          nil
        end

        def sanitize_adapter(value)
          return "adapter" if value.is_a?(String) && value.include?("::")

          value
        rescue
          nil
        end

        # Read the root (first segment) of a `fetch_path` lookup.
        # For a {BetterAuth::Configuration} we call the snake_case
        # reader; for a Hash we look up the key under both symbol
        # and string forms; for any other object we return `nil`.
        #
        # @param opts [BetterAuth::Configuration, Hash, Object]
        # @param key [Symbol]
        # @return [Object, nil]
        def read_root(opts, key)
          if defined?(::BetterAuth::Configuration) && opts.is_a?(::BetterAuth::Configuration)
            return opts.public_send(key) if opts.respond_to?(key)

            return nil
          end

          return hash_lookup(opts, key) if opts.is_a?(Hash)

          nil
        end

        # Look up a key in a hash trying both symbol and string
        # forms. Returns `nil` when neither shape contains the key.
        #
        # @param hash [Hash]
        # @param key [Symbol, String]
        # @return [Object, nil]
        def hash_lookup(hash, key)
          symbol_key = key.is_a?(Symbol) ? key : key.to_s.to_sym
          return hash[symbol_key] if hash.key?(symbol_key)

          string_key = key.to_s
          return hash[string_key] if hash.key?(string_key)

          nil
        end
      end
    end
  end
end
