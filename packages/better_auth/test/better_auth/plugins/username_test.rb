# frozen_string_literal: true

require "json"
require "stringio"
require_relative "../../test_helper"

class BetterAuthPluginsUsernameTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"

  def test_username_sign_up_sign_in_update_and_availability
    auth = build_auth(plugins: [BetterAuth::Plugins.username(min_username_length: 4)])

    _status, headers, _body = auth.api.sign_up_email(
      body: {
        email: "new-email@example.com",
        username: "New_User",
        password: "password123",
        name: "New User"
      },
      as_response: true
    )
    cookie = cookie_header(headers.fetch("set-cookie"))
    session = auth.api.get_session(headers: {"cookie" => cookie})

    assert_equal "new_user", session[:user]["username"]
    assert_equal "New_User", session[:user]["displayUsername"]

    sign_in = auth.api.sign_in_username(body: {username: "NEW_USER", password: "password123"})
    assert_match(/\A[0-9a-f]{32}\z/, sign_in[:token])
    assert_equal "new_user", sign_in[:user]["username"]

    auth.api.update_user(headers: {"cookie" => cookie}, body: {username: "priority_user", displayUsername: "Priority Display"})
    updated = auth.api.get_session(headers: {"cookie" => cookie}, query: {disableCookieCache: true})
    assert_equal "priority_user", updated[:user]["username"]
    assert_equal "Priority Display", updated[:user]["displayUsername"]

    unavailable = auth.api.is_username_available(body: {username: "PRIORITY_USER"})
    assert_equal({available: false}, unavailable)
    available = auth.api.is_username_available(body: {username: "fresh_user"})
    assert_equal({available: true}, available)
  end

  def test_username_rejects_duplicates_and_invalid_values
    auth = build_auth(plugins: [BetterAuth::Plugins.username(min_username_length: 4)])
    auth.api.sign_up_email(body: {email: "one@example.com", username: "first_user", password: "password123", name: "One"})

    duplicate = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "two@example.com", username: "FIRST_USER", password: "password123", name: "Two"})
    end
    assert_equal 422, duplicate.status_code
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["USERNAME_IS_ALREADY_TAKEN"], duplicate.message

    invalid = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "bad@example.com", username: "bad user", password: "password123", name: "Bad"})
    end
    assert_equal 400, invalid.status_code
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["INVALID_USERNAME"], invalid.message

    too_short = assert_raises(BetterAuth::APIError) do
      auth.api.is_username_available(body: {username: "abc"})
    end
    assert_equal 422, too_short.status_code
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["USERNAME_TOO_SHORT"], too_short.message
  end

  def test_username_update_duplicate_rules_match_upstream
    auth = build_auth(plugins: [BetterAuth::Plugins.username(min_username_length: 4)])
    first_cookie = sign_up_cookie(auth, email: "first@example.com", username: "first_user")
    second_cookie = sign_up_cookie(auth, email: "second@example.com", username: "second_user")

    different_user = assert_raises(BetterAuth::APIError) do
      auth.api.update_user(headers: {"cookie" => second_cookie}, body: {username: "FIRST_USER"})
    end
    assert_equal 400, different_user.status_code
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["USERNAME_IS_ALREADY_TAKEN"], different_user.message

    auth.api.update_user(headers: {"cookie" => first_cookie}, body: {username: "FIRST_USER"})
    session = auth.api.get_session(headers: {"cookie" => first_cookie}, query: {disableCookieCache: true})
    assert_equal "first_user", session[:user]["username"]
  end

  def test_username_display_only_and_post_normalization_flow
    display_auth = build_auth(
      plugins: [
        BetterAuth::Plugins.username(
          display_username_validator: ->(display_username) { display_username.match?(/\A[a-zA-Z0-9_\-\s]+\z/) }
        )
      ]
    )
    display_cookie = sign_up_cookie(display_auth, email: "display-only@example.com", display_username: "Test_Username")
    display_session = display_auth.api.get_session(headers: {"cookie" => display_cookie}, query: {disableCookieCache: true})
    assert_equal "test_username", display_session[:user]["username"]
    assert_equal "Test_Username", display_session[:user]["displayUsername"]

    post_auth = build_auth(
      plugins: [
        BetterAuth::Plugins.username(
          validation_order: {username: "post-normalization", display_username: "post-normalization"},
          username_normalization: ->(username) { username.tr(" ", "_").downcase }
        )
      ]
    )
    post_cookie = sign_up_cookie(post_auth, email: "post-normalized@example.com", username: "Post Normalized")
    post_session = post_auth.api.get_session(headers: {"cookie" => post_cookie}, query: {disableCookieCache: true})
    assert_equal "post_normalized", post_session[:user]["username"]
    assert_equal "Post Normalized", post_session[:user]["displayUsername"]
  end

  def test_username_custom_normalization_and_validators
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.username(
          min_username_length: 4,
          username_normalization: ->(value) { value.tr("04", "oa").downcase },
          display_username_normalization: ->(value) { value.downcase },
          display_username_validator: ->(value) { value.match?(/\A[a-zA-Z0-9_\-\s]+\z/) }
        )
      ]
    )

    result = auth.api.sign_up_email(
      body: {
        email: "normal@example.com",
        username: "H4XX0R",
        displayUsername: "Fancy Name",
        password: "password123",
        name: "Normal"
      }
    )

    assert_equal "haxxor", result[:user]["username"]
    assert_equal "fancy name", result[:user]["displayUsername"]

    duplicate = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "copy@example.com", username: "haxxor", password: "password123", name: "Copy"})
    end
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["USERNAME_IS_ALREADY_TAKEN"], duplicate.message

    invalid_display = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "display@example.com", displayUsername: "Invalid!", password: "password123", name: "Display"})
    end
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["INVALID_DISPLAY_USERNAME"], invalid_display.message
  end

  def test_validation_order_uses_raw_value_by_default_and_normalized_value_when_requested
    default_auth = build_auth(plugins: [BetterAuth::Plugins.username(username_normalization: ->(value) { value.tr(" ", "_") })])
    assert_raises(BetterAuth::APIError) do
      default_auth.api.sign_up_email(body: {email: "raw-order@example.com", username: "raw value", password: "password123", name: "Raw"})
    end

    post_auth = build_auth(plugins: [BetterAuth::Plugins.username(validation_order: {username: "post-normalization"}, username_normalization: ->(value) { value.tr(" ", "_") })])
    assert_equal "post_value", post_auth.api.sign_up_email(body: {email: "post-order@example.com", username: "post value", password: "password123", name: "Post"}).fetch(:user).fetch("username")
  end

  def test_post_normalization_sign_in_validates_the_raw_username
    auth = build_auth(plugins: [BetterAuth::Plugins.username(
      validation_order: {username: "post-normalization"},
      username_normalization: ->(value) { value.tr(" ", "_") }
    )])
    created = auth.api.sign_up_email(body: {email: "sign-in-order@example.com", username: "sign in value", password: "password123", name: "Sign In"})
    assert_equal "sign_in_value", created.fetch(:user).fetch("username")

    assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_username(body: {username: "sign in value", password: "password123"})
    end

    signed_in = auth.api.sign_in_username(body: {username: "sign_in_value", password: "password123"})
    assert_equal created.fetch(:user).fetch("id"), signed_in.fetch(:user).fetch("id")
  end

  def test_invalid_display_only_stays_display_only_and_explicit_empty_username_errors
    auth = build_auth(plugins: [BetterAuth::Plugins.username])
    cookie = sign_up_cookie(auth, email: "invalid-display@example.com", display_username: "invalid! value")
    assert_nil auth.api.get_session(headers: {"cookie" => cookie})[:user]["username"]

    error = assert_raises(BetterAuth::APIError) do
      auth.api.sign_up_email(body: {email: "empty-username@example.com", username: "", password: "password123", name: "Empty"})
    end
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["USERNAME_TOO_SHORT"], error.message
  end

  def test_username_email_verification_does_not_leak_until_password_is_valid
    auth = build_auth(
      email_and_password: {enabled: true, require_email_verification: true},
      email_verification: {send_on_sign_up: false},
      plugins: [BetterAuth::Plugins.username]
    )
    auth.api.sign_up_email(body: {email: "unverified@example.com", username: "unverified_user", password: "password123", name: "Unverified"})

    wrong_password = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_username(body: {username: "unverified_user", password: "wrong-password"})
    end
    assert_equal 401, wrong_password.status_code
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["INVALID_USERNAME_OR_PASSWORD"], wrong_password.message

    correct_password = assert_raises(BetterAuth::APIError) do
      auth.api.sign_in_username(body: {username: "unverified_user", password: "password123"})
    end
    assert_equal 403, correct_password.status_code
    assert_equal BetterAuth::Plugins::USERNAME_ERROR_CODES["EMAIL_NOT_VERIFIED"], correct_password.message
  end

  def test_username_demo_flow_works_through_rack_requests
    auth = build_auth(plugins: [BetterAuth::Plugins.username(min_username_length: 4)])

    sign_up_status, _sign_up_headers, sign_up_body = auth.call(
      rack_env(
        "POST",
        "/api/auth/sign-up/email",
        body: JSON.generate(email: "rack-username@example.com", username: "Rack_User", password: "password123", name: "Rack")
      )
    )
    assert_equal 200, sign_up_status
    assert_equal "rack_user", JSON.parse(sign_up_body.join).fetch("user").fetch("username")

    sign_in_status, sign_in_headers, sign_in_body = auth.call(
      rack_env(
        "POST",
        "/api/auth/sign-in/username",
        body: JSON.generate(username: "RACK_USER", password: "password123")
      )
    )
    sign_in = JSON.parse(sign_in_body.join)
    cookie = cookie_header(sign_in_headers.fetch("set-cookie"))

    assert_equal 200, sign_in_status
    assert_match(/\A[0-9a-f]{32}\z/, sign_in.fetch("token"))

    session_status, _session_headers, session_body = auth.call(
      rack_env("GET", "/api/auth/get-session", body: "", extra_headers: {"HTTP_COOKIE" => cookie})
    )
    session = JSON.parse(session_body.join)

    assert_equal 200, session_status
    assert_equal "rack_user", session.fetch("user").fetch("username")
  end

  def test_username_sign_in_honors_callback_url
    auth = build_auth(plugins: [BetterAuth::Plugins.username])
    sign_up_cookie(auth, email: "callback-username@example.com", username: "callback_user")

    _status, headers, body = auth.api.sign_in_username(
      body: {username: "callback_user", password: "password123", callbackURL: "/dashboard"},
      as_response: true
    )

    assert_equal "/dashboard", headers.fetch("location")
    response = JSON.parse(body.join)
    assert_equal true, response.fetch("redirect")
    assert_equal "/dashboard", response.fetch("url")
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def sign_up_cookie(auth, email:, username: nil, display_username: nil)
    body = {email: email, password: "password123", name: "Username User"}
    body[:username] = username if username
    body[:display_username] = display_username if display_username
    _status, headers, _body = auth.api.sign_up_email(body: body, as_response: true)
    cookie_header(headers.fetch("set-cookie"))
  end

  def cookie_header(set_cookie)
    set_cookie.lines.map { |line| line.split(";").first }.join("; ")
  end

  def rack_env(method, path, body:, content_type: "application/json", extra_headers: {})
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(body),
      "CONTENT_TYPE" => content_type,
      "CONTENT_LENGTH" => body.bytesize.to_s,
      "HTTP_ORIGIN" => "http://localhost:3000"
    }.merge(extra_headers)
  end
end
