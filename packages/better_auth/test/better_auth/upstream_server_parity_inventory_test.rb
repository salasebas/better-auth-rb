# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/upstream_server_parity"

class BetterAuthUpstreamServerParityInventoryTest < Minitest::Test
  PARITY = BetterAuth::TestSupport::UpstreamServerParity

  def test_real_inventory_is_valid
    assert_empty PARITY.validation_errors

    popup = PARITY::SERVER_UPSTREAM_TEST_OWNERS.fetch("plugins/oauth-popup/oauth-popup.test.ts")
    assert_equal "../../../docs/adr/0001-oauth-popup-server-half.md", popup.fetch(:owner)
    assert File.file?(File.expand_path(popup.fetch(:owner), PARITY::TEST_ROOT))
  end

  def test_validator_rejects_unplanned_partial_and_invalid_metadata
    path = "api/middlewares/authorization.test.ts"
    entries = PARITY::SERVER_UPSTREAM_TEST_OWNERS.merge(
      path => {owner: "better_auth/api_test.rb", status: :partial, notes: "fixture gap"}
    )
    errors = PARITY.validation_errors(entries: entries)
    assert_includes errors, "Missing current plan for partial #{path}"

    done_entries = PARITY::SERVER_UPSTREAM_TEST_OWNERS.merge(
      path => {owner: "better_auth/api_test.rb", status: :partial, plan: "019", notes: "fixture gap"}
    )
    done_errors = UpstreamTestInventory.validate(
      upstream_paths: PARITY.upstream_test_paths,
      entries: done_entries,
      exclusions: PARITY::EXCLUDED_UPSTREAM_TESTS,
      test_root: PARITY::TEST_ROOT,
      active_plans: {"019" => :done}
    )
    assert_includes done_errors, "Plan 019 is DONE for partial #{path}"

    invalid_path = "api/check-endpoint-conflicts.test.ts"
    invalid_entries = PARITY::SERVER_UPSTREAM_TEST_OWNERS.merge(
      invalid_path => {status: :unknown, notes: "fixture"}
    )
    invalid_errors = PARITY.validation_errors(entries: invalid_entries)
    assert invalid_errors.any? { |error| error.include?("Invalid status") }
    assert invalid_errors.any? { |error| error.include?("Missing Ruby owner") }

    na_entries = PARITY::SERVER_UPSTREAM_TEST_OWNERS.merge(
      invalid_path => {status: :ruby_not_applicable}
    )
    assert_includes PARITY.validation_errors(entries: na_entries), "Missing Ruby N/A reason for #{invalid_path}"

    missing_evidence = PARITY::SERVER_UPSTREAM_TEST_OWNERS.merge(
      path => PARITY::SERVER_UPSTREAM_TEST_OWNERS.fetch(path).merge(
        evidence: {"better_auth/api_test.rb" => "test_does_not_exist"}
      )
    )
    evidence_errors = PARITY.validation_errors(entries: missing_evidence)
    assert evidence_errors.any? { |error| error.include?("Missing named test test_does_not_exist") }
  end

  def test_auth_test_helpers_are_available_from_test_helper
    assert BetterAuthTestHelpers.respond_to?(:build_auth)
    assert_equal "GET", BetterAuthTestHelpers.json_rack_env("GET", "/api/auth/ok").fetch("REQUEST_METHOD")
    auth = BetterAuthTestHelpers.build_auth
    assert_equal true, auth.options.email_and_password[:enabled]
  end
end
