# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/generate-upstream-endpoint-registry"
require_relative "../scripts/compare-endpoint-api-names"

class EndpointToolingTest < Minitest::Test
  def test_extracts_export_function_api_key_route
    source = <<~TYPESCRIPT
      export function createApiKey(options: Options) {
        return createAuthEndpoint(
          "/api-key/create",
          { method: "POST" },
          async () => options,
        );
      }
    TYPESCRIPT

    name, chunk = UpstreamEndpointRegistry.declaration_chunks(source).fetch(0)
    route = UpstreamEndpointRegistry.parse_endpoint_definition(chunk)

    assert_equal "createApiKey", name
    assert_equal "/api-key/create", route.fetch(:path)
    assert_equal ["POST"], route.fetch(:methods)
  end

  def test_extracts_local_oauth_popup_route_without_hiding_http_exposure
    source = <<~TYPESCRIPT
      const oauthPopupStart = createAuthEndpoint(
        "/oauth-popup/start",
        { method: "GET", metadata: HIDE_METADATA },
        async () => undefined,
      );
    TYPESCRIPT

    name, chunk = UpstreamEndpointRegistry.declaration_chunks(source).fetch(0)
    route = UpstreamEndpointRegistry.parse_endpoint_definition(chunk)

    assert_equal "oauthPopupStart", name
    assert_equal "/oauth-popup/start", route.fetch(:path)
    assert_equal "http_hidden_metadata", route.fetch(:exposure)
    refute route.fetch(:server_only)
  end

  def test_parses_multiline_passkey_mapping
    block = <<~TYPESCRIPT
      {
        generatePasskeyRegistrationOptions: generatePasskeyRegistrationOptions(
          opts,
          { maxAgeInSeconds: MAX_AGE_IN_SECONDS },
        ),
        generatePasskeyAuthenticationOptions:
          generatePasskeyAuthenticationOptions(opts, {
            maxAgeInSeconds: MAX_AGE_IN_SECONDS,
          }),
      }
    TYPESCRIPT

    entries = UpstreamEndpointRegistry.parse_endpoint_block_entries(block).to_h do |key, target, _comment|
      [key, target.fetch(:symbol)]
    end

    assert_equal "generatePasskeyRegistrationOptions", entries.fetch("generatePasskeyRegistrationOptions")
    assert_equal "generatePasskeyAuthenticationOptions", entries.fetch("generatePasskeyAuthenticationOptions")
  end

  def test_expands_method_arrays_when_resolving_entries
    route_definition = UpstreamEndpointRegistry.parse_endpoint_definition(<<~TYPESCRIPT)
      export const userinfo = createAuthEndpoint(
        "/oauth2/userinfo",
        { method: ["GET", "POST"] },
        handler,
      );
    TYPESCRIPT
    mappings = [mapping("userinfo", symbol: "userinfo")]

    rows, unresolved = UpstreamEndpointRegistry.resolve_entries(mappings, {"userinfo" => route_definition})

    assert_empty unresolved
    assert_equal %w[GET POST], rows.map { |row| row.fetch(:method) }.sort
  end

  def test_route_matcher_handles_wildcards_and_passkey_overrides_both_directions
    upstream = [upstream_row("/session", "*", "getSession")]
    ruby = [ruby_row("/session", "GET", "get_session")]
    report = EndpointApiComparison.build_report(upstream, ruby)

    assert_equal 1, report.fetch(:aligned_count)
    assert_equal 0, report.fetch(:missing_ruby_count)
    assert_equal 0, report.fetch(:missing_upstream_count)

    passkey = upstream_row("/passkey/generate-register-options", "GET", "generatePasskeyRegistrationOptions", plugin_id: "passkey")
    ruby_passkey = ruby_row("/passkey/generate-register-options", "POST", "generate_passkey_registration_options")
    override_report = EndpointApiComparison.build_report([passkey], [ruby_passkey])

    assert_equal 1, override_report.fetch(:aligned_count)
    assert_equal 0, override_report.fetch(:missing_upstream_count)
  end

  def test_normalizes_totp_as_one_acronym
    assert_equal "get_totp_uri", EndpointNaming.upstream_registry_key_to_ruby("getTOTPURI")
    assert_equal "verify_totp", EndpointNaming.upstream_registry_key_to_ruby("verifyTOTP")
  end

  def test_reads_real_dotted_client_docblock_without_inventing_fallback
    block = <<~TYPESCRIPT
      {
        /**
         * **server:**
         * `auth.api.callbackOAuth`
         * **client:**
         * `authClient.oauth.callback`
         */
        callbackOAuth: callbackOAuth,
        callbackWithoutClient: callbackWithoutClient,
      }
    TYPESCRIPT
    mappings = UpstreamEndpointRegistry.parse_endpoint_block_entries(block).map do |key, target, comment|
      mapping(key, symbol: target.fetch(:symbol), comment: comment)
    end
    routes = {
      "callbackOAuth" => route("/callback/:id", "GET"),
      "callbackWithoutClient" => route("/callback/:provider", "GET")
    }

    rows, = UpstreamEndpointRegistry.resolve_entries(mappings, routes)
    documented = rows.find { |row| row[:registry_key] == "callbackOAuth" }
    undocumented = rows.find { |row| row[:registry_key] == "callbackWithoutClient" }

    assert_equal "auth.api.callbackOAuth", documented.fetch(:upstream_api)
    assert_equal "authClient.oauth.callback", documented.fetch(:upstream_client)
    assert_nil undocumented.fetch(:upstream_client)
  end

  def test_reports_exact_known_gaps_and_explicit_unsupported_exclusions
    report = EndpointApiComparison.build_report(
      [
        upstream_row("/oauth-popup/start", "GET", "oauthPopupStart", plugin_id: "oauth-popup"),
        upstream_row("/siwe/get-nonce", "POST", "getNonce", plugin_id: "siwe"),
        upstream_row("/mcp/token", "POST", "mcpOAuthToken", plugin_id: "mcp")
      ],
      []
    )

    assert_equal 2, report.fetch(:known_gap_count)
    assert_equal [
      ["/oauth-popup/start", "unimplemented_plugin", nil],
      ["/siwe/get-nonce", "wire_alias_missing", {method: "POST", path: "/siwe/nonce"}]
    ], report.fetch(:known_gaps).map { |row| [row.fetch(:path), row.fetch(:reason), row[:ruby_equivalent]] }
    assert_equal 1, report.fetch(:excluded_unsupported_count)
    assert_equal "mcp", report.fetch(:excluded_unsupported).fetch(0).fetch(:plugin_id)
    assert_equal %w[mcp electron oidc-provider], report.fetch(:excluded_unsupported_plugins)
    assert_equal 0, report.fetch(:missing_ruby_count)
  end

  private

  def mapping(registry_key, symbol:, comment: "")
    {
      registry_key: registry_key,
      target: {inline: false, symbol: symbol},
      comment: comment,
      plugin_id: "fixture",
      source_file: "fixture.ts"
    }
  end

  def route(path, method)
    {
      path: path,
      methods: [method],
      server_only: false,
      exposure: "http",
      hidden_metadata: false,
      comment: "",
      deprecated: false,
      source_file: "fixture.ts"
    }
  end

  def upstream_row(path, method, registry_key, plugin_id: "core")
    {
      path: path,
      method: method,
      registry_key: registry_key,
      ruby_registry_key: EndpointNaming.upstream_registry_key_to_ruby(registry_key),
      plugin_id: plugin_id,
      deprecated: false,
      server_only: false
    }
  end

  def ruby_row(path, method, endpoint_key)
    {path: path, method: method, endpoint_key: endpoint_key, plugin_id: "core"}
  end
end
