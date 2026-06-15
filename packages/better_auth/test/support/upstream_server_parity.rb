# frozen_string_literal: true

module BetterAuth
  module TestSupport
    module UpstreamServerParity
      UPSTREAM_ROOT = File.expand_path(
        "../../../../reference/upstream-src/1.6.9/repository/packages/better-auth/src",
        __dir__
      )

      EXCLUDED_UPSTREAM_TESTS = {
        "client/client-ssr.test.ts" => "Browser client SSR behavior; no Ruby server equivalent",
        "client/client.test.ts" => "Browser client API surface; no Ruby server equivalent",
        "client/proxy.test.ts" => "Client proxy and generated client shape; no Ruby server equivalent",
        "client/query.test.ts" => "Client query helpers; no Ruby server equivalent",
        "client/session-refresh.test.ts" => "Browser client session refresh; no Ruby server equivalent",
        "client/url.test.ts" => "Client URL helpers; no Ruby server equivalent",
        "integrations/next-js.test.ts" => "Next.js framework integration; not a Ruby server target",
        "plugins/mcp/client/mcp-client.test.ts" => "MCP browser/client plugin; server MCP tests live elsewhere",
        "plugins/organization/client.test.ts" => "Organization client plugin API; not server organization behavior",
        "plugins/test-utils/test-utils.test.ts" => "Upstream test harness utilities; not runtime server behavior",
        "types/types.test.ts" => "TypeScript type inference assertions; no Ruby server runtime equivalent"
      }.freeze

      SERVER_UPSTREAM_TEST_OWNERS = {
        "api/check-endpoint-conflicts.test.ts" => {
          owner: "better_auth/endpoint_test.rb",
          status: :covered,
          plan: "006",
          notes: "Endpoint conflict detection covered in core endpoint tests"
        },
        "api/index.test.ts" => {
          owner: "better_auth/api_test.rb",
          status: :covered,
          plan: "006",
          notes: "Core API index and endpoint wiring covered in api_test"
        },
        "api/middlewares/authorization.test.ts" => {
          owner: "better_auth/api_test.rb",
          status: :partial,
          plan: "007",
          notes: "Authorization middleware parity gaps tracked in plan 007"
        },
        "api/middlewares/origin-check.test.ts" => {
          owner: "better_auth/router_test.rb",
          status: :partial,
          plan: "007",
          notes: "Origin-check middleware parity gaps tracked in plan 007"
        },
        "api/rate-limiter/rate-limiter.test.ts" => {
          owner: "better_auth/plugins/rate_limit_matrix_test.rb",
          status: :partial,
          plan: "007",
          notes: "Rate limiter parity gaps tracked in plan 007"
        },
        "api/routes/account.test.ts" => {
          owner: "better_auth/routes/account_test.rb",
          status: :partial,
          plan: "009",
          notes: "Account route parity gaps tracked in plan 009"
        },
        "api/routes/email-verification.test.ts" => {
          owner: "better_auth/routes/email_verification_test.rb",
          status: :partial,
          plan: "009",
          notes: "Email verification route parity gaps tracked in plan 009"
        },
        "api/routes/error.test.ts" => {
          owner: "better_auth/routes/error_test.rb",
          status: :covered,
          plan: "009",
          notes: "Error route responses covered in error_test"
        },
        "api/routes/password.test.ts" => {
          owner: "better_auth/routes/password_test.rb",
          status: :partial,
          plan: "009",
          notes: "Password route parity gaps tracked in plan 009"
        },
        "api/routes/session-api.test.ts" => {
          owner: "better_auth/routes/session_routes_test.rb",
          status: :partial,
          plan: "008",
          notes: "Session route parity gaps tracked in plan 008"
        },
        "api/routes/sign-in.test.ts" => {
          owner: "better_auth/routes/sign_in_test.rb",
          status: :partial,
          plan: "009",
          notes: "Sign-in route parity gaps tracked in plan 009"
        },
        "api/routes/sign-out.test.ts" => {
          owner: "better_auth/routes/sign_out_test.rb",
          status: :partial,
          plan: "009",
          notes: "Sign-out route parity gaps tracked in plan 009"
        },
        "api/routes/sign-up.test.ts" => {
          owner: "better_auth/routes/sign_up_test.rb",
          status: :partial,
          plan: "009",
          notes: "Sign-up route parity gaps tracked in plan 009"
        },
        "api/routes/update-user.test.ts" => {
          owner: "better_auth/routes/user_routes_test.rb",
          status: :partial,
          plan: "009",
          notes: "Update-user route parity gaps tracked in plan 009"
        },
        "api/to-auth-endpoints.test.ts" => {
          owner: "better_auth/api_test.rb",
          status: :covered,
          plan: "006",
          notes: "Endpoint conversion helpers covered in api_test"
        },
        "auth/full.test.ts" => {
          owner: "better_auth/auth_test.rb",
          status: :covered,
          plan: "006",
          notes: "Full auth configuration surface covered in auth_test"
        },
        "auth/minimal.test.ts" => {
          owner: "better_auth/auth_test.rb",
          status: :covered,
          plan: "006",
          notes: "Minimal auth configuration covered in auth_test"
        },
        "auth/trusted-origins.test.ts" => {
          owner: "better_auth/auth_context_upstream_parity_test.rb",
          status: :partial,
          plan: "007",
          notes: "Trusted-origin parity gaps tracked in plan 007"
        },
        "call.test.ts" => {
          owner: "better_auth/api_test.rb",
          status: :covered,
          plan: "006",
          notes: "Auth call dispatch covered in api_test"
        },
        "context/create-context.test.ts" => {
          owner: "better_auth/auth_context_upstream_parity_test.rb",
          status: :partial,
          plan: "007",
          notes: "Context bootstrap parity gaps tracked in plan 007"
        },
        "context/init-minimal.test.ts" => {
          owner: "better_auth/auth_test.rb",
          status: :covered,
          plan: "007",
          notes: "Minimal init path covered alongside auth_test"
        },
        "context/init.test.ts" => {
          owner: "better_auth/auth_context_upstream_parity_test.rb",
          status: :partial,
          plan: "007",
          notes: "Context init parity gaps tracked in plan 007"
        },
        "cookies/cookies.test.ts" => {
          owner: "better_auth/cookies_test.rb",
          status: :partial,
          plan: "008",
          notes: "Cookie and session-cache parity gaps tracked in plan 008"
        },
        "crypto/password.test.ts" => {
          owner: "better_auth/password_test.rb",
          status: :covered,
          plan: "006",
          notes: "Password hashing covered in password_test"
        },
        "crypto/secret-rotation.test.ts" => {
          owner: "better_auth/crypto_test.rb",
          status: :covered,
          plan: "006",
          notes: "Secret rotation covered in crypto_test"
        },
        "db/db.test.ts" => {
          owner: "better_auth/adapters/internal_adapter_test.rb",
          status: :covered,
          plan: "006",
          notes: "Core DB adapter behavior covered in internal_adapter_test"
        },
        "db/get-migration-schema.test.ts" => {
          owner: "better_auth/migration/sql_test.rb",
          status: :covered,
          plan: "006",
          notes: "Migration schema introspection covered in migration/sql_test"
        },
        "db/internal-adapter.test.ts" => {
          owner: "better_auth/adapters/internal_adapter_test.rb",
          status: :covered,
          plan: "006",
          notes: "Internal adapter behavior covered in internal_adapter_test"
        },
        "db/secondary-storage.test.ts" => {
          owner: "better_auth/adapters/internal_adapter_test.rb",
          status: :partial,
          plan: "008",
          notes: "Secondary storage adapter behavior partially covered in internal_adapter_test"
        },
        "db/to-zod.test.ts" => {
          status: :ruby_not_applicable,
          plan: "006",
          notes: "Zod schema generation is TypeScript-only; Ruby uses its own schema layer"
        },
        "instrumentation.db.test.ts" => {
          owner: "better_auth/instrumentation_test.rb",
          status: :covered,
          plan: "006",
          notes: "DB instrumentation hooks covered in instrumentation_test"
        },
        "instrumentation.endpoint.test.ts" => {
          owner: "better_auth/instrumentation_test.rb",
          status: :covered,
          plan: "006",
          notes: "Endpoint instrumentation hooks covered in instrumentation_test"
        },
        "oauth2/link-account.test.ts" => {
          owner: "better_auth/oauth2_test.rb",
          status: :covered,
          plan: "006",
          notes: "OAuth2 account linking covered in oauth2_test"
        },
        "oauth2/utils.test.ts" => {
          owner: "better_auth/oauth2_test.rb",
          status: :covered,
          plan: "006",
          notes: "OAuth2 utility helpers covered in oauth2_test"
        },
        "plugins/access/access.test.ts" => {
          owner: "better_auth/plugins/access_test.rb",
          status: :covered,
          plan: "006",
          notes: "Access-control helper surface covered in access_test"
        },
        "plugins/additional-fields/additional-fields.test.ts" => {
          owner: "better_auth/plugins/additional_fields_test.rb",
          status: :partial,
          plan: "012",
          notes: "Additional-fields plugin parity gaps tracked in plan 012"
        },
        "plugins/admin/admin.test.ts" => {
          owner: "better_auth/plugins/admin_test.rb",
          status: :partial,
          plan: "010",
          notes: "Admin plugin overlaps organization access control; gaps tracked in plan 010"
        },
        "plugins/anonymous/anon.test.ts" => {
          owner: "better_auth/plugins/anonymous_test.rb",
          status: :partial,
          plan: "012",
          notes: "Anonymous plugin parity gaps tracked in plan 012"
        },
        "plugins/bearer/bearer.test.ts" => {
          owner: "better_auth/plugins/bearer_test.rb",
          status: :partial,
          plan: "012",
          notes: "Bearer plugin parity gaps tracked in plan 012"
        },
        "plugins/captcha/captcha.test.ts" => {
          owner: "better_auth/plugins/captcha_test.rb",
          status: :partial,
          plan: "012",
          notes: "Captcha plugin parity gaps tracked in plan 012"
        },
        "plugins/custom-session/custom-session.test.ts" => {
          owner: "better_auth/plugins/custom_session_test.rb",
          status: :partial,
          plan: "012",
          notes: "Custom-session plugin parity gaps tracked in plan 012"
        },
        "plugins/device-authorization/device-authorization.test.ts" => {
          owner: "better_auth/plugins/device_authorization_test.rb",
          status: :covered,
          plan: "006",
          notes: "Device authorization plugin covered in device_authorization_test"
        },
        "plugins/email-otp/email-otp.test.ts" => {
          owner: "better_auth/plugins/email_otp_test.rb",
          status: :partial,
          plan: "011",
          notes: "Email OTP plugin parity gaps tracked in plan 011"
        },
        "plugins/generic-oauth/generic-oauth.test.ts" => {
          owner: "better_auth/plugins/generic_oauth_test.rb",
          status: :covered,
          plan: "006",
          notes: "Generic OAuth plugin covered in generic_oauth_test"
        },
        "plugins/haveibeenpwned/haveibeenpwned.test.ts" => {
          owner: "better_auth/plugins/have_i_been_pwned_test.rb",
          status: :partial,
          plan: "012",
          notes: "Have I Been Pwned plugin parity gaps tracked in plan 012"
        },
        "plugins/jwt/jwt.test.ts" => {
          owner: "better_auth/plugins/jwt_test.rb",
          status: :covered,
          plan: "006",
          notes: "JWT plugin covered in jwt_test"
        },
        "plugins/jwt/rotation.test.ts" => {
          owner: "better_auth/plugins/jwt_test.rb",
          status: :covered,
          plan: "006",
          notes: "JWT rotation covered in jwt_test"
        },
        "plugins/last-login-method/custom-prefix.test.ts" => {
          owner: "better_auth/plugins/last_login_method_test.rb",
          status: :partial,
          plan: "012",
          notes: "Last-login-method custom prefix parity gaps tracked in plan 012"
        },
        "plugins/last-login-method/last-login-method.test.ts" => {
          owner: "better_auth/plugins/last_login_method_test.rb",
          status: :partial,
          plan: "012",
          notes: "Last-login-method plugin parity gaps tracked in plan 012"
        },
        "plugins/magic-link/magic-link.test.ts" => {
          owner: "better_auth/plugins/magic_link_test.rb",
          status: :partial,
          plan: "011",
          notes: "Magic-link plugin parity gaps tracked in plan 011"
        },
        "plugins/mcp/mcp.test.ts" => {
          owner: [
            "better_auth/plugins/mcp/authorization_test.rb",
            "better_auth/plugins/mcp/metadata_test.rb",
            "better_auth/plugins/mcp/token_test.rb",
            "better_auth/plugins/mcp/userinfo_test.rb",
            "better_auth/plugins/mcp/resource_handler_test.rb"
          ],
          status: :covered,
          plan: "006",
          notes: "MCP server plugin covered across mcp/*_test.rb files"
        },
        "plugins/multi-session/multi-session.test.ts" => {
          owner: "better_auth/plugins/multi_session_test.rb",
          status: :partial,
          plan: "012",
          notes: "Multi-session plugin parity gaps tracked in plan 012"
        },
        "plugins/oauth-proxy/oauth-proxy.test.ts" => {
          owner: "better_auth/plugins/oauth_proxy_test.rb",
          status: :covered,
          plan: "006",
          notes: "OAuth proxy plugin covered in oauth_proxy_test"
        },
        "plugins/oidc-provider/oidc.test.ts" => {
          owner: "better_auth/plugins/oidc_provider_test.rb",
          status: :covered,
          plan: "006",
          notes: "OIDC provider plugin covered in oidc_provider_test"
        },
        "plugins/oidc-provider/utils/prompt.test.ts" => {
          owner: "better_auth/plugins/oidc_provider_test.rb",
          status: :covered,
          plan: "006",
          notes: "OIDC prompt utilities covered in oidc_provider_test"
        },
        "plugins/one-time-token/one-time-token.test.ts" => {
          owner: "better_auth/plugins/one_time_token_test.rb",
          status: :partial,
          plan: "011",
          notes: "One-time-token plugin parity gaps tracked in plan 011"
        },
        "plugins/open-api/open-api.test.ts" => {
          owner: "better_auth/plugins/open_api_test.rb",
          status: :covered,
          plan: "006",
          notes: "OpenAPI plugin covered in open_api_test"
        },
        "plugins/organization/organization-hook.test.ts" => {
          owner: "better_auth/plugins/organization_test.rb",
          status: :partial,
          plan: "010",
          notes: "Organization hook parity gaps tracked in plan 010"
        },
        "plugins/organization/organization.test.ts" => {
          owner: "better_auth/plugins/organization_test.rb",
          status: :partial,
          plan: "010",
          notes: "Organization plugin parity gaps tracked in plan 010"
        },
        "plugins/organization/routes/crud-access-control.test.ts" => {
          owner: "better_auth/plugins/organization_test.rb",
          status: :partial,
          plan: "010",
          notes: "Organization access-control route parity gaps tracked in plan 010"
        },
        "plugins/organization/routes/crud-members.test.ts" => {
          owner: "better_auth/plugins/organization_test.rb",
          status: :partial,
          plan: "010",
          notes: "Organization member route parity gaps tracked in plan 010"
        },
        "plugins/organization/routes/crud-org.test.ts" => {
          owner: "better_auth/plugins/organization_test.rb",
          status: :partial,
          plan: "010",
          notes: "Organization CRUD route parity gaps tracked in plan 010"
        },
        "plugins/organization/team.test.ts" => {
          owner: "better_auth/plugins/organization_test.rb",
          status: :partial,
          plan: "010",
          notes: "Organization team parity gaps tracked in plan 010"
        },
        "plugins/phone-number/phone-number.test.ts" => {
          owner: "better_auth/plugins/phone_number_test.rb",
          status: :covered,
          plan: "006",
          notes: "Phone-number plugin covered in phone_number_test"
        },
        "plugins/siwe/siwe.test.ts" => {
          owner: "better_auth/plugins/siwe_test.rb",
          status: :partial,
          plan: "012",
          notes: "SIWE plugin parity gaps tracked in plan 012"
        },
        "plugins/two-factor/two-factor.test.ts" => {
          owner: "better_auth/plugins/two_factor_test.rb",
          status: :covered,
          plan: "006",
          notes: "Two-factor plugin covered in two_factor_test"
        },
        "plugins/username/username.test.ts" => {
          owner: "better_auth/plugins/username_test.rb",
          status: :covered,
          plan: "006",
          notes: "Username plugin covered in username_test"
        },
        "social.test.ts" => {
          owner: "better_auth/routes/social_test.rb",
          status: :covered,
          plan: "006",
          notes: "Social sign-in routes covered in social_test"
        },
        "utils/url.test.ts" => {
          owner: "better_auth/host_test.rb",
          status: :covered,
          plan: "006",
          notes: "URL/host utilities covered in host_test"
        }
      }.freeze

      TEST_ROOT = File.expand_path("..", __dir__)

      module_function

      def upstream_test_paths
        Dir.glob(File.join(UPSTREAM_ROOT, "**", "*test.ts")).map do |absolute|
          absolute.delete_prefix(UPSTREAM_ROOT + "/")
        end.sort
      end

      def owner_paths(entry)
        Array(entry[:owner])
      end

      def owner_exists?(relative_path)
        File.file?(File.join(TEST_ROOT, relative_path))
      end
    end
  end
end
