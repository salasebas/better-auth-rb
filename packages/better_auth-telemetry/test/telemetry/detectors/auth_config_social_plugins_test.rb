# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth"
require "better_auth/telemetry/detectors/auth_config"

# Verifies the redaction map rows under `socialProviders[]`, `plugins`,
# `user.*`, `verification.*`, `session.*`, and `account.*` filled in by
# task 4.9.
#
# The strategy: build a `BetterAuth::Configuration` with two social
# providers (one populated, one barebones), two plugin instances, and
# every `user`/`session`/`account`/`verification` leaf populated with
# either a sentinel string (raw pass-through) or a callable
# (boolean-redacted). Then call {AuthConfig.call} and assert each
# documented camelCase key matches the redaction shape.
class AuthConfigSocialPluginsTest < Minitest::Test
  AuthConfig = BetterAuth::Telemetry::Detectors::AuthConfig

  # Factory helpers ---------------------------------------------------

  # Build a `BetterAuth::Configuration` with the listed social
  # providers / plugins / user / session / account / verification
  # overrides on top of the bare-minimum required keys.
  def configuration_with(extra = {})
    BetterAuth::Configuration.new({secret: "0" * 40}.merge(extra))
  end

  # The first provider populates **every** documented option so each
  # `bool` leaf collapses to `true` and each raw pass-through carries
  # the sentinel value.
  def populated_provider_options
    {
      map_profile_to_user: -> { :ignored },
      disable_default_scope: true,
      disable_id_token_sign_in: true,
      disable_implicit_sign_up: false,
      disable_sign_up: true,
      get_user_info: -> { :ignored },
      override_user_info_on_sign_in: true,
      prompt: "consent",
      verify_id_token: -> { :ignored },
      scope: %w[email profile],
      refresh_access_token: -> { :ignored }
    }
  end

  # The second provider leaves every option unset so each `bool`
  # leaf collapses to `false` and each raw pass-through carries
  # `nil`. This proves the empty-options branch wires `bool(nil) ==
  # false` rather than raising on missing keys.
  def empty_provider_options
    {}
  end

  # Tiny stand-in plugin class. We intentionally do **not** use
  # `BetterAuth::Plugin.coerce` to avoid coupling this test to plugin
  # normalization details; the redactor only needs `#respond_to?(:id)
  # && #id`. Configuration#normalize_plugins will wrap us via
  # `Plugin.coerce`, but the wrapped Plugin still exposes `id` as a
  # string so the assertion stays stable.
  PluginStub = Struct.new(:id) do
    def to_h
      {id: id}
    end
  end

  def configuration
    configuration_with(
      social_providers: {
        github: populated_provider_options,
        google: empty_provider_options
      },
      plugins: [PluginStub.new("alpha"), PluginStub.new("beta")],
      user: {
        model_name: "users",
        fields: {email: "user_email"},
        additional_fields: {nickname: {type: "string"}},
        change_email: {
          enabled: true,
          send_change_email_confirmation: -> { :ignored }
        }
      },
      verification: {
        model_name: "verifications",
        disable_cleanup: true,
        fields: {identifier: "ident"}
      },
      session: {
        model_name: "sessions",
        additional_fields: {device_id: {type: "string"}},
        cookie_cache: {
          enabled: true,
          max_age: 600,
          strategy: "jwe"
        },
        disable_session_refresh: true,
        expires_in: 7200,
        fields: {token: "tok"},
        fresh_age: 1200,
        preserve_session_in_database: true,
        store_session_in_database: false,
        update_age: 86_400
      },
      account: {
        model_name: "accounts",
        fields: {provider_id: "pid"},
        encrypt_oauth_tokens: true,
        update_account_on_sign_in: false,
        account_linking: {
          enabled: true,
          trusted_providers: %w[github google],
          update_user_info_on_link: true,
          allow_unlinking_all: false
        }
      }
    )
  end

  def payload
    @payload ||= AuthConfig.call(configuration, nil)
  end

  # ------------------------------------------------------------------
  # socialProviders[*]
  # ------------------------------------------------------------------

  def test_social_providers_is_an_array_with_one_entry_per_configured_provider
    section = payload[:socialProviders]

    assert_kind_of Array, section
    assert_equal 2, section.length
    ids = section.map { |entry| entry[:id] }
    assert_equal %w[github google], ids
  end

  def test_social_providers_entries_carry_the_documented_camelcase_key_set
    expected_keys = %i[
      id
      mapProfileToUser
      disableDefaultScope
      disableIdTokenSignIn
      disableImplicitSignUp
      disableSignUp
      getUserInfo
      overrideUserInfoOnSignIn
      prompt
      verifyIdToken
      scope
      refreshAccessToken
    ]

    payload[:socialProviders].each do |entry|
      assert_equal expected_keys.sort, entry.keys.sort,
        "provider #{entry[:id].inspect} should expose exactly the documented keys"
    end
  end

  def test_populated_provider_redacts_callable_leaves_to_strict_true
    github = payload[:socialProviders].find { |entry| entry[:id] == "github" }

    assert_equal true, github[:mapProfileToUser]
    assert_equal true, github[:disableDefaultScope]
    assert_equal true, github[:disableIdTokenSignIn]
    assert_equal true, github[:getUserInfo]
    assert_equal true, github[:overrideUserInfoOnSignIn]
    assert_equal true, github[:verifyIdToken]
    assert_equal true, github[:refreshAccessToken]
  end

  def test_populated_provider_passes_through_raw_scalars_verbatim
    github = payload[:socialProviders].find { |entry| entry[:id] == "github" }

    # `disableSignUp` and `disableImplicitSignUp` are raw scalars in
    # upstream's redaction block, so they pass through unchanged.
    assert_equal true, github[:disableSignUp]
    assert_equal false, github[:disableImplicitSignUp]
    assert_equal "consent", github[:prompt]
    assert_equal %w[email profile], github[:scope]
  end

  def test_empty_provider_collapses_callable_leaves_to_strict_false
    google = payload[:socialProviders].find { |entry| entry[:id] == "google" }

    assert_equal false, google[:mapProfileToUser]
    assert_equal false, google[:disableDefaultScope]
    assert_equal false, google[:disableIdTokenSignIn]
    assert_equal false, google[:getUserInfo]
    assert_equal false, google[:overrideUserInfoOnSignIn]
    assert_equal false, google[:verifyIdToken]
    assert_equal false, google[:refreshAccessToken]
  end

  def test_empty_provider_emits_nil_for_unset_raw_pass_through_keys
    google = payload[:socialProviders].find { |entry| entry[:id] == "google" }

    assert_nil google[:disableImplicitSignUp]
    assert_nil google[:disableSignUp]
    assert_nil google[:prompt]
    assert_nil google[:scope]
  end

  # ------------------------------------------------------------------
  # plugins
  # ------------------------------------------------------------------

  def test_plugins_is_the_array_of_plugin_id_strings_in_declaration_order
    # `Configuration#normalize_plugins` wraps each plugin via
    # `BetterAuth::Plugin.coerce`. The resulting `Plugin#id` is the
    # stringified id from the original `PluginStub#id`.
    assert_equal %w[alpha beta], payload[:plugins]
  end

  def test_plugins_is_nil_when_no_plugins_are_configured
    config = configuration_with(plugins: [])
    section = AuthConfig.call(config, nil)

    assert_nil section[:plugins]
  end

  def test_plugins_is_nil_when_plugins_key_is_absent
    config = configuration_with
    section = AuthConfig.call(config, nil)

    assert_nil section[:plugins]
  end

  # ------------------------------------------------------------------
  # user.*
  # ------------------------------------------------------------------

  def test_user_section_emits_documented_camelcase_keys
    user = payload[:user]

    assert_equal "users", user[:modelName]
    assert_equal({email: "user_email"}, user[:fields])
    assert_equal({nickname: {type: "string"}}, user[:additionalFields])
  end

  def test_user_change_email_enabled_is_raw_pass_through
    assert_equal true, payload[:user][:changeEmail][:enabled]
  end

  def test_user_change_email_send_change_email_confirmation_is_strict_true_when_callable_present
    assert_equal true, payload[:user][:changeEmail][:sendChangeEmailConfirmation]
  end

  def test_user_change_email_send_change_email_confirmation_is_strict_false_when_unset
    config = configuration_with(user: {change_email: {enabled: false}})
    user = AuthConfig.call(config, nil)[:user]

    assert_equal false, user[:changeEmail][:sendChangeEmailConfirmation]
  end

  # ------------------------------------------------------------------
  # verification.*
  # ------------------------------------------------------------------

  def test_verification_section_emits_documented_camelcase_keys_as_raw
    verification = payload[:verification]

    assert_equal "verifications", verification[:modelName]
    assert_equal true, verification[:disableCleanup]
    assert_equal({identifier: "ident"}, verification[:fields])
  end

  # ------------------------------------------------------------------
  # session.*
  # ------------------------------------------------------------------

  def test_session_section_emits_documented_camelcase_keys_as_raw
    session = payload[:session]

    assert_equal "sessions", session[:modelName]
    assert_equal({device_id: {type: "string"}}, session[:additionalFields])
    assert_equal true, session[:cookieCache][:enabled]
    assert_equal 600, session[:cookieCache][:maxAge]
    assert_equal "jwe", session[:cookieCache][:strategy]
    assert_equal true, session[:disableSessionRefresh]
    assert_equal 7200, session[:expiresIn]
    assert_equal({token: "tok"}, session[:fields])
    assert_equal 1200, session[:freshAge]
    assert_equal true, session[:preserveSessionInDatabase]
    assert_equal false, session[:storeSessionInDatabase]
    assert_equal 86_400, session[:updateAge]
  end

  # ------------------------------------------------------------------
  # account.*
  # ------------------------------------------------------------------

  def test_account_section_emits_documented_camelcase_keys_as_raw
    account = payload[:account]

    assert_equal "accounts", account[:modelName]
    assert_equal({provider_id: "pid"}, account[:fields])
    assert_equal true, account[:encryptOAuthTokens]
    assert_equal false, account[:updateAccountOnSignIn]
    assert_equal true, account[:accountLinking][:enabled]
    assert_equal %w[github google], account[:accountLinking][:trustedProviders]
    assert_equal true, account[:accountLinking][:updateUserInfoOnLink]
    assert_equal false, account[:accountLinking][:allowUnlinkingAll]
  end
end
