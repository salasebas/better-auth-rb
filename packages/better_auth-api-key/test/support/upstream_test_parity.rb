# frozen_string_literal: true

require_relative "../../../../test/support/upstream_test_inventory"

module BetterAuthAPIKeyUpstreamParity
  ROOT = File.expand_path("../../../..", __dir__)
  TEST_ROOT = File.expand_path("..", __dir__)
  LEDGER = UpstreamPackageTestLedger.new(
    repository_root: ROOT,
    upstream_subpath: "packages/api-key",
    test_root: TEST_ROOT,
    entries: {
      "src/api-key.test.ts" => {
        owner: "better_auth/api_key_test.rb",
        status: :covered,
        evidence: {"better_auth/api_key_test.rb" => "test_create_verify_get_list_update_and_delete_api_key"},
        notes: "CRUD, verification, quota, rate-limit, storage, and configuration behavior"
      },
      "src/org-api-key.test.ts" => {
        owner: "better_auth/api_key/org_api_key_test.rb",
        status: :covered,
        evidence: {"better_auth/api_key/org_api_key_test.rb" => "test_organization_owner_has_full_crud_access"},
        notes: "Organization ownership, membership, and permission behavior"
      }
    }
  )
end
