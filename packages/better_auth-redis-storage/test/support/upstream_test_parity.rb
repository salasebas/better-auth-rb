# frozen_string_literal: true

require_relative "../../../../test/support/upstream_test_inventory"

module BetterAuthRedisStorageUpstreamParity
  ROOT = File.expand_path("../../../..", __dir__)
  TEST_ROOT = File.expand_path("..", __dir__)
  LEDGER = UpstreamPackageTestLedger.new(
    repository_root: ROOT,
    upstream_subpath: "packages/redis-storage",
    test_root: TEST_ROOT,
    entries: {
      "test/redis-storage.test.ts" => {
        owner: "better_auth/redis_storage_test.rb",
        status: :covered,
        evidence: {"better_auth/redis_storage_test.rb" => "test_increment_is_atomic_and_sets_ttl_only_when_opening_the_window"},
        notes: "Prefixing, TTL, CRUD, scanning, clear, atomic consume/increment, and secondary-storage use"
      }
    }
  )
end
