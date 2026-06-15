# frozen_string_literal: true

require "json"
require "stringio"
require "uri"
require_relative "../../test_helper"

class BetterAuthPluginsMagicLinkTest < Minitest::Test
  SECRET = "phase-eight-secret-with-enough-entropy-123"

  def test_magic_link_sends_and_verifies_existing_user
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )
    auth.api.sign_up_email(body: {email: "magic@example.com", password: "password123", name: "Magic"})

    assert_equal({status: true}, auth.api.sign_in_magic_link(body: {email: "magic@example.com", callbackURL: "/dashboard"}))
    assert_equal "magic@example.com", sent.first[:email]
    assert_includes sent.first[:url], "http://localhost:3000/api/auth/magic-link/verify"
    assert_includes sent.first[:url], "callbackURL=%2Fdashboard"

    status, headers, _body = auth.api.magic_link_verify(
      query: {token: sent.first[:token], callbackURL: "/dashboard"},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/dashboard", headers.fetch("location")
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="

    reused = auth.api.magic_link_verify(query: {token: sent.first[:token]}, as_response: true)
    assert_equal 302, reused.first
    assert_includes reused[1].fetch("location"), "error=ATTEMPTS_EXCEEDED"
  end

  def test_magic_link_signs_up_new_user_and_verifies_email
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )

    auth.api.sign_in_magic_link(body: {email: "new-magic@example.com", name: "New Magic"})
    result = auth.api.magic_link_verify(query: {token: sent.first[:token]})

    assert_match(/\A[0-9a-f]{32}\z/, result[:token])
    assert_equal "new-magic@example.com", result[:user]["email"]
    assert_equal "New Magic", result[:user]["name"]
    assert_equal true, result[:user]["emailVerified"]
  end

  def test_magic_link_redirects_new_users_to_new_user_callback_url
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )

    auth.api.sign_in_magic_link(
      body: {
        email: "new-callback-magic@example.com",
        name: "Callback Magic",
        callbackURL: "/dashboard",
        newUserCallbackURL: "/welcome"
      }
    )
    status, headers, _body = auth.api.magic_link_verify(
      query: {
        token: sent.first[:token],
        callbackURL: "/dashboard",
        newUserCallbackURL: "/welcome"
      },
      as_response: true
    )

    assert_equal 302, status
    assert_equal "/welcome", headers.fetch("location")
  end

  def test_magic_link_verifies_existing_unverified_user
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )
    auth.api.sign_up_email(body: {email: "unverified-magic@example.com", password: "password123", name: "Unverified"})
    user = auth.context.internal_adapter.find_user_by_email("unverified-magic@example.com")[:user]
    assert_equal false, user["emailVerified"]

    auth.api.sign_in_magic_link(body: {email: "unverified-magic@example.com"})
    result = auth.api.magic_link_verify(query: {token: sent.first[:token]})

    assert_equal true, result[:user]["emailVerified"]
    updated = auth.context.internal_adapter.find_user_by_email("unverified-magic@example.com")[:user]
    assert_equal true, updated["emailVerified"]
  end

  def test_magic_link_verifies_last_issued_token_and_sets_cookie_for_json_response
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )
    auth.api.sign_up_email(body: {email: "latest-magic@example.com", password: "password123", name: "Latest Magic"})

    3.times { auth.api.sign_in_magic_link(body: {email: "latest-magic@example.com"}) }
    latest_token = sent.last.fetch(:token)

    status, headers, body = auth.api.magic_link_verify(query: {token: latest_token}, as_response: true)

    assert_equal 200, status
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    parsed = JSON.parse(body.join)
    assert_match(/\A[0-9a-f]{32}\z/, parsed.fetch("token"))
    assert_match(/\A[0-9a-f]{32}\z/, parsed.fetch("session").fetch("token"))
    assert_equal "latest-magic@example.com", parsed.fetch("user").fetch("email")
  end

  def test_magic_link_forwards_metadata_to_sender
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )

    auth.api.sign_in_magic_link(body: {email: "metadata@example.com", metadata: {source: "cli", nested: {plan: "parity"}}})

    assert_equal({source: "cli", nested: {plan: "parity"}}, sent.first.fetch(:metadata))
  end

  def test_magic_link_respects_allowed_attempts
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(
          allowed_attempts: 3,
          send_magic_link: ->(data, _ctx = nil) { sent << data }
        )
      ]
    )
    auth.api.sign_up_email(body: {email: "attempts@example.com", password: "password123", name: "Attempts"})
    auth.api.sign_in_magic_link(body: {email: "attempts@example.com"})

    3.times do
      status, _headers, _body = auth.api.magic_link_verify(query: {token: sent.first[:token]}, as_response: true)
      assert_equal 200, status
    end
    exceeded = auth.api.magic_link_verify(query: {token: sent.first[:token], errorCallbackURL: "/error"}, as_response: true)

    assert_equal 302, exceeded.first
    assert_includes exceeded[1].fetch("location"), "error=ATTEMPTS_EXCEEDED"
  end

  def test_magic_link_allows_unlimited_attempts
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(
          allowed_attempts: Float::INFINITY,
          send_magic_link: ->(data, _ctx = nil) { sent << data }
        )
      ]
    )
    auth.api.sign_up_email(body: {email: "infinite@example.com", password: "password123", name: "Infinite"})
    auth.api.sign_in_magic_link(body: {email: "infinite@example.com"})

    4.times do
      status, _headers, _body = auth.api.magic_link_verify(query: {token: sent.first[:token]}, as_response: true)
      assert_equal 200, status
    end
  end

  def test_magic_link_redirects_for_expired_invalid_and_disabled_signup
    sent = []
    expired_auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(
          expires_in: -1,
          send_magic_link: ->(data, _ctx = nil) { sent << data }
        )
      ]
    )
    expired_auth.api.sign_in_magic_link(body: {email: "expired@example.com"})
    expired = expired_auth.api.magic_link_verify(query: {token: sent.first[:token], errorCallbackURL: "/error-page?foo=bar"}, as_response: true)

    assert_equal 302, expired.first
    assert_includes expired[1].fetch("location"), "/error-page?foo=bar&error=EXPIRED_TOKEN"

    disabled_sent = []
    disabled = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(
          disable_sign_up: true,
          send_magic_link: ->(data, _ctx = nil) { disabled_sent << data }
        )
      ]
    )
    disabled.api.sign_in_magic_link(body: {email: "disabled-new@example.com"})
    response = disabled.api.magic_link_verify(query: {token: disabled_sent.first[:token]}, as_response: true)

    assert_equal 302, response.first
    assert_includes response[1].fetch("location"), "error=new_user_signup_disabled"
  end

  def test_magic_link_supports_custom_and_hashed_token_storage
    sent = []
    hashed = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(
          store_token: "hashed",
          generate_token: ->(_email) { "hashed-token" },
          send_magic_link: ->(data, _ctx = nil) { sent << data }
        )
      ]
    )

    hashed.api.sign_in_magic_link(body: {email: "hash@example.com"})
    assert hashed.context.internal_adapter.find_verification_value(BetterAuth::Crypto.sha256("hashed-token", encoding: :base64url))
    assert_nil hashed.context.internal_adapter.find_verification_value("hashed-token")

    custom_sent = []
    custom = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(
          store_token: {type: "custom-hasher", hash: ->(token) { "#{token}:stored" }},
          generate_token: ->(_email) { "custom-token" },
          send_magic_link: ->(data, _ctx = nil) { custom_sent << data }
        )
      ]
    )
    custom.api.sign_in_magic_link(body: {email: "custom@example.com"})

    assert_equal "custom-token", custom_sent.first[:token]
    assert custom.context.internal_adapter.find_verification_value("custom-token:stored")
  end

  def test_magic_link_rejects_untrusted_verify_callback_url
    sent = []
    auth = build_auth(
      trusted_origins: ["http://localhost:3000"],
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )
    auth.api.sign_in_magic_link(body: {email: "origin@example.com"})

    error = assert_raises(BetterAuth::APIError) do
      auth.api.magic_link_verify(query: {token: sent.first[:token], callbackURL: "http://malicious.com"})
    end

    assert_equal 403, error.status_code
    assert_equal "Invalid callbackURL", error.message
  end

  def test_magic_link_secondary_storage_string_flow_verifies_and_signs_up
    storage = StringStorage.new
    sent = []
    auth = build_auth(
      secondary_storage: storage,
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )
    auth.api.sign_up_email(body: {email: "secondary-magic@example.com", password: "password123", name: "Secondary Magic"})

    auth.api.sign_in_magic_link(body: {email: "secondary-magic@example.com"})
    assert verification_keys(storage).any?
    status, headers, _body = auth.api.magic_link_verify(query: {token: sent.last[:token]}, as_response: true)

    assert_equal 200, status
    assert_includes headers.fetch("set-cookie"), "better-auth.session_token="

    auth.api.sign_in_magic_link(body: {email: "secondary-new-magic@example.com", name: "Secondary New"})
    result = auth.api.magic_link_verify(query: {token: sent.last[:token]})

    assert_match(/\A[0-9a-f]{32}\z/, result[:token])
    assert_equal "secondary-new-magic@example.com", result[:user]["email"]
    assert_equal "Secondary New", result[:user]["name"]
    assert_equal true, result[:user]["emailVerified"]
  end

  def test_magic_link_secondary_storage_tracks_attempts_and_deletes_expired_tokens
    storage = StringStorage.new
    sent = []
    auth = build_auth(
      secondary_storage: storage,
      plugins: [
        BetterAuth::Plugins.magic_link(
          allowed_attempts: 2,
          send_magic_link: ->(data, _ctx = nil) { sent << data }
        )
      ]
    )
    auth.api.sign_up_email(body: {email: "secondary-attempts@example.com", password: "password123", name: "Secondary Attempts"})
    auth.api.sign_in_magic_link(body: {email: "secondary-attempts@example.com"})
    token = sent.last[:token]

    2.times do
      status, _headers, _body = auth.api.magic_link_verify(query: {token: token}, as_response: true)
      assert_equal 200, status
    end
    exceeded = auth.api.magic_link_verify(query: {token: token, errorCallbackURL: "/error"}, as_response: true)

    assert_equal 302, exceeded.first
    assert_includes exceeded[1].fetch("location"), "error=ATTEMPTS_EXCEEDED"
    assert_empty verification_keys(storage)

    expired_storage = StringStorage.new
    expired_sent = []
    expired_auth = build_auth(
      secondary_storage: expired_storage,
      plugins: [
        BetterAuth::Plugins.magic_link(
          expires_in: 2,
          send_magic_link: ->(data, _ctx = nil) { expired_sent << data }
        )
      ]
    )
    expired_auth.api.sign_in_magic_link(body: {email: "secondary-expired@example.com"})
    expired_token = expired_sent.last[:token]
    sleep 2.1
    expired = expired_auth.api.magic_link_verify(query: {token: expired_token, errorCallbackURL: "/error"}, as_response: true)

    assert_equal 302, expired.first
    assert_includes expired[1].fetch("location"), "error=EXPIRED_TOKEN"
    assert_empty verification_keys(expired_storage)
  end

  def test_magic_link_secondary_storage_preparsed_objects_verify_and_track_attempts
    storage = ObjectStorage.new
    sent = []
    auth = build_auth(
      secondary_storage: storage,
      plugins: [
        BetterAuth::Plugins.magic_link(
          allowed_attempts: 2,
          send_magic_link: ->(data, _ctx = nil) { sent << data }
        )
      ]
    )
    auth.api.sign_up_email(body: {email: "object-magic@example.com", password: "password123", name: "Object Magic"})
    auth.api.sign_in_magic_link(body: {email: "object-magic@example.com"})
    token = sent.last[:token]

    2.times do
      status, headers, _body = auth.api.magic_link_verify(query: {token: token}, as_response: true)
      assert_equal 200, status
      assert_includes headers.fetch("set-cookie"), "better-auth.session_token="
    end
    exceeded = auth.api.magic_link_verify(query: {token: token, errorCallbackURL: "/error"}, as_response: true)

    assert_equal 302, exceeded.first
    assert_includes exceeded[1].fetch("location"), "error=ATTEMPTS_EXCEEDED"
    assert_empty verification_keys(storage)
  end

  def test_magic_link_demo_flow_works_through_rack_requests
    sent = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )

    sign_in_status, _sign_in_headers, sign_in_body = auth.call(
      rack_env(
        "POST",
        "/api/auth/sign-in/magic-link",
        body: JSON.generate(email: "rack-magic@example.com", name: "Rack Magic", callbackURL: "/dashboard")
      )
    )

    assert_equal 200, sign_in_status
    assert_equal({"status" => true}, JSON.parse(sign_in_body.join))
    assert_equal "rack-magic@example.com", sent.first[:email]

    verify_status, verify_headers, _verify_body = auth.call(
      rack_env("GET", "/api/auth/magic-link/verify", query: Rack::Utils.build_query(token: sent.first[:token], callbackURL: "/dashboard"), body: "")
    )

    assert_equal 302, verify_status
    assert_equal "/dashboard", verify_headers.fetch("location")
    assert_includes verify_headers.fetch("set-cookie"), "better-auth.session_token="
  end

  def test_magic_link_send_passes_context_to_sender
    captured = []
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(
          send_magic_link: lambda { |data, ctx|
            captured << {email: data[:email], has_context: !ctx.nil?, path: ctx&.path}
          }
        )
      ]
    )

    auth.api.sign_in_magic_link(body: {email: "context-magic@example.com"})

    assert_equal "context-magic@example.com", captured.first[:email]
    assert_equal true, captured.first[:has_context]
    assert_equal "/sign-in/magic-link", captured.first[:path]
  end

  def test_magic_link_empty_token_redirects_with_invalid_token
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(_data, _ctx = nil) {})
      ]
    )

    status, headers, _body = auth.api.magic_link_verify(
      query: {token: "", errorCallbackURL: "/error"},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "/error"
    assert_includes headers.fetch("location"), "error=INVALID_TOKEN"
  end

  def test_magic_link_malformed_verification_redirects_with_invalid_token
    auth = build_auth(
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(_data, _ctx = nil) {})
      ]
    )
    auth.context.internal_adapter.create_verification_value(
      identifier: "broken-token",
      value: "not-json",
      expiresAt: Time.now + 300
    )

    status, headers, _body = auth.api.magic_link_verify(
      query: {token: "broken-token", errorCallbackURL: "/broken-error"},
      as_response: true
    )

    assert_equal 302, status
    assert_includes headers.fetch("location"), "/broken-error"
    assert_includes headers.fetch("location"), "error=INVALID_TOKEN"
  end

  def test_magic_link_accepts_trusted_absolute_callback_urls
    sent = []
    auth = build_auth(
      trusted_origins: ["http://localhost:3000"],
      plugins: [
        BetterAuth::Plugins.magic_link(send_magic_link: ->(data, _ctx = nil) { sent << data })
      ]
    )
    auth.api.sign_up_email(body: {email: "trusted-callback@example.com", password: "password123", name: "Trusted"})
    auth.api.sign_in_magic_link(body: {email: "trusted-callback@example.com"})

    status, headers, _body = auth.api.magic_link_verify(
      query: {token: sent.first[:token], callbackURL: "http://localhost:3000/safe"},
      as_response: true
    )

    assert_equal 302, status
    assert_equal "http://localhost:3000/safe", headers.fetch("location")
  end

  def test_magic_link_verify_route_uses_plugin_rate_limits
    auth = build_auth(
      rate_limit: {enabled: true},
      plugins: [
        BetterAuth::Plugins.magic_link(
          rate_limit: {window: 60, max: 1},
          send_magic_link: ->(_data, _ctx = nil) {}
        )
      ]
    )
    auth.context.internal_adapter.create_verification_value(
      identifier: "rate-limit-token",
      value: JSON.generate(email: "rate-verify@example.com", attempt: 0),
      expiresAt: Time.now + 300
    )

    statuses = 2.times.map do
      auth.call(rack_env("GET", "/api/auth/magic-link/verify", query: "token=rate-limit-token", body: "")).first
    end

    assert_equal [200, 429], statuses
  end

  private

  def build_auth(options = {})
    email_and_password = {enabled: true}.merge(options.fetch(:email_and_password, {}))
    BetterAuth.auth({base_url: "http://localhost:3000", secret: SECRET, database: :memory}.merge(options).merge(email_and_password: email_and_password))
  end

  def verification_keys(storage)
    storage.keys.grep(/\Averification:/)
  end

  def rack_env(method, path, body:, query: "", content_type: "application/json", extra_headers: {})
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => query,
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

  class StringStorage
    def initialize
      @store = {}
    end

    def set(key, value, _ttl = nil)
      @store[key] = value
    end

    def get(key)
      @store[key]
    end

    def delete(key)
      @store.delete(key)
    end

    def keys
      @store.keys
    end
  end

  class ObjectStorage
    def initialize
      @store = {}
    end

    def set(key, value, _ttl = nil)
      @store[key] = JSON.parse(value)
    rescue JSON::ParserError
      @store[key] = value
    end

    def get(key)
      @store[key]
    end

    def delete(key)
      @store.delete(key)
    end

    def keys
      @store.keys
    end
  end
end
