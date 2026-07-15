# frozen_string_literal: true

require_relative "../../../../test/support/upstream_test_inventory"

module BetterAuthSCIMUpstreamParity
  ROOT = File.expand_path("../../../..", __dir__)
  TEST_ROOT = File.expand_path("..", __dir__)
  LEDGER = UpstreamPackageTestLedger.new(
    repository_root: ROOT,
    upstream_subpath: "packages/scim",
    test_root: TEST_ROOT,
    entries: {
      "src/scim-patch.test.ts" => {
        owner: "better_auth/scim/scim_patch_test.rb",
        status: :covered,
        evidence: {"better_auth/scim/scim_patch_test.rb" => "test_scim_patch_email_is_unique_and_resets_verification_only_on_real_change"},
        notes: "PATCH operation variants, email safety, active state, and input limits"
      },
      "src/scim-users.test.ts" => {
        owner: "better_auth/scim/scim_users_test.rb",
        status: :covered,
        evidence: {"better_auth/scim/scim_users_test.rb" => "test_scim_put_active_revokes_secondary_sessions_and_can_reactivate"},
        notes: "User CRUD, filtering, provider boundaries, email uniqueness, and deprovisioning"
      },
      "src/scim.management.test.ts" => {
        owner: "better_auth/scim/scim_management_test.rb",
        status: :covered,
        evidence: {"better_auth/scim/scim_management_test.rb" => "test_default_scim_token_storage_is_hashed"},
        notes: "Provider/token management, ownership, storage modes, rotation, and hooks"
      },
      "src/scim.test.ts" => {
        owner: "better_auth/scim/scim_test.rb",
        status: :covered,
        evidence: {"better_auth/scim/scim_test.rb" => "test_scim_create_user_matches_upstream_resource_variants"},
        notes: "Plugin surface, SCIM schemas, errors, metadata, and create/update validation"
      }
    }
  )
end
