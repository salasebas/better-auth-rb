# frozen_string_literal: true

require "json"
require "uri"
require_relative "../../test_helper"

class BetterAuthPluginsAnonymousTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"

  def test_anonymous_sign_in_creates_session_and_anonymous_user
    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous])

    status, headers, body = auth.api.sign_in_anonymous(as_response: true)
    data = JSON.parse(body.join)
    cookie = cookie_header(headers.fetch("set-cookie"))
    session = auth.api.get_session(headers: {"cookie" => cookie})

    assert_equal 200, status
    assert_match(/\A[0-9a-f]{32}\z/, data.fetch("token"))
    assert_equal true, data.fetch("user").fetch("isAnonymous")
    assert_equal "Anonymous", data.fetch("user").fetch("name")
    assert_equal true, session[:user]["isAnonymous"]
  end

  def test_anonymous_sign_in_supports_custom_name_email_and_domain
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.anonymous(
          generate_name: ->(_ctx) { "Guest Bee" },
          generate_random_email: -> { "guest@example.test" }
        )
      ]
    )

    result = auth.api.sign_in_anonymous

    assert_equal "Guest Bee", result[:user]["name"]
    assert_equal "guest@example.test", result[:user]["email"]

    domain_auth = build_auth(plugins: [BetterAuth::Plugins.anonymous(email_domain_name: "anon.example")])
    domain_result = domain_auth.api.sign_in_anonymous
    assert_match(/\Atemp-[0-9a-f]{32}@anon\.example\z/, domain_result[:user]["email"])
  end

  def test_anonymous_schema_supports_custom_is_anonymous_field_mapping
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.anonymous(
          schema: {
            user: {
              fields: {
                isAnonymous: "is_anon"
              }
            }
          }
        )
      ]
    )

    schema = BetterAuth::Schema.auth_tables(auth.context.options)
    result = auth.api.sign_in_anonymous

    assert_equal "is_anon", schema.fetch("user").fetch(:fields).fetch("isAnonymous").fetch(:field_name)
    assert_equal true, result[:user]["isAnonymous"]
  end

  def test_anonymous_sign_in_falls_back_when_generators_return_blank_values
    nil_name_auth = build_auth(plugins: [BetterAuth::Plugins.anonymous(generate_name: ->(_ctx) {})])
    empty_name_auth = build_auth(plugins: [BetterAuth::Plugins.anonymous(generate_name: ->(_ctx) { "" })])
    empty_email_auth = build_auth(plugins: [BetterAuth::Plugins.anonymous(generate_random_email: -> { "" })])

    assert_equal "Anonymous", nil_name_auth.api.sign_in_anonymous[:user]["name"]
    assert_equal "Anonymous", empty_name_auth.api.sign_in_anonymous[:user]["name"]
    assert_match(/\Atemp@[0-9a-f]{32}\.com\z/, empty_email_auth.api.sign_in_anonymous[:user]["email"])
  end

  def test_anonymous_sign_in_rejects_truthy_non_string_generated_email
    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous(generate_random_email: -> { true })])

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_anonymous
    end
    assert_equal 400, error.status_code
    assert_equal BetterAuth::Plugins::ANONYMOUS_ERROR_CODES["INVALID_EMAIL_FORMAT"], error.message
  end

  def test_anonymous_sign_in_rejects_invalid_generated_email_and_repeat_anonymous_session
    invalid_auth = build_auth(plugins: [BetterAuth::Plugins.anonymous(generate_random_email: -> { "not-an-email" })])

    invalid = assert_raises(BetterAuth::APIError) do
      invalid_auth.api.sign_in_anonymous
    end
    assert_equal 400, invalid.status_code
    assert_equal BetterAuth::Plugins::ANONYMOUS_ERROR_CODES["INVALID_EMAIL_FORMAT"], invalid.message

    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous])
    _status, headers, _body = auth.api.sign_in_anonymous(as_response: true)
    cookie = cookie_header(headers.fetch("set-cookie"))

    repeated = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_anonymous(headers: {"cookie" => cookie})
    end
    assert_equal 400, repeated.status_code
    assert_equal BetterAuth::Plugins::ANONYMOUS_ERROR_CODES["ANONYMOUS_USERS_CANNOT_SIGN_IN_AGAIN_ANONYMOUSLY"], repeated.message
  end

  def test_delete_anonymous_user_removes_user_session_and_cookie
    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous])
    _status, headers, _body = auth.api.sign_in_anonymous(as_response: true)
    cookie = cookie_header(headers.fetch("set-cookie"))
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]

    status, response_headers, body = auth.api.delete_anonymous_user(headers: {"cookie" => cookie}, as_response: true)

    assert_equal 200, status
    assert_equal({"success" => true}, JSON.parse(body.join))
    assert_nil auth.context.internal_adapter.find_user_by_id(user_id)
    assert_nil auth.api.get_session(headers: {"cookie" => cookie})
    assert_includes response_headers.fetch("set-cookie"), "better-auth.session_token="
  end

  def test_delete_anonymous_user_rejects_disabled_or_non_anonymous_users
    disabled = build_auth(plugins: [BetterAuth::Plugins.anonymous(disable_delete_anonymous_user: true)])
    _status, disabled_headers, _body = disabled.api.sign_in_anonymous(as_response: true)
    disabled_cookie = cookie_header(disabled_headers.fetch("set-cookie"))

    disabled_error = assert_raises(BetterAuth::APIError) do
      disabled.api.delete_anonymous_user(headers: {"cookie" => disabled_cookie})
    end
    assert_equal 400, disabled_error.status_code
    assert_equal BetterAuth::Plugins::ANONYMOUS_ERROR_CODES["DELETE_ANONYMOUS_USER_DISABLED"], disabled_error.message

    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous])
    real_cookie = sign_up_cookie(auth, email: "real@example.com")
    forbidden = assert_raises(BetterAuth::APIError) do
      auth.api.delete_anonymous_user(headers: {"cookie" => real_cookie})
    end
    assert_equal 403, forbidden.status_code
    assert_equal BetterAuth::Plugins::ANONYMOUS_ERROR_CODES["USER_IS_NOT_ANONYMOUS"], forbidden.message
  end

  def test_real_sign_in_links_and_deletes_previous_anonymous_user
    link_calls = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.anonymous(
          on_link_account: ->(data) { link_calls << data }
        )
      ]
    )
    auth.api.sign_up_email(body: {email: "linked@example.com", password: "password123", name: "Linked"})
    _status, anon_headers, _body = auth.api.sign_in_anonymous(as_response: true)
    anon_cookie = cookie_header(anon_headers.fetch("set-cookie"))
    anon_user_id = auth.api.get_session(headers: {"cookie" => anon_cookie})[:user]["id"]

    status, real_headers, body = auth.api.sign_in_email(
      headers: {"cookie" => anon_cookie},
      body: {email: "linked@example.com", password: "password123"},
      as_response: true
    )
    data = JSON.parse(body.join)
    real_cookie = cookie_header(real_headers.fetch("set-cookie"))

    assert_equal 200, status
    assert_equal "linked@example.com", data.fetch("user").fetch("email")
    assert_equal false, data.fetch("user").fetch("isAnonymous")
    assert_nil auth.context.internal_adapter.find_user_by_id(anon_user_id)
    assert_equal 1, link_calls.length
    assert_equal anon_user_id, link_calls.first[:anonymous_user][:user]["id"]
    assert_equal data.fetch("user").fetch("id"), link_calls.first[:new_user][:user]["id"]
    assert_equal "linked@example.com", auth.api.get_session(headers: {"cookie" => real_cookie})[:user]["email"]
  end

  def test_linking_keeps_anonymous_user_when_deletion_is_disabled
    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous(disable_delete_anonymous_user: true)])
    anon_cookie, anon_user_id = sign_in_anonymous_cookie_and_user_id(auth)
    new_user = create_real_user(auth, "disabled-link@example.com")
    new_session = auth.context.internal_adapter.create_session(new_user["id"])
    ctx = anonymous_link_context(auth, anon_cookie, {session: new_session, user: new_user})
    set_signed_session_cookie(ctx, new_session["token"])

    BetterAuth::Plugins.link_anonymous_user(ctx, auth.context.options.plugins.first.options)

    assert auth.context.internal_adapter.find_user_by_id(anon_user_id)
  end

  def test_linking_keeps_anonymous_user_for_same_user_new_session
    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous])
    anon_cookie, anon_user_id = sign_in_anonymous_cookie_and_user_id(auth)
    anon_user = auth.context.internal_adapter.find_user_by_id(anon_user_id)
    new_session = auth.context.internal_adapter.create_session(anon_user_id)
    ctx = anonymous_link_context(auth, anon_cookie, {session: new_session, user: anon_user})
    set_signed_session_cookie(ctx, new_session["token"])

    BetterAuth::Plugins.link_anonymous_user(ctx, auth.context.options.plugins.first.options)

    assert auth.context.internal_adapter.find_user_by_id(anon_user_id)
  end

  def test_linking_keeps_anonymous_user_when_new_session_is_still_anonymous
    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous])
    anon_cookie, anon_user_id = sign_in_anonymous_cookie_and_user_id(auth)
    new_user = create_anonymous_user(auth, "second-anon@example.com")
    new_session = auth.context.internal_adapter.create_session(new_user["id"])
    ctx = anonymous_link_context(auth, anon_cookie, {session: new_session, user: new_user})
    set_signed_session_cookie(ctx, new_session["token"])

    BetterAuth::Plugins.link_anonymous_user(ctx, auth.context.options.plugins.first.options)

    assert auth.context.internal_adapter.find_user_by_id(anon_user_id)
  end

  def test_linking_ignores_set_cookie_entries_that_only_contain_session_cookie_name_as_substring
    auth = build_auth(plugins: [BetterAuth::Plugins.anonymous])
    anon_cookie, anon_user_id = sign_in_anonymous_cookie_and_user_id(auth)
    new_user = create_real_user(auth, "substring-cookie@example.com")
    new_session = auth.context.internal_adapter.create_session(new_user["id"])
    ctx = anonymous_link_context(auth, anon_cookie, {session: new_session, user: new_user})
    ctx.set_cookie("not-#{auth.context.auth_cookies[:session_token].name}", "value")

    BetterAuth::Plugins.link_anonymous_user(ctx, auth.context.options.plugins.first.options)

    assert auth.context.internal_adapter.find_user_by_id(anon_user_id)
  end

  def test_social_callback_links_and_deletes_previous_anonymous_user
    link_calls = []
    auth = build_auth(
      social_providers: {
        github: {
          id: "github",
          create_authorization_url: lambda do |data|
            "https://github.example/oauth?state=#{URI.encode_www_form_component(data[:state])}"
          end,
          validate_authorization_code: ->(_data) { {accessToken: "oauth-access"} },
          get_user_info: ->(_tokens) {
            {
              user: {
                id: "gh-anonymous-link",
                email: "social-linked@example.com",
                name: "Social Linked",
                emailVerified: true
              }
            }
          }
        }
      },
      plugins: [
        BetterAuth::Plugins.anonymous(
          on_link_account: ->(data) { link_calls << data }
        )
      ]
    )
    _status, anon_headers, _body = auth.api.sign_in_anonymous(as_response: true)
    anon_cookie = cookie_header(anon_headers.fetch("set-cookie"))
    anon_user_id = auth.api.get_session(headers: {"cookie" => anon_cookie})[:user]["id"]
    sign_in = auth.api.sign_in_social(
      headers: {"cookie" => anon_cookie},
      body: {provider: "github", callbackURL: "/dashboard", disableRedirect: true}
    )
    state = URI.decode_www_form(URI.parse(sign_in.fetch(:url)).query).assoc("state").last

    status, headers, _body = auth.api.callback_oauth(
      headers: {"cookie" => anon_cookie},
      params: {providerId: "github"},
      query: {code: "oauth-code", state: state},
      as_response: true
    )
    real_cookie = cookie_header(headers.fetch("set-cookie"))

    assert_equal 302, status
    assert_equal "/dashboard", headers["location"]
    assert_nil auth.context.internal_adapter.find_user_by_id(anon_user_id)
    assert_equal 1, link_calls.length
    assert_equal anon_user_id, link_calls.first[:anonymous_user][:user]["id"]
    assert_equal "social-linked@example.com", link_calls.first[:new_user][:user]["email"]
    assert_equal "social-linked@example.com", auth.api.get_session(headers: {"cookie" => real_cookie})[:user]["email"]
  end

  def test_magic_link_verify_links_and_deletes_previous_anonymous_user
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.anonymous,
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )
    _status, anon_headers, _body = auth.api.sign_in_anonymous(as_response: true)
    anon_cookie = cookie_header(anon_headers.fetch("set-cookie"))
    anon_user_id = auth.api.get_session(headers: {"cookie" => anon_cookie})[:user]["id"]

    auth.api.sign_in_magic_link(headers: {"cookie" => anon_cookie}, body: {email: "magic-linked@example.com", name: "Magic Linked"})
    status, headers, _body = auth.api.magic_link_verify(
      headers: {"cookie" => anon_cookie},
      query: {token: sent.first[:token], callbackURL: "/dashboard"},
      as_response: true
    )
    real_cookie = cookie_header(headers.fetch("set-cookie"))

    assert_equal 302, status
    assert_nil auth.context.internal_adapter.find_user_by_id(anon_user_id)
    assert_equal "magic-linked@example.com", auth.api.get_session(headers: {"cookie" => real_cookie})[:user]["email"]
  end

  def test_sign_in_email_otp_links_and_deletes_previous_anonymous_user
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.anonymous,
        BetterAuth::Plugins.email_otp(send_verification_otp: ->(data, _ctx = nil) { sent << data })
      ]
    )
    _status, anon_headers, _body = auth.api.sign_in_anonymous(as_response: true)
    anon_cookie = cookie_header(anon_headers.fetch("set-cookie"))
    anon_user_id = auth.api.get_session(headers: {"cookie" => anon_cookie})[:user]["id"]

    auth.api.send_verification_otp(body: {email: "otp-linked@example.com", type: "sign-in"})
    result = auth.api.sign_in_email_otp(
      headers: {"cookie" => anon_cookie},
      body: {email: "otp-linked@example.com", otp: sent.last[:otp], name: "OTP Linked"},
      return_headers: true
    )
    real_cookie = [anon_cookie, cookie_header(result.fetch(:headers).fetch("set-cookie"))].join("; ")

    assert_nil auth.context.internal_adapter.find_user_by_id(anon_user_id)
    assert_equal "otp-linked@example.com", auth.api.get_session(headers: {"cookie" => real_cookie})[:user]["email"]
    assert_equal true, auth.api.get_session(headers: {"cookie" => real_cookie})[:user]["emailVerified"]
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def sign_up_cookie(auth, email:)
    _status, headers, _body = auth.api.sign_up_email(
      body: {email: email, password: "password123", name: "Real User"},
      as_response: true
    )
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end

  def sign_in_anonymous_cookie_and_user_id(auth)
    _status, headers, _body = auth.api.sign_in_anonymous(as_response: true)
    cookie = cookie_header(headers.fetch("set-cookie"))
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    [cookie, user_id]
  end

  def create_real_user(auth, email)
    auth.context.internal_adapter.create_user(
      email: email,
      emailVerified: false,
      isAnonymous: false,
      name: "Linked User",
      createdAt: Time.now,
      updatedAt: Time.now
    )
  end

  def create_anonymous_user(auth, email)
    auth.context.internal_adapter.create_user(
      email: email,
      emailVerified: false,
      isAnonymous: true,
      name: "Anonymous",
      createdAt: Time.now,
      updatedAt: Time.now
    )
  end

  def anonymous_link_context(auth, cookie, new_session)
    auth.context.reset_runtime!
    auth.context.set_new_session(new_session)
    BetterAuth::Endpoint::Context.new(
      path: "/sign-in/email",
      method: "POST",
      query: {},
      body: {},
      params: {},
      headers: {"cookie" => cookie},
      context: auth.context
    )
  end

  def set_signed_session_cookie(ctx, token)
    cookie = ctx.context.auth_cookies[:session_token]
    ctx.set_signed_cookie(cookie.name, token, ctx.context.secret, cookie.attributes)
  end
end
