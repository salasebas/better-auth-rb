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
          plan: "007",
          notes: "Direct API index, hooks, disabled paths, and response formatting covered in api_test"
        },
        "api/middlewares/authorization.test.ts" => {
          owner: "better_auth/api_test.rb",
          status: :partial,
          plan: "007",
          notes: "Authorization middleware parity gaps tracked in plan 007"
        },
        "api/middlewares/origin-check.test.ts" => {
          owner: ["better_auth/router_test.rb"],
          status: :covered,
          plan: "007",
          notes: "Origin, Fetch Metadata CSRF, disable flags, and path-scoped skips covered in router_test"
        },
        "api/rate-limiter/rate-limiter.test.ts" => {
          owner: ["better_auth/router_test.rb", "better_auth/rate_limiter_test.rb"],
          status: :covered,
          plan: "007",
          notes: "Core RateLimiter storage/rules and Rack integration covered in rate_limiter_test and router_test"
        },
        "api/routes/account.test.ts" => {
          owner: "better_auth/routes/account_test.rb",
          status: :covered,
          plan: "009",
          notes: "Account listing, unlink guards, access-token refresh, account cookie, refresh-token errors, and account info covered in account_test"
        },
        "api/routes/email-verification.test.ts" => {
          owner: "better_auth/routes/email_verification_test.rb",
          status: :covered,
          plan: "009",
          notes: "Send/verify email flows, callback redirects, verification callbacks, change-email verification, and secondary storage covered in email_verification_test"
        },
        "api/routes/error.test.ts" => {
          owner: "better_auth/routes/error_test.rb",
          status: :covered,
          plan: "009",
          notes: "Error route responses covered in error_test"
        },
        "api/routes/password.test.ts" => {
          owner: "better_auth/routes/password_test.rb",
          status: :covered,
          plan: "009",
          notes: "Password reset enumeration safety, callback redirects, credential creation, session revocation, verify-password scope, and length errors covered in password_test"
        },
        "api/routes/session-api.test.ts" => {
          owner: ["better_auth/routes/session_routes_test.rb", "better_auth/session_test.rb"],
          status: :covered,
          plan: "008",
          notes: "Session routes, cookie cache strategies, deferred refresh, secondary storage, date fields, and update-session guards covered in session_routes_test and session_test"
        },
        "api/routes/sign-in.test.ts" => {
          owner: "better_auth/routes/sign_in_test.rb",
          status: :covered,
          plan: "009",
          notes: "Email sign-in, CSRF/origin checks, form-urlencoded bodies, verification-on-sign-in, and callback URL validation covered in sign_in_test; social callback URL checks live in social_test"
        },
        "api/routes/sign-out.test.ts" => {
          owner: "better_auth/routes/sign_out_test.rb",
          status: :covered,
          plan: "009",
          notes: "Sign-out idempotency, session deletion, and cookie/cache/account cleanup covered in sign_out_test"
        },
        "api/routes/sign-up.test.ts" => {
          owner: "better_auth/routes/sign_up_test.rb",
          status: :covered,
          plan: "009",
          notes: "Sign-up custom fields, enumeration protection, CSRF, form-urlencoded bodies, sendOnSignUp behavior, and synthetic user responses covered in sign_up_test"
        },
        "api/routes/update-user.test.ts" => {
          owner: "better_auth/routes/user_routes_test.rb",
          status: :covered,
          plan: "009",
          notes: "Update/delete/change-password/change-email flows, enumeration-safe change-email, delete-user verification, and secondary storage propagation covered in user_routes_test"
        },
        "api/to-auth-endpoints.test.ts" => {
          owner: "better_auth/api_test.rb",
          status: :covered,
          plan: "007",
          notes: "Endpoint conversion and direct API dispatch covered in api_test"
        },
        "auth/full.test.ts" => {
          owner: ["better_auth/auth_test.rb", "better_auth/auth_context_upstream_parity_test.rb"],
          status: :covered,
          plan: "007",
          notes: "Full auth configuration and context bootstrap covered in auth_test and auth_context_upstream_parity_test"
        },
        "auth/minimal.test.ts" => {
          owner: "better_auth/auth_test.rb",
          status: :covered,
          plan: "007",
          notes: "Minimal auth configuration covered in auth_test"
        },
        "auth/trusted-origins.test.ts" => {
          owner: "better_auth/auth_context_upstream_parity_test.rb",
          status: :covered,
          plan: "007",
          notes: "Trusted-origin merge, dynamic base URL hosts, and plugin callbacks covered in auth_context_upstream_parity_test"
        },
        "call.test.ts" => {
          owner: ["better_auth/api_test.rb", "better_auth/auth_context_upstream_parity_test.rb"],
          status: :covered,
          plan: "007",
          notes: "Auth call dispatch, hooks, cookies, and error chaining covered in api_test and auth_context_upstream_parity_test"
        },
        "context/create-context.test.ts" => {
          owner: "better_auth/auth_context_upstream_parity_test.rb",
          status: :covered,
          plan: "007",
          notes: "Context bootstrap for secrets, session defaults, plugins, dynamic base URL, and password utilities covered in auth_context_upstream_parity_test; upstream hasPlugin has no Ruby equivalent"
        },
        "context/init-minimal.test.ts" => {
          owner: "better_auth/auth_test.rb",
          status: :covered,
          plan: "007",
          notes: "Minimal init path covered alongside auth_test"
        },
        "context/init.test.ts" => {
          owner: "better_auth/auth_context_upstream_parity_test.rb",
          status: :covered,
          plan: "007",
          notes: "Context init, plugin ordering, database hooks exposure, and telemetry options covered in auth_context_upstream_parity_test"
        },
        "cookies/cookies.test.ts" => {
          owner: "better_auth/cookies_test.rb",
          status: :covered,
          plan: "008",
          notes: "Cookie defaults, production env, cross-subdomain, parsing, cache strategies, chunking, rotation, and Endpoint set-cookie helpers covered in cookies_test; Ruby uses Endpoint helpers instead of a standalone parseSetCookieHeader utility"
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
          status: :covered,
          plan: "012",
          notes: "Additional-fields plugin covered in additional_fields_test"
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
          notes: "Anonymous linking on /email-otp/verify-email and SIWE verify not covered; sign-in and magic-link paths covered"
        },
        "plugins/bearer/bearer.test.ts" => {
          owner: "better_auth/plugins/bearer_test.rb",
          status: :covered,
          plan: "012",
          notes: "Bearer plugin covered in bearer_test"
        },
        "plugins/captcha/captcha.test.ts" => {
          owner: "better_auth/plugins/captcha_test.rb",
          status: :partial,
          plan: "012",
          notes: "Missing secret key surfaces as UNKNOWN_ERROR rather than MISSING_SECRET_KEY response code"
        },
        "plugins/custom-session/custom-session.test.ts" => {
          owner: "better_auth/plugins/custom_session_test.rb",
          status: :covered,
          plan: "012",
          notes: "Custom-session plugin covered in custom_session_test"
        },
        "plugins/device-authorization/device-authorization.test.ts" => {
          owner: "better_auth/plugins/device_authorization_test.rb",
          status: :covered,
          plan: "006",
          notes: "Device authorization plugin covered in device_authorization_test"
        },
        "plugins/email-otp/email-otp.test.ts" => {
          owner: [
            "better_auth/plugins/email_otp_test.rb",
            "better_auth/plugins/rate_limit_matrix_test.rb"
          ],
          status: :covered,
          plan: "011",
          notes: "Email OTP plugin covered in email_otp_test; custom rate-limit storage in rate_limit_matrix_test"
        },
        "plugins/generic-oauth/generic-oauth.test.ts" => {
          owner: "better_auth/plugins/generic_oauth_test.rb",
          status: :covered,
          plan: "006",
          notes: "Generic OAuth plugin covered in generic_oauth_test"
        },
        "plugins/haveibeenpwned/haveibeenpwned.test.ts" => {
          owner: "better_auth/plugins/have_i_been_pwned_test.rb",
          status: :covered,
          plan: "012",
          notes: "Have I Been Pwned plugin covered in have_i_been_pwned_test"
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
          status: :covered,
          plan: "012",
          notes: "Last-login-method custom prefix covered in last_login_method_test"
        },
        "plugins/last-login-method/last-login-method.test.ts" => {
          owner: "better_auth/plugins/last_login_method_test.rb",
          status: :partial,
          plan: "012",
          notes: "Passkey and phone-number login method paths not covered; core email, magic-link, SIWE, and OAuth paths covered"
        },
        "plugins/magic-link/magic-link.test.ts" => {
          owner: [
            "better_auth/plugins/magic_link_test.rb",
            "better_auth/plugins/rate_limit_matrix_test.rb"
          ],
          status: :partial,
          plan: "011",
          notes: "Rack verify requests without token return 400 validation instead of errorCallback redirect"
        },
        "plugins/mcp/mcp.test.ts" => {
          owner: [
            "../../better_auth-oauth-provider/test/better_auth/oauth_provider/mcp_test.rb"
          ],
          status: :covered,
          plan: "019",
          notes: "MCP/resource-server behavior covered by oauth-provider package"
        },
        "plugins/multi-session/multi-session.test.ts" => {
          owner: "better_auth/plugins/multi_session_test.rb",
          status: :covered,
          plan: "012",
          notes: "Multi-session plugin covered in multi_session_test"
        },
        "plugins/oauth-proxy/oauth-proxy.test.ts" => {
          owner: "better_auth/plugins/oauth_proxy_test.rb",
          status: :covered,
          plan: "006",
          notes: "OAuth proxy plugin covered in oauth_proxy_test"
        },
        "plugins/oidc-provider/oidc.test.ts" => {
          owner: "../../better_auth-oauth-provider/test/better_auth/oauth_provider_test.rb",
          status: :covered,
          plan: "019",
          notes: "OIDC provider behavior superseded by oauth-provider package"
        },
        "plugins/oidc-provider/utils/prompt.test.ts" => {
          owner: "../../better_auth-oauth-provider/test/better_auth/oauth_provider/prompt_test.rb",
          status: :covered,
          plan: "019",
          notes: "OIDC prompt utilities covered by oauth-provider package"
        },
        "plugins/one-time-token/one-time-token.test.ts" => {
          owner: "better_auth/plugins/one_time_token_test.rb",
          status: :covered,
          plan: "011",
          notes: "One-time-token plugin covered; disable_client_request applies to generate only"
        },
        "plugins/open-api/open-api.test.ts" => {
          owner: "better_auth/plugins/open_api_test.rb",
          status: :covered,
          plan: "006",
          notes: "OpenAPI plugin covered in open_api_test"
        },
        "plugins/organization/organization-hook.test.ts" => {
          owner: [
            "better_auth/plugins/organization_test.rb",
            "better_auth/plugins/organization_org_crud_test.rb",
            "better_auth/plugins/organization_members_test.rb"
          ],
          status: :covered,
          plan: "010",
          notes: "Organization hooks covered in organization_test and org CRUD tests"
        },
        "plugins/organization/organization.test.ts" => {
          owner: [
            "better_auth/plugins/organization_test.rb",
            "better_auth/plugins/organization_org_crud_test.rb",
            "better_auth/plugins/organization_members_test.rb"
          ],
          status: :partial,
          plan: "010",
          notes: "Callable membership_limit is not enforced on add_member; type-only schema order tests excluded"
        },
        "plugins/organization/routes/crud-access-control.test.ts" => {
          owner: [
            "better_auth/plugins/organization_test.rb",
            "better_auth/plugins/organization_members_test.rb"
          ],
          status: :covered,
          plan: "010",
          notes: "Dynamic access-control routes covered in organization plugin tests"
        },
        "plugins/organization/routes/crud-members.test.ts" => {
          owner: [
            "better_auth/plugins/organization_test.rb",
            "better_auth/plugins/organization_members_test.rb"
          ],
          status: :partial,
          plan: "010",
          notes: "Callable membership_limit is not enforced on add_member"
        },
        "plugins/organization/routes/crud-org.test.ts" => {
          owner: [
            "better_auth/plugins/organization_test.rb",
            "better_auth/plugins/organization_org_crud_test.rb"
          ],
          status: :covered,
          plan: "010",
          notes: "Organization CRUD routes covered in organization plugin tests"
        },
        "plugins/organization/team.test.ts" => {
          owner: [
            "better_auth/plugins/organization_test.rb",
            "better_auth/plugins/organization_org_crud_test.rb",
            "better_auth/plugins/organization_members_test.rb"
          ],
          status: :covered,
          plan: "010",
          notes: "Organization team routes covered in organization plugin tests"
        },
        "plugins/phone-number/phone-number.test.ts" => {
          owner: "better_auth/plugins/phone_number_test.rb",
          status: :covered,
          plan: "006",
          notes: "Phone-number plugin covered in phone_number_test"
        },
        "plugins/siwe/siwe.test.ts" => {
          owner: "better_auth/plugins/siwe_test.rb",
          status: :covered,
          plan: "012",
          notes: "SIWE plugin covered in siwe_test"
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
        candidates = [
          File.join(TEST_ROOT, relative_path),
          File.expand_path(relative_path, TEST_ROOT)
        ]
        candidates.any? { |path| File.file?(path) }
      end
    end
  end
end
