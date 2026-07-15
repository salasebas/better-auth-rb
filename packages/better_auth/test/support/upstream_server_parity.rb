# frozen_string_literal: true

require_relative "../../../../test/support/upstream_test_inventory"

module BetterAuth
  module TestSupport
    module UpstreamServerParity
      REPOSITORY_ROOT = File.expand_path("../../../..", __dir__)
      VERSION_FILE = File.join(REPOSITORY_ROOT, "reference/upstream-better-auth/VERSION.md")
      UPSTREAM_VERSION = File.read(VERSION_FILE)[/^\| Version \| `(\d+\.\d+\.\d+)` \|$/, 1]
      raise "Could not read pinned upstream version from #{VERSION_FILE}" unless UPSTREAM_VERSION

      UPSTREAM_ROOT = File.expand_path(
        "reference/upstream-src/#{UPSTREAM_VERSION}/repository/packages/better-auth/src",
        REPOSITORY_ROOT
      )

      EXCLUDED_UPSTREAM_TESTS = {
        "client/client-ssr.test.ts" => "Browser client SSR behavior; no Ruby server equivalent",
        "client/client.test.ts" => "Browser client API surface; no Ruby server equivalent",
        "client/client-declaration.test.ts" => "TypeScript client declaration surface; no Ruby server equivalent",
        "client/equality.test.ts" => "TypeScript client type equality assertions; no Ruby server equivalent",
        "client/parser.test.ts" => "Browser client response parser; no Ruby server equivalent",
        "client/proxy.test.ts" => "Client proxy and generated client shape; no Ruby server equivalent",
        "client/query.test.ts" => "Client query helpers; no Ruby server equivalent",
        "client/session-refresh.test.ts" => "Browser client session refresh; no Ruby server equivalent",
        "client/url.test.ts" => "Client URL helpers; no Ruby server equivalent",
        "integrations/next-js.test.ts" => "Next.js framework integration; not a Ruby server target",
        "plugins/mcp/client/mcp-client.test.ts" => "MCP browser/client plugin; server MCP tests live elsewhere",
        "plugins/oauth-popup/oauth-popup.client.test.ts" => "OAuth popup browser client behavior; no Ruby server equivalent",
        "plugins/organization/client.test.ts" => "Organization client plugin API; not server organization behavior",
        "plugins/organization/organization-client-declaration.test.ts" => "TypeScript organization client declaration surface; no Ruby server equivalent",
        "plugins/test-utils/test-utils.test.ts" => "Upstream test harness utilities; not runtime server behavior",
        "types/types.test.ts" => "TypeScript type inference assertions; no Ruby server runtime equivalent"
      }.freeze

      ACTIVE_PLANS = {"019" => :todo}.freeze
      RECONCILED_EVIDENCE_PATHS = %w[
        api/middlewares/authorization.test.ts
        api/routes/cookie-cache-fallback.test.ts
        api/server-only-endpoints.test.ts
        db/secondary-storage.test.ts
        oauth2/state.test.ts
        plugins/admin/admin.test.ts
        plugins/admin/admin-username.test.ts
        plugins/anonymous/anon.test.ts
        plugins/captcha/captcha.test.ts
        plugins/last-login-method/last-login-method.test.ts
        plugins/magic-link/magic-link.test.ts
        plugins/one-tap/one-tap.test.ts
        plugins/organization/organization.test.ts
        plugins/organization/routes/crud-invites.test.ts
        plugins/organization/routes/crud-members.test.ts
        plugins/two-factor/two-factor.account-lockout.test.ts
        plugins/two-factor/two-factor.attempt-cap.test.ts
        plugins/two-factor/two-factor.security.test.ts
      ].freeze

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
          status: :covered,
          evidence: {"better_auth/api_test.rb" => "test_direct_api_error_preserves_headers_accumulated_before_raise"},
          notes: "Authorization and direct API error/header behavior is covered by the direct API hook and error tests in api_test"
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
        "api/routes/cookie-cache-fallback.test.ts" => {
          owner: ["better_auth/cookies_test.rb", "better_auth/session_test.rb"],
          status: :covered,
          evidence: {
            "better_auth/cookies_test.rb" => "test_compact_cookie_cache_rejects_expired_and_tampered_payloads",
            "better_auth/session_test.rb" => "test_find_current_session_expires_cookie_when_session_is_missing"
          },
          notes: "Cookie cache tamper, expiry, secret rotation, missing-session fallback, and sensitive-session bypass cases are covered in cookies_test and session_test"
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
        "api/server-only-endpoints.test.ts" => {
          owner: "better_auth/api_test.rb",
          status: :covered,
          evidence: {"better_auth/api_test.rb" => "test_disabled_paths_return_not_found_for_rack_but_remain_callable_via_direct_api"},
          notes: "Server-only endpoints remain directly callable while Rack-disabled paths return not found, covered in api_test"
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
          status: :covered,
          evidence: {"better_auth/adapters/internal_adapter_test.rb" => "test_create_find_update_and_delete_session_with_secondary_storage"},
          notes: "Secondary-storage reads, writes, deletes, atomic consume, increment, and fallback behavior are covered in internal_adapter_test"
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
        "oauth2/state.test.ts" => {
          owner: ["better_auth/routes/social_test.rb", "better_auth/plugins/generic_oauth_test.rb"],
          status: :covered,
          evidence: {
            "better_auth/routes/social_test.rb" => "test_callback_rejects_invalid_signed_state",
            "better_auth/plugins/generic_oauth_test.rb" => "test_state_cookie_failure_uses_recovered_per_flow_error_url"
          },
          notes: "Signed state, per-flow callback/error URLs, single-use consumption, tamper rejection, and secondary-storage state are covered in social_test and generic_oauth_test"
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
          status: :covered,
          evidence: {"better_auth/plugins/admin_test.rb" => "test_admin_manages_users_roles_bans_sessions_and_passwords"},
          notes: "Admin user/session/role/ban/impersonation behavior and authorization hardening are covered in admin_test"
        },
        "plugins/admin/admin-username.test.ts" => {
          owner: "better_auth/plugins/admin_test.rb",
          status: :covered,
          evidence: {"better_auth/plugins/admin_test.rb" => "test_admin_create_user_validates_and_mirrors_username_fields"},
          notes: "Admin create/update username field mapping and validation are covered by admin create-user and update-user cases"
        },
        "plugins/anonymous/anon.test.ts" => {
          owner: "better_auth/plugins/anonymous_test.rb",
          status: :covered,
          evidence: {"better_auth/plugins/anonymous_test.rb" => "test_sign_in_email_otp_links_and_deletes_previous_anonymous_user"},
          notes: "Anonymous creation, deletion, session linking, social, magic-link, and email-OTP linking are covered in anonymous_test; SIWE has its own equivalent plugin callback coverage"
        },
        "plugins/bearer/bearer.test.ts" => {
          owner: "better_auth/plugins/bearer_test.rb",
          status: :covered,
          plan: "012",
          notes: "Bearer plugin covered in bearer_test"
        },
        "plugins/captcha/captcha.test.ts" => {
          owner: "better_auth/plugins/captcha_test.rb",
          status: :adapted,
          evidence: {"better_auth/plugins/captcha_test.rb" => "test_missing_secret_key_returns_unknown_error"},
          notes: "Provider payloads, protected paths, timeouts, and failure codes are covered in captcha_test; Ruby intentionally maps configuration/service failures to UNKNOWN_ERROR"
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
          status: :adapted,
          evidence: {"better_auth/plugins/last_login_method_test.rb" => "test_last_login_method_updates_database_on_social_and_generic_oauth_callbacks"},
          notes: "Email, sign-up, magic-link, SIWE, social, and generic OAuth persistence are covered in last_login_method_test; external Passkey and phone packages own their callback integration"
        },
        "plugins/magic-link/magic-link.test.ts" => {
          owner: [
            "better_auth/plugins/magic_link_test.rb",
            "better_auth/plugins/rate_limit_matrix_test.rb"
          ],
          status: :adapted,
          evidence: {"better_auth/plugins/magic_link_test.rb" => "test_magic_link_empty_token_redirects_with_invalid_token"},
          notes: "Magic-link issuance, single-use storage, Rack verification, invalid/empty token redirects, callbacks, and rate limits are covered in magic_link_test; Ruby validates the Rack query before endpoint dispatch"
        },
        "plugins/mcp/mcp.test.ts" => {
          owner: [
            "../../better_auth-oauth-provider/test/better_auth/oauth_provider/mcp_test.rb"
          ],
          status: :covered,
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
        "plugins/oauth-popup/oauth-popup.test.ts" => {
          owner: "../../../docs/adr/0001-oauth-popup-server-half.md",
          status: :partial,
          plan: "019",
          notes: "The opt-in OAuth Popup server half is intentionally deferred to Plan 019; no runtime implementation exists yet"
        },
        "plugins/oidc-provider/oidc.test.ts" => {
          status: :ruby_not_applicable,
          notes: "The legacy upstream oidc-provider plugin is unsupported; Ruby uses the separate OAuth Provider package"
        },
        "plugins/oidc-provider/redirect-uri.test.ts" => {
          status: :ruby_not_applicable,
          notes: "Redirect behavior belongs to the unsupported legacy oidc-provider plugin; the separate Ruby OAuth Provider package has its own redirect validation inventory"
        },
        "plugins/oidc-provider/utils/prompt.test.ts" => {
          status: :ruby_not_applicable,
          notes: "Prompt utilities belong to the unsupported legacy oidc-provider plugin; equivalent OAuth Provider behavior is inventoried in that package"
        },
        "plugins/one-time-token/one-time-token.test.ts" => {
          owner: "better_auth/plugins/one_time_token_test.rb",
          status: :covered,
          plan: "011",
          notes: "One-time-token plugin covered; disable_client_request applies to generate only"
        },
        "plugins/one-tap/one-tap.test.ts" => {
          owner: "better_auth/plugins/one_tap_test.rb",
          status: :covered,
          evidence: {"better_auth/plugins/one_tap_test.rb" => "test_callback_rejects_untrusted_google_sub_for_existing_user"},
          notes: "Google identity ownership, verified-email linking, audience, hosted-domain, and implicit-linking cases are covered in one_tap_test"
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
          status: :adapted,
          evidence: {"better_auth/plugins/organization_test.rb" => "test_teams_and_dynamic_roles"},
          notes: "Organization creation, membership limits, invitations, teams, hooks, and access control are covered; TypeScript-only schema ordering assertions do not apply to Ruby"
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
        "plugins/organization/routes/crud-invites.test.ts" => {
          owner: [
            "better_auth/plugins/organization_test.rb",
            "better_auth/plugins/organization_members_test.rb"
          ],
          status: :covered,
          evidence: {"better_auth/plugins/organization_members_test.rb" => "test_invitation_accept_reject_and_cancel_hooks_fire"},
          notes: "Invitation ownership, verification, accept/reject/cancel hooks, roles, and membership limits are covered in organization_members_test"
        },
        "plugins/organization/routes/crud-members.test.ts" => {
          owner: [
            "better_auth/plugins/organization_test.rb",
            "better_auth/plugins/organization_members_test.rb"
          ],
          status: :covered,
          evidence: {"better_auth/plugins/organization_members_test.rb" => "test_concurrent_member_adds_cannot_exceed_membership_limit"},
          notes: "Member add/remove/leave/update/list behavior, ownership guards, last-owner safety, teams, dynamic roles, and limits are covered in organization_members_test"
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
        "plugins/two-factor/two-factor.account-lockout.test.ts" => {
          owner: "better_auth/plugins/two_factor_security_test.rb",
          status: :covered,
          evidence: {"better_auth/plugins/two_factor_security_test.rb" => "test_account_lock_accumulates_across_totp_otp_and_backup_challenges"},
          notes: "Cross-method account lock accumulation, reset, expiry, disablement, and legacy rows are covered in two_factor_security_test"
        },
        "plugins/two-factor/two-factor.attempt-cap.test.ts" => {
          owner: "better_auth/plugins/two_factor_security_test.rb",
          status: :covered,
          evidence: {"better_auth/plugins/two_factor_security_test.rb" => "test_concurrent_totp_burst_processes_at_most_five_guesses"},
          notes: "TOTP and backup-code five-attempt budgets, concurrent bursts, and internal-error restoration are covered in two_factor_security_test"
        },
        "plugins/two-factor/two-factor.security.test.ts" => {
          owner: ["better_auth/plugins/two_factor_test.rb", "better_auth/plugins/two_factor_security_test.rb"],
          status: :covered,
          evidence: {
            "better_auth/plugins/two_factor_test.rb" => "test_encrypted_two_factor_values_survive_secret_rotation",
            "better_auth/plugins/two_factor_security_test.rb" => "test_lock_fields_are_hidden_from_output_and_missing_legacy_lock_is_usable"
          },
          notes: "Encrypted/hash storage, secret rotation, replay resistance, lock fields, challenge cookies, and management authentication are covered in the two-factor tests"
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

      def validation_errors(entries: SERVER_UPSTREAM_TEST_OWNERS, exclusions: EXCLUDED_UPSTREAM_TESTS, upstream_paths: upstream_test_paths)
        UpstreamTestInventory.validate(
          upstream_paths: upstream_paths,
          entries: entries,
          exclusions: exclusions,
          test_root: TEST_ROOT,
          active_plans: ACTIVE_PLANS,
          evidence_required_for: RECONCILED_EVIDENCE_PATHS
        )
      end
    end
  end
end
