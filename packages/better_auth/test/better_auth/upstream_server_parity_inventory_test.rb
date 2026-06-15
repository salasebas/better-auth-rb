# frozen_string_literal: true

require_relative "../test_helper"
require_relative "../support/upstream_server_parity"

class BetterAuthUpstreamServerParityInventoryTest < Minitest::Test
  HIGH_GAP_PLAN_EXPECTATIONS = {
    "context/create-context.test.ts" => "007",
    "cookies/cookies.test.ts" => "008",
    "api/routes/session-api.test.ts" => "008",
    "plugins/organization/organization.test.ts" => "010",
    "plugins/email-otp/email-otp.test.ts" => "011",
    "plugins/magic-link/magic-link.test.ts" => "011"
  }.freeze

  def test_every_upstream_test_file_is_classified
    upstream_tests = BetterAuth::TestSupport::UpstreamServerParity.upstream_test_paths
    classified = BetterAuth::TestSupport::UpstreamServerParity::EXCLUDED_UPSTREAM_TESTS.keys +
      BetterAuth::TestSupport::UpstreamServerParity::SERVER_UPSTREAM_TEST_OWNERS.keys

    unclassified = upstream_tests.reject { |path| classified.include?(path) }
    stale = classified.reject { |path| upstream_tests.include?(path) }

    assert_empty unclassified, "Unclassified upstream tests: #{unclassified.join(", ")}"
    assert_empty stale, "Stale inventory entries: #{stale.join(", ")}"
  end

  def test_excluded_upstream_tests_include_reasons
    BetterAuth::TestSupport::UpstreamServerParity::EXCLUDED_UPSTREAM_TESTS.each do |path, note|
      assert note.is_a?(String) && !note.strip.empty?, "Missing exclusion note for #{path}"
    end
  end

  def test_server_owner_paths_exist_for_applicable_entries
    BetterAuth::TestSupport::UpstreamServerParity::SERVER_UPSTREAM_TEST_OWNERS.each do |upstream_path, entry|
      next if entry[:status] == :ruby_not_applicable

      BetterAuth::TestSupport::UpstreamServerParity.owner_paths(entry).each do |owner_path|
        assert BetterAuth::TestSupport::UpstreamServerParity.owner_exists?(owner_path),
          "Missing Ruby owner #{owner_path} for #{upstream_path}"
        refute owner_path.start_with?("reference/upstream-src"),
          "Owner must not point into upstream source tree: #{owner_path}"
      end
    end
  end

  def test_no_server_owner_points_into_upstream_source_tree
    BetterAuth::TestSupport::UpstreamServerParity::SERVER_UPSTREAM_TEST_OWNERS.each_value do |entry|
      BetterAuth::TestSupport::UpstreamServerParity.owner_paths(entry).each do |owner_path|
        refute_includes owner_path, "reference/upstream-src"
      end
    end
  end

  def test_high_gap_upstream_files_map_to_expected_plans
    HIGH_GAP_PLAN_EXPECTATIONS.each do |upstream_path, expected_plan|
      entry = BetterAuth::TestSupport::UpstreamServerParity::SERVER_UPSTREAM_TEST_OWNERS.fetch(upstream_path)
      assert_equal expected_plan, entry.fetch(:plan),
        "Expected plan #{expected_plan} for #{upstream_path}, got #{entry.fetch(:plan)}"
      assert_equal :partial, entry.fetch(:status),
        "Expected partial status for #{upstream_path}"
    end
  end

  def test_auth_test_helpers_are_available_from_test_helper
    assert BetterAuthTestHelpers.respond_to?(:build_auth)
    assert_equal "GET", BetterAuthTestHelpers.json_rack_env("GET", "/api/auth/ok").fetch("REQUEST_METHOD")
    auth = BetterAuthTestHelpers.build_auth
    assert_equal true, auth.options.email_and_password[:enabled]
  end
end
