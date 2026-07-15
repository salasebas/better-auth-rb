# frozen_string_literal: true

require_relative "../../../../test/support/upstream_test_inventory"

module BetterAuthSSOUpstreamParity
  ROOT = File.expand_path("../../../..", __dir__)
  TEST_ROOT = File.expand_path("..", __dir__)
  LEDGER = UpstreamPackageTestLedger.new(
    repository_root: ROOT,
    upstream_subpath: "packages/sso",
    test_root: TEST_ROOT,
    entries: {
      "src/domain-verification.test.ts" => {
        owner: "better_auth/sso/domain_verification_test.rb",
        status: :covered,
        evidence: {"better_auth/sso/domain_verification_test.rb" => "test_verify_domain_requires_proof_for_every_listed_domain_and_accepts_raw_token"},
        notes: "Domain request/verification ownership, DNS proof, token lifetime, and storage"
      },
      "src/linking/org-assignment.test.ts" => {
        owner: "better_auth/sso/linking/org_assignment_test.rb",
        status: :covered,
        evidence: {"better_auth/sso/linking/org_assignment_test.rb" => "test_only_uses_verified_provider_when_multiple_providers_claim_same_domain"},
        notes: "Verified-domain organization assignment and role resolution"
      },
      "src/oidc.test.ts" => {
        owner: "better_auth/sso/rack_and_edge_cases_test.rb",
        status: :covered,
        evidence: {"better_auth/sso/rack_and_edge_cases_test.rb" => "test_rack_mounted_oidc_callback_creates_session"},
        notes: "OIDC sign-in/callback identity and Rack behavior"
      },
      "src/oidc/discovery.test.ts" => {
        owner: "better_auth/sso/providers_test.rb",
        status: :covered,
        evidence: {"better_auth/sso/providers_test.rb" => "test_update_provider_merges_resolved_issuer_into_protocol_configs"},
        notes: "OIDC discovery hydration and persisted provider configuration"
      },
      "src/providers.test.ts" => {
        owner: "better_auth/sso/providers_test.rb",
        status: :covered,
        evidence: {"better_auth/sso/providers_test.rb" => "test_delete_provider_transactionally_deletes_linked_accounts_but_preserves_user_and_other_identities"},
        notes: "Provider registration, update, visibility, authorization, and deletion"
      },
      "src/routes/helpers.test.ts" => {
        owner: "better_auth/sso/routes/helpers_test.rb",
        status: :covered,
        evidence: {"better_auth/sso/routes/helpers_test.rb" => "test_create_saml_post_form_delegates_to_plugins"},
        notes: "SAML helper delegation"
      },
      "src/saml.test.ts" => {
        owner: "../../better_auth-saml/test/better_auth/sso/saml_test.rb",
        status: :covered,
        evidence: {"../../better_auth-saml/test/better_auth/sso/saml_test.rb" => "test_replayed_saml_assertion_is_rejected_across_callback_and_acs"},
        notes: "SAML registration, callbacks, replay protection, linking, and logout behavior"
      },
      "src/saml/algorithms.test.ts" => {
        owner: "../../better_auth-saml/test/better_auth/sso/saml/algorithms_test.rb",
        status: :covered,
        evidence: {"../../better_auth-saml/test/better_auth/sso/saml/algorithms_test.rb" => "test_validate_config_rejects_deprecated_signature_even_when_digest_is_secure"},
        notes: "Signature and digest algorithm policy"
      },
      "src/saml/assertions.test.ts" => {
        owner: "../../better_auth-saml/test/better_auth/sso/saml/assertions_test.rb",
        status: :covered,
        evidence: {"../../better_auth-saml/test/better_auth/sso/saml/assertions_test.rb" => "test_rejects_deeply_nested_injected_assertion"},
        notes: "Single-assertion parsing and wrapping defenses"
      },
      "src/saml/response-binding.test.ts" => {
        owner: "../../better_auth-saml/test/better_auth/sso/saml_test.rb",
        status: :covered,
        evidence: {"../../better_auth-saml/test/better_auth/sso/saml_test.rb" => "test_signed_authn_request_signature_can_be_verified_by_idp"},
        notes: "Redirect binding signatures and relay-state preservation"
      },
      "src/utils.test.ts" => {
        owner: "better_auth/sso/utils_test.rb",
        status: :covered,
        evidence: {"better_auth/sso/utils_test.rb" => "test_parse_certificate_accepts_pem_and_raw_base64_certificates"},
        notes: "Domain, JSON, certificate, and client-id utilities"
      }
    }
  )
end
