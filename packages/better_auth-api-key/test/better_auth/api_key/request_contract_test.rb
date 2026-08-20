# frozen_string_literal: true

require_relative "test_support"

class BetterAuthAPIKeyRequestContractTest < Minitest::Test
  include APIKeyTestSupport

  def test_http_body_contracts_reject_malformed_shapes_and_types_before_handlers
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "request-contract-body@example.com")
    cases = [
      ["/api-key/create", [], "[body] Invalid input: expected object, received array"],
      ["/api-key/create", {expiresIn: "86400"}, "[body.expiresIn] Invalid input: expected number, received string"],
      ["/api-key/create", {prefix: "bad prefix"}, "[body.prefix] Invalid prefix format, must be alphanumeric and contain only underscores and hyphens."],
      ["/api-key/verify", {key: 7}, "[body.key] Invalid input: expected string, received number"],
      ["/api-key/update", {keyId: 7}, "[body.keyId] Invalid input: expected string, received number"],
      ["/api-key/delete", {keyId: 7}, "[body.keyId] Invalid input: expected string, received number"]
    ]

    cases.each do |path, request_body, message|
      status, body = rack_json_response(auth, "POST", path, body: request_body, cookie: cookie)

      assert_equal 400, status, path
      assert_equal({"code" => "VALIDATION_ERROR", "message" => message}, body, path)
    end
  end

  def test_http_body_contracts_reject_json_null_and_false_before_handlers
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "request-contract-falsy-body@example.com")
    cases = [
      ["null", "null"],
      ["false", "boolean"]
    ]

    %w[/api-key/create /api-key/update /api-key/delete].each do |path|
      cases.each do |payload, input_type|
        status, body = rack_raw_json_response(auth, "POST", path, payload: payload, cookie: cookie)

        assert_equal 400, status, "#{path} #{payload}"
        assert_equal(
          {"code" => "VALIDATION_ERROR", "message" => "[body] Invalid input: expected object, received #{input_type}"},
          body,
          "#{path} #{payload}"
        )
      end
    end
  end

  def test_direct_contracts_distinguish_explicit_nil_and_false_from_omitted_inputs
    auth = build_api_key_auth(default_key_length: 12)
    body_endpoints = %i[create_api_key verify_api_key update_api_key delete_api_key]

    body_endpoints.each do |endpoint|
      {nil => "null", false => "boolean"}.each do |input, input_type|
        error = assert_raises(BetterAuth::APIError) { auth.api.public_send(endpoint, body: input) }

        assert_equal "VALIDATION_ERROR", error.code
        assert_equal "[body] Invalid input: expected object, received #{input_type}", error.message
      end
    end

    %i[get_api_key list_api_keys].each do |endpoint|
      error = assert_raises(BetterAuth::APIError) { auth.api.public_send(endpoint, query: nil) }

      assert_equal "VALIDATION_ERROR", error.code
      assert_equal "[query] Invalid input: expected object, received null", error.message
    end
  end

  def test_create_body_contract_enforces_bounds_and_nested_permission_types
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "request-contract-create-bounds@example.com")
    cases = [
      [{remaining: -1}, "[body.remaining] Too small: expected number to be >=0"],
      [{refillAmount: 0}, "[body.refillAmount] Too small: expected number to be >=1"],
      [{permissions: {repo: ["read", 1]}}, "[body.permissions.repo.1] Invalid input: expected string, received number"]
    ]

    cases.each do |request_body, message|
      status, body = rack_json_response(auth, "POST", "/api-key/create", body: request_body, cookie: cookie)

      assert_equal 400, status
      assert_equal({"code" => "VALIDATION_ERROR", "message" => message}, body)
    end
  end

  def test_get_query_contract_rejects_non_string_id
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "request-contract-get@example.com")

    status, body = rack_get_json_response(auth, "/api-key/get?id%5B%5D=key-id", cookie: cookie)

    assert_equal 400, status
    assert_equal(
      {"code" => "VALIDATION_ERROR", "message" => "[query.id] Invalid input: expected string, received array"},
      body
    )
  end

  def test_list_query_contract_coerces_nonnegative_integers_like_zod
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "request-contract-list-coercion@example.com")

    empty_status, empty_body = rack_get_json_response(auth, "/api-key/list?limit=", cookie: cookie)
    numeric_status, numeric_body = rack_get_json_response(auth, "/api-key/list?limit=2&offset=1", cookie: cookie)

    assert_equal 200, empty_status
    assert_equal 0, empty_body.fetch("limit")
    assert_equal 200, numeric_status
    assert_equal 2, numeric_body.fetch("limit")
    assert_equal 1, numeric_body.fetch("offset")
  end

  def test_list_query_contract_rejects_enum_fraction_bounds_and_nan_with_complete_envelopes
    auth = build_api_key_auth(default_key_length: 12)
    cookie = sign_up_cookie(auth, email: "request-contract-list-errors@example.com")
    cases = [
      ["sortDirection=ASC", "[query.sortDirection] Invalid option: expected one of \"asc\"|\"desc\""],
      ["limit=2.5", "[query.limit] Invalid input: expected int, received number"],
      ["limit=-1", "[query.limit] Too small: expected number to be >=0"],
      ["limit=abc", "[query.limit] Invalid input: expected number, received NaN"]
    ]

    cases.each do |query, message|
      status, body = rack_get_json_response(auth, "/api-key/list?#{query}", cookie: cookie)

      assert_equal 400, status, query
      assert_equal({"code" => "VALIDATION_ERROR", "message" => message}, body, query)
    end
  end

  def test_create_contract_coerces_user_id_and_strips_unknown_fields
    auth = build_api_key_auth(default_key_length: 12)

    created = auth.api.create_api_key(body: {userId: 123})
    unknown_field = assert_raises(BetterAuth::APIError) do
      auth.api.create_api_key(body: {user_id: "not-an-upstream-field"})
    end

    assert_equal "123", created[:referenceId]
    assert_equal "UNAUTHORIZED", unknown_field.status
    assert_equal "UNAUTHORIZED_SESSION", unknown_field.code
  end

  def test_http_route_errors_publish_api_key_registry_codes
    auth = build_api_key_auth(default_key_length: 12, enable_metadata: true)
    cookie = sign_up_cookie(auth, email: "request-contract-error-codes@example.com")
    created = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {})
    cases = [
      ["POST", "/api-key/create", {remaining: 1}, 400, "SERVER_ONLY_PROPERTY"],
      ["POST", "/api-key/create", {name: "a" * 33}, 400, "INVALID_NAME_LENGTH"],
      ["POST", "/api-key/create", {prefix: "a" * 33}, 400, "INVALID_PREFIX_LENGTH"],
      ["POST", "/api-key/create", {metadata: "invalid"}, 400, "INVALID_METADATA_TYPE"],
      ["POST", "/api-key/update", {keyId: created[:id]}, 400, "NO_VALUES_TO_UPDATE"],
      ["POST", "/api-key/delete", {keyId: "missing"}, 404, "KEY_NOT_FOUND"]
    ]

    cases.each do |method, path, request_body, expected_status, code|
      status, body = rack_json_response(auth, method, path, body: request_body, cookie: cookie)

      assert_equal expected_status, status, path
      assert_equal(
        {"code" => code, "message" => BetterAuth::APIKey::ERROR_CODES.fetch(code)},
        body,
        path
      )
    end

    status, body = rack_get_json_response(auth, "/api-key/get?id=missing", cookie: cookie)
    assert_equal 404, status
    assert_equal(
      {"code" => "KEY_NOT_FOUND", "message" => BetterAuth::APIKey::ERROR_CODES.fetch("KEY_NOT_FOUND")},
      body
    )
  end

  private

  def rack_raw_json_response(auth, method, path, payload:, cookie: nil)
    env = {
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => payload.bytesize.to_s,
      "HTTP_ORIGIN" => "http://localhost:3000",
      :input => payload
    }
    env["HTTP_COOKIE"] = cookie if cookie
    response = Rack::MockRequest.new(auth).request(method, "/api/auth#{path}", env)
    [response.status, JSON.parse(response.body)]
  end

  def rack_get_json_response(auth, path, cookie:)
    response = Rack::MockRequest.new(auth).get(
      "/api/auth#{path}",
      "HTTP_COOKIE" => cookie,
      "HTTP_ORIGIN" => "http://localhost:3000"
    )
    [response.status, JSON.parse(response.body)]
  end
end
