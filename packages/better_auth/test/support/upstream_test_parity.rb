# frozen_string_literal: true

require_relative "upstream_server_parity"

module BetterAuth
  module TestSupport
    module UpstreamTestParity
      ADAPTER_TESTS = {
        "core/src/db/adapter/factory.test.ts" => {
          status: :adapted,
          owner: "better_auth/adapters/adapter_contract.rb",
          evidence: {"better_auth/adapters/adapter_contract.rb" => "test_adapter_contract_coerces_boolean_and_numeric_filters_before_querying"},
          notes: "Where value coercion is verified through Memory and SQL queries. Custom-adapter factory parity is tracked in #289."
        },
        "memory-adapter/src/memory-adapter.test.ts" => {
          status: :adapted,
          owner: "better_auth/adapters/memory_test.rb",
          evidence: {"better_auth/adapters/memory_test.rb" => %w[
            test_failed_transaction_does_not_erase_an_unrelated_concurrent_write
            test_transaction_hides_uncommitted_writes_and_merges_only_changed_rows
          ]},
          notes: "The transaction isolation tests cover rollback, commit, concurrent changes, and in-place database updates."
        },
        "test-utils/src/adapter/suites/basic.ts" => {
          status: :adapted,
          owner: "better_auth/adapters/adapter_contract.rb",
          evidence: {"better_auth/adapters/adapter_contract.rb" => "test_adapter_contract_join_session_user"},
          notes: "The projected one-to-one and one-to-many join cases run against the Ruby Memory and SQL adapters."
        }
      }.freeze

      def self.validation_errors
        upstream_root = File.expand_path("../..", UpstreamServerParity::UPSTREAM_ROOT)
        paths = ADAPTER_TESTS.keys.select { |path| File.file?(File.join(upstream_root, path)) }
        UpstreamTestInventory.validate(
          upstream_paths: paths,
          entries: ADAPTER_TESTS,
          exclusions: {},
          test_root: UpstreamServerParity::TEST_ROOT,
          require_named_evidence: true
        )
      end
    end
  end
end
