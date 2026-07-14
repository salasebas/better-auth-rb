# frozen_string_literal: true

require "json"
require_relative "../../test_helper"

class BetterAuthPluginsI18nTest < Minitest::Test
  TRANSLATIONS = {
    "en" => {
      "INVALID_EMAIL_OR_PASSWORD" => "Invalid email or password",
      "INVALID_PASSWORD" => "Invalid password"
    },
    "fr" => {
      "INVALID_EMAIL_OR_PASSWORD" => "FR invalid email or password",
      "INVALID_PASSWORD" => "FR invalid password",
      "BODY_MUST_BE_AN_OBJECT" => "FR body must be an object",
      "CUSTOM_ERROR" => "FR custom error"
    },
    "de" => {
      "INVALID_EMAIL_OR_PASSWORD" => "DE invalid email or password"
    }
  }.freeze

  def build_auth(options = {})
    BetterAuthTestHelpers.build_auth({
      email_and_password: BetterAuthTestPasswordHelpers.fast_email_and_password_config
    }.merge(options))
  end

  def build_i18n_plugin(overrides = {})
    BetterAuth::Plugins.i18n({translations: TRANSLATIONS}.merge(overrides))
  end

  def test_i18n_factory_shape
    plugin = build_i18n_plugin

    assert_equal "i18n", plugin.id
    assert_empty plugin.endpoints
    assert_empty plugin.schema
    assert_empty plugin.migrations
    assert_equal ["header"], plugin.options[:detection]
  end

  def test_i18n_raises_when_translations_are_empty
    error = assert_raises(BetterAuth::Error) do
      BetterAuth::Plugins.i18n(translations: {})
    end

    assert_includes error.message, "i18n plugin: translations object is empty"
  end

  def test_i18n_raises_when_translations_are_missing
    error = assert_raises(BetterAuth::Error) do
      BetterAuth::Plugins.i18n({})
    end

    assert_includes error.message, "i18n plugin: translations object is empty"
  end

  def test_header_detection_translates_invalid_email_or_password_to_french
    auth = build_auth(plugins: [build_i18n_plugin])

    status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "fr"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal 401, status
    assert_equal "INVALID_EMAIL_OR_PASSWORD", payload["code"]
    assert_equal "FR invalid email or password", payload["message"]
    assert_equal "Invalid email or password", payload["originalMessage"]
  end

  def test_header_detection_translates_to_german
    auth = build_auth(plugins: [build_i18n_plugin])

    status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "de"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal 401, status
    assert_equal "DE invalid email or password", payload["message"]
  end

  def test_header_detection_uses_quality_values_to_pick_first_available_locale
    auth = build_auth(plugins: [build_i18n_plugin])

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "es;q=0.9, fr;q=0.8, en;q=0.7"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "FR invalid email or password", payload["message"]
  end

  def test_header_detection_maps_regional_locale_to_base_locale
    auth = build_auth(plugins: [build_i18n_plugin])

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "fr-CA"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "FR invalid email or password", payload["message"]
  end

  def test_unknown_header_locale_falls_back_to_default_locale
    auth = build_auth(plugins: [build_i18n_plugin(default_locale: "de")])

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "es"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "DE invalid email or password", payload["message"]
  end

  def test_cookie_detection_takes_priority_over_header
    auth = build_auth(plugins: [build_i18n_plugin(detection: ["cookie", "header"], locale_cookie: "lang")])

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"cookie" => "lang=fr", "Accept-Language" => "de"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "FR invalid email or password", payload["message"]
  end

  def test_session_detection_reads_locale_from_current_user
    auth = build_auth(
      plugins: [build_i18n_plugin(detection: ["session", "header"], user_locale_field: "locale")],
      user: {
        additional_fields: {
          locale: {type: "string", required: false}
        }
      }
    )

    cookie = BetterAuthTestHelpers.sign_up_cookie(
      auth,
      email: "locale-user@example.com",
      extra: {locale: "fr"}
    )

    status, _headers, body = auth.api.update_user(
      headers: {"cookie" => cookie},
      body: ["not-object"],
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal 400, status
    assert_equal "BODY_MUST_BE_AN_OBJECT", payload["code"]
    assert_equal "FR body must be an object", payload["message"]
  end

  def test_callback_detection_reads_custom_header
    auth = build_auth(
      plugins: [
        build_i18n_plugin(
          detection: ["callback"],
          get_locale: ->(ctx) { ctx.headers["x-custom-locale"] }
        )
      ]
    )

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"x-custom-locale" => "fr"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "FR invalid email or password", payload["message"]
  end

  def test_callback_detection_runs_for_direct_api_without_request
    auth = build_auth(
      plugins: [
        build_i18n_plugin(
          detection: ["callback"],
          get_locale: ->(_ctx) { "fr" }
        )
      ]
    )

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "FR invalid email or password", payload["message"]
  end

  def test_detection_order_falls_through_when_callback_returns_unavailable_locale
    auth = build_auth(
      plugins: [
        build_i18n_plugin(
          detection: ["callback", "header"],
          get_locale: ->(_ctx) { "es" }
        )
      ]
    )

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "fr"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "FR invalid email or password", payload["message"]
  end

  def test_missing_translation_keeps_original_response_unchanged
    auth = build_auth(
      plugins: [
        build_i18n_plugin(
          translations: {
            "fr" => {
              "INVALID_PASSWORD" => "FR invalid password"
            }
          }
        )
      ]
    )

    status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "fr"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal 401, status
    assert_equal "Invalid email or password", payload["message"]
    refute payload.key?("originalMessage")
  end

  def test_non_error_responses_are_not_modified
    auth = build_auth(plugins: [build_i18n_plugin])
    cookie = BetterAuthTestHelpers.sign_up_cookie(auth, email: "session-user@example.com")

    _status, _headers, body = auth.api.get_session(
      headers: {"Accept-Language" => "fr", "cookie" => cookie},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert payload["session"]
    assert payload["user"]
    refute payload.key?("originalMessage")
  end

  def test_rack_http_request_path_translates_errors
    auth = build_auth(plugins: [build_i18n_plugin])

    status, _headers, body = auth.call(
      BetterAuthTestHelpers.json_rack_env(
        "POST",
        "/api/auth/sign-in/email",
        body: {email: "missing@example.com", password: "password123"},
        headers: {"HTTP_ACCEPT_LANGUAGE" => "fr"}
      )
    )

    payload = JSON.parse(body.join)

    assert_equal 401, status
    assert_equal "FR invalid email or password", payload["message"]
    assert_equal "Invalid email or password", payload["originalMessage"]
  end

  def test_symbol_and_camel_case_option_compatibility
    plugin = BetterAuth::Plugins.i18n(
      translations: {fr: {INVALID_EMAIL_OR_PASSWORD: "FR invalid email or password"}},
      defaultLocale: "fr",
      localeCookie: "lang",
      userLocaleField: "locale",
      getLocale: ->(_ctx) { "fr" }
    )

    assert_equal "fr", plugin.options[:default_locale]
    assert_equal "lang", plugin.options[:locale_cookie]
    assert_equal "locale", plugin.options[:user_locale_field]
    assert_respond_to plugin.options[:get_locale], :call

    auth = build_auth(plugins: [plugin])

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "FR invalid email or password", payload["message"]
  end

  def test_plugin_error_code_reverse_lookup_translates_custom_errors
    custom_plugin = BetterAuth::Plugin.new(
      id: "custom-errors",
      error_codes: {"CUSTOM_ERROR" => "Custom original"},
      endpoints: {
        trigger: BetterAuth::Endpoint.new(path: "/trigger-custom", method: "GET") do |_ctx|
          raise BetterAuth::APIError.new("BAD_REQUEST", message: "Custom original")
        end
      }
    )

    auth = build_auth(
      plugins: [
        build_i18n_plugin,
        custom_plugin
      ]
    )

    _status, _headers, body = auth.api.trigger(
      headers: {"Accept-Language" => "fr"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "CUSTOM_ERROR", payload["code"]
    assert_equal "FR custom error", payload["message"]
    assert_equal "Custom original", payload["originalMessage"]
  end

  def test_default_locale_en_used_when_accept_language_unavailable
    auth = build_auth(plugins: [build_i18n_plugin(default_locale: "en")])

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "es"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "INVALID_EMAIL_OR_PASSWORD", payload["code"]
    assert_equal "Invalid email or password", payload["message"]
  end

  def test_default_locale_used_when_no_detection_signals_present
    auth = build_auth(plugins: [build_i18n_plugin(default_locale: "en")])

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "Invalid email or password", payload["message"]
  end

  def test_builtin_english_is_preserved_when_default_and_english_translation_are_missing
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.i18n(
          translations: {
            "fr" => {
              "INVALID_EMAIL_OR_PASSWORD" => "FR invalid email or password"
            },
            "de" => {
              "INVALID_EMAIL_OR_PASSWORD" => "DE invalid email or password"
            }
          },
          detection: ["header"]
        )
      ]
    )

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "Invalid email or password", payload["message"]
  end

  def test_en_used_as_implicit_default_when_available_but_not_specified
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.i18n(
          translations: {
            "de" => {
              "INVALID_EMAIL_OR_PASSWORD" => "DE invalid email or password"
            },
            "en" => {
              "INVALID_EMAIL_OR_PASSWORD" => "Invalid email or password"
            },
            "fr" => {
              "INVALID_EMAIL_OR_PASSWORD" => "FR invalid email or password"
            }
          },
          detection: ["header"]
        )
      ]
    )

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "Invalid email or password", payload["message"]
  end

  def test_invalid_explicit_default_locale_falls_back_to_en
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.i18n(
          translations: {
            "en" => {
              "INVALID_EMAIL_OR_PASSWORD" => "Invalid email or password"
            },
            "fr" => {
              "INVALID_EMAIL_OR_PASSWORD" => "FR invalid email or password"
            }
          },
          default_locale: "es",
          detection: ["header"]
        )
      ]
    )

    _status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "Invalid email or password", payload["message"]
  end

  def test_session_detection_falls_through_to_header_when_user_locale_unavailable
    auth = build_auth(
      plugins: [build_i18n_plugin(detection: ["session", "header"], user_locale_field: "locale")],
      user: {
        additional_fields: {
          locale: {type: "string", required: false}
        }
      }
    )

    cookie = BetterAuthTestHelpers.sign_up_cookie(
      auth,
      email: "locale-fallback@example.com",
      extra: {locale: "es"}
    )

    status, _headers, body = auth.api.update_user(
      headers: {"cookie" => cookie, "Accept-Language" => "fr"},
      body: ["not-object"],
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal 400, status
    assert_equal "FR body must be an object", payload["message"]
  end

  def test_translation_preserves_http_status_code
    auth = build_auth(plugins: [build_i18n_plugin])

    status, _headers, body = auth.api.sign_in_email(
      body: {email: "missing@example.com", password: "password123"},
      headers: {"Accept-Language" => "fr"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal 401, status
    assert_equal "INVALID_EMAIL_OR_PASSWORD", payload["code"]
    assert_equal "FR invalid email or password", payload["message"]
  end

  def test_explicit_error_body_code_is_translated_without_reverse_lookup
    custom_plugin = BetterAuth::Plugin.new(
      id: "explicit-code-errors",
      endpoints: {
        trigger_explicit_code: BetterAuth::Endpoint.new(path: "/trigger-explicit-code", method: "GET") do |_ctx|
          raise BetterAuth::APIError.new(
            "BAD_REQUEST",
            code: "BODY_MUST_BE_AN_OBJECT",
            message: "Body must be an object",
            body: {code: "BODY_MUST_BE_AN_OBJECT", message: "Body must be an object"}
          )
        end
      }
    )

    auth = build_auth(plugins: [build_i18n_plugin, custom_plugin])

    _status, _headers, body = auth.api.trigger_explicit_code(
      headers: {"Accept-Language" => "fr"},
      as_response: true
    )

    payload = JSON.parse(body.join)

    assert_equal "BODY_MUST_BE_AN_OBJECT", payload["code"]
    assert_equal "FR body must be an object", payload["message"]
    assert_equal "Body must be an object", payload["originalMessage"]
  end

  def test_direct_api_without_as_response_raises_translated_api_error
    auth = build_auth(plugins: [build_i18n_plugin(detection: ["callback"], get_locale: ->(_ctx) { "fr" })])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_email(body: {email: "missing@example.com", password: "password123"})
    end

    assert_equal "FR invalid email or password", error.message
    assert_equal "Invalid email or password", error.body[:originalMessage]
  end
end
