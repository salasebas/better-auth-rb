# frozen_string_literal: true

require_relative "../test_helper"
require "stringio"

class BetterAuthAuthTest < Minitest::Test
  SECRET = "test-secret-that-is-long-enough-for-validation"

  def test_auth_returns_public_api_shape
    auth = BetterAuth.auth(base_url: "http://localhost:3000", secret: SECRET)

    assert_instance_of BetterAuth::Auth, auth
    assert_respond_to auth, :handler
    assert_respond_to auth, :api
    assert_respond_to auth, :options
    assert_respond_to auth, :context
    assert_respond_to auth, :error_codes
    assert_equal "/api/auth", auth.options.base_path
    assert_equal "http://localhost:3000/api/auth", auth.context.base_url
  end

  def test_auth_is_rack_callable_alias_to_handler
    auth = BetterAuth.auth(base_url: "http://localhost:3000", secret: SECRET)

    status, headers, body = auth.call(
      "REQUEST_METHOD" => "GET",
      "PATH_INFO" => "/api/auth/unknown",
      "rack.input" => StringIO.new
    )

    assert_equal 404, status
    assert_equal "application/json", headers["content-type"]
    assert_equal ["{\"error\":\"Not Found\"}"], body
  end

  def test_plugin_error_codes_merge_with_base_error_codes
    auth = BetterAuth.auth(
      base_url: "http://localhost:3000",
      secret: SECRET,
      plugins: [
        {
          id: "custom-plugin",
          error_codes: {
            "CUSTOM_ERROR" => "Custom error message"
          }
        }
      ]
    )

    assert_equal "User not found", auth.error_codes["USER_NOT_FOUND"]
    assert_equal "Custom error message", auth.error_codes["CUSTOM_ERROR"]
  end

  def test_inferred_base_url_uses_valid_trusted_proxy_headers
    captured = []
    auth = BetterAuth.auth(
      secret: SECRET,
      base_url: "https://auth.example.com",
      serving_origins: ["https://preview.example.com:8443"],
      advanced: {trusted_proxy_headers: true},
      plugins: [capture_base_url_plugin(captured)]
    )

    status, = auth.call(rack_env("GET", "/api/auth/capture-base-url", headers: {
      "HTTP_X_FORWARDED_HOST" => "preview.example.com:8443",
      "HTTP_X_FORWARDED_PROTO" => "https",
      "HTTP_HOST" => "localhost:3000"
    }))

    assert_equal 200, status
    assert_equal "https://preview.example.com:8443/api/auth", captured.first
    assert_equal "https://auth.example.com/api/auth", auth.context.base_url
  end

  def test_inferred_base_url_rejects_malicious_forwarded_and_host_headers
    captured = []
    auth = BetterAuth.auth(
      secret: SECRET,
      base_url: "https://auth.example.com",
      advanced: {trusted_proxy_headers: true},
      plugins: [capture_base_url_plugin(captured)]
    )

    status, = auth.call(rack_env("GET", "/api/auth/capture-base-url", headers: {
      "HTTP_X_FORWARDED_HOST" => "../../../etc/passwd",
      "HTTP_X_FORWARDED_PROTO" => "https",
      "HTTP_HOST" => "<script>alert('xss')</script>",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000"
    }))

    assert_equal 200, status
    assert_equal "https://auth.example.com/api/auth", captured.first
    assert_equal "https://auth.example.com/api/auth", auth.context.base_url
  end

  private

  def capture_base_url_plugin(captured)
    {
      id: "capture-base-url",
      endpoints: {
        capture_base_url: BetterAuth::Endpoint.new(path: "/capture-base-url", method: "GET") do |ctx|
          captured << ctx.context.base_url
          ctx.json({ok: true})
        end
      }
    }
  end

  def rack_env(method, path, headers: {})
    {
      "REQUEST_METHOD" => method,
      "PATH_INFO" => path,
      "QUERY_STRING" => "",
      "SERVER_NAME" => "localhost",
      "SERVER_PORT" => "3000",
      "REMOTE_ADDR" => "127.0.0.1",
      "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(""),
      "CONTENT_LENGTH" => "0"
    }.merge(headers)
  end
end
