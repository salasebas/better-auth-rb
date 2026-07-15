# frozen_string_literal: true

require_relative "../../../../test/support/upstream_test_inventory"

module BetterAuthOAuthProviderUpstreamParity
  ROOT = File.expand_path("../../../..", __dir__)
  TEST_ROOT = File.expand_path("..", __dir__)
  LEDGER = UpstreamPackageTestLedger.new(
    repository_root: ROOT,
    upstream_subpath: "packages/oauth-provider",
    test_root: TEST_ROOT,
    entries: {
      "src/authorize.test.ts" => {
        owner: "better_auth/oauth_provider/authorize_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/authorize_test.rb" => "test_authorize_rejects_unsupported_response_type_on_redirect_uri"},
        notes: "Authorization response validation"
      },
      "src/introspect.test.ts" => {
        owner: "better_auth/oauth_provider/introspect_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/introspect_test.rb" => "test_introspect_does_not_expose_tokens_to_other_clients"},
        notes: "Opaque/JWT token introspection and client isolation"
      },
      "src/logout.test.ts" => {
        owner: "better_auth/oauth_provider/logout_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/logout_test.rb" => "test_end_session_returns_success_without_redirect_for_valid_id_token"},
        notes: "End-session ID-token validation"
      },
      "src/mcp.test.ts" => {
        owner: "better_auth/oauth_provider/mcp_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/mcp_test.rb" => "test_mcp_handler_with_verifier_accepts_valid_jwt"},
        notes: "Protected-resource metadata and bearer challenges"
      },
      "src/metadata.test.ts" => {
        owner: "better_auth/oauth_provider/metadata_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/metadata_test.rb" => "test_authorization_server_metadata_matches_upstream_endpoints_and_cache_headers"},
        notes: "Authorization/OpenID metadata and cache headers"
      },
      "src/oauth.test.ts" => {
        owner: "better_auth/oauth_provider/oauth_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/oauth_test.rb" => "test_plugin_entrypoint_uses_oauth_provider_models_not_oidc_provider_models"},
        notes: "Canonical plugin entrypoint and model surface"
      },
      "src/oauthClient/endpoints-privileges.test.ts" => {
        owner: "better_auth/oauth_provider/oauth_client/endpoints_privileges_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/oauth_client/endpoints_privileges_test.rb" => "test_client_privileges_can_block_list_endpoint"},
        notes: "Client management privilege callbacks"
      },
      "src/oauthClient/endpoints.test.ts" => {
        owner: "better_auth/oauth_provider/oauth_client/endpoints_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/oauth_client/endpoints_test.rb" => "test_client_management_create_read_list_update_rotate_delete"},
        notes: "Client CRUD, rotation, metadata validation, and public lookup"
      },
      "src/oauthConsent/endpoints.test.ts" => {
        owner: "better_auth/oauth_provider/oauth_consent/endpoints_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/oauth_consent/endpoints_test.rb" => "test_consent_management_lists_reads_updates_and_deletes_consents"},
        notes: "Consent CRUD and user scoping"
      },
      "src/pairwise.test.ts" => {
        owner: "better_auth/oauth_provider/pairwise_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/pairwise_test.rb" => "test_pairwise_multi_host_redirects_require_sector_identifier_uri"},
        notes: "Pairwise subject stability and sector validation"
      },
      "src/pkce-optional.test.ts" => {
        owner: "better_auth/oauth_provider/pkce_optional_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/pkce_optional_test.rb" => "test_confidential_client_can_opt_out_of_pkce_for_authorization_code"},
        notes: "Explicit confidential-client PKCE opt-out"
      },
      "src/register.test.ts" => {
        owner: "better_auth/oauth_provider/register_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/register_test.rb" => "test_dynamic_registration_defaults_to_pkce_and_strips_unknown_metadata"},
        notes: "Dynamic registration defaults, validation, scopes, and client types"
      },
      "src/revoke.test.ts" => {
        owner: "better_auth/oauth_provider/revoke_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/revoke_test.rb" => "test_revoke_refresh_token_makes_associated_access_token_inactive"},
        notes: "Access/refresh token revocation and client ownership"
      },
      "src/schema.test.ts" => {
        owner: "better_auth/oauth_provider_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider_test.rb" => "test_oauth_hot_path_schema_fields_are_indexed"},
        notes: "OAuth foreign-key and hot-path indexes"
      },
      "src/signed-query.test.ts" => {
        owner: "better_auth/oauth_provider/utils/query_serialization_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/utils/query_serialization_test.rb" => "test_signed_query_canonicalizes_reordered_repeated_resource_values"},
        notes: "Declared signed parameters and canonical repeated values"
      },
      "src/token.test.ts" => {
        owner: "better_auth/oauth_provider/token_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/token_test.rb" => "test_authorization_code_is_persisted_and_consumed_once_across_auth_instances"},
        notes: "Grant authentication, PKCE, single-use codes, rotation, resources, and cache controls"
      },
      "src/types/zod.test.ts" => {
        owner: "better_auth/oauth_provider/types/zod_test.rb",
        status: :adapted,
        evidence: {"better_auth/oauth_provider/types/zod_test.rb" => "test_safe_url_rejects_dangerous_schemes_and_non_loopback_http"},
        notes: "Ruby URL validation equivalent for the upstream Zod schema"
      },
      "src/userinfo.test.ts" => {
        owner: "better_auth/oauth_provider/userinfo_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/userinfo_test.rb" => "test_userinfo_file_parity_filters_profile_and_email_claims_by_scope"},
        notes: "Bearer handling and scope-filtered OpenID claims"
      },
      "src/utils/basic-auth.test.ts" => {
        owner: "better_auth/oauth_provider/token_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/token_test.rb" => "test_client_secret_basic_authorization_code_exchange_uses_authenticated_client_id"},
        notes: "RFC Basic client authentication and OAuth error handling"
      },
      "src/utils/query-serialization.test.ts" => {
        owner: "better_auth/oauth_provider/utils/query_serialization_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/utils/query_serialization_test.rb" => "test_signed_query_rejects_duplicate_signature_and_fragments"},
        notes: "Signed query parsing, canonicalization, and reserved parameters"
      },
      "src/utils/timestamps.test.ts" => {
        owner: "better_auth/oauth_provider/utils/timestamps_test.rb",
        status: :covered,
        evidence: {"better_auth/oauth_provider/utils/timestamps_test.rb" => "test_normalize_timestamp_value_accepts_epoch_millis_strings"},
        notes: "Epoch-millisecond normalization and authentication time"
      }
    },
    exclusions: {
      "src/public-types.test.ts" => "TypeScript package export and option-helper type assertions have no Ruby runtime equivalent"
    }
  )
end
