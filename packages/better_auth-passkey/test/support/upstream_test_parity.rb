# frozen_string_literal: true

require_relative "../../../../test/support/upstream_test_inventory"

module BetterAuthPasskeyUpstreamParity
  ROOT = File.expand_path("../../../..", __dir__)
  TEST_ROOT = File.expand_path("..", __dir__)
  LEDGER = UpstreamPackageTestLedger.new(
    repository_root: ROOT,
    upstream_subpath: "packages/passkey",
    test_root: TEST_ROOT,
    entries: {
      "src/authenticator-metadata.test.ts" => {
        owner: "better_auth/passkey/authenticator_metadata_test.rb",
        status: :covered,
        evidence: {"better_auth/passkey/authenticator_metadata_test.rb" => "test_common_authenticator_names_cover_every_upstream_provider_family"},
        notes: "Authenticator family naming and normalization"
      },
      "src/open-api.test.ts" => {
        owner: "better_auth/passkey_test.rb",
        status: :covered,
        evidence: {"better_auth/passkey_test.rb" => "test_visible_endpoints_have_complete_open_api_metadata"},
        notes: "Passkey endpoint OpenAPI metadata"
      },
      "src/passkey.test.ts" => {
        owner: ["better_auth/passkey/routes/registration_test.rb", "better_auth/passkey/routes/authentication_test.rb"],
        status: :covered,
        evidence: {
          "better_auth/passkey/routes/registration_test.rb" => "test_registration_name_uses_trimmed_client_then_hook_then_nil_and_runs_hook_once",
          "better_auth/passkey/routes/authentication_test.rb" => "test_concurrent_authentication_challenge_has_exactly_one_winner"
        },
        notes: "Registration, authentication, naming, management, and single-use challenge behavior"
      }
    },
    exclusions: {
      "src/client.test.ts" => "Browser WebAuthn client ceremony, extension merging, and TypeScript OAuth hooks have no Ruby server runtime equivalent"
    }
  )
end
