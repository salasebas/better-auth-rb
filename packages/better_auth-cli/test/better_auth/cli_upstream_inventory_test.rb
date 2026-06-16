# frozen_string_literal: true

require "minitest/autorun"
require_relative "../support/upstream_cli_parity"

class BetterAuthCLIUpstreamInventoryTest < Minitest::Test
  EXPECTED_UPSTREAM_TEST_FILE_COUNT = 14

  def test_upstream_cli_test_file_count
    paths = BetterAuth::CLITestSupport::UpstreamCLIParity.upstream_test_paths
    assert_equal EXPECTED_UPSTREAM_TEST_FILE_COUNT, paths.length,
      "Upstream CLI test file count changed; refresh inventory before proceeding"
  end

  def test_every_upstream_test_file_is_classified
    upstream_tests = BetterAuth::CLITestSupport::UpstreamCLIParity.upstream_test_paths
    classified = BetterAuth::CLITestSupport::UpstreamCLIParity::EXCLUDED_UPSTREAM_TESTS.keys +
      BetterAuth::CLITestSupport::UpstreamCLIParity::RUBY_CLI_TEST_OWNERS.keys

    unclassified = upstream_tests.reject { |path| classified.include?(path) }
    stale = classified.reject { |path| upstream_tests.include?(path) }

    assert_empty unclassified, "Unclassified upstream tests: #{unclassified.join(", ")}"
    assert_empty stale, "Stale inventory entries: #{stale.join(", ")}"
  end

  def test_excluded_upstream_tests_include_reasons
    BetterAuth::CLITestSupport::UpstreamCLIParity::EXCLUDED_UPSTREAM_TESTS.each do |path, note|
      assert note.is_a?(String) && !note.strip.empty?, "Missing exclusion note for #{path}"
    end
  end

  def test_ruby_owner_paths_exist_for_applicable_entries
    BetterAuth::CLITestSupport::UpstreamCLIParity::RUBY_CLI_TEST_OWNERS.each do |upstream_path, entry|
      next if entry[:status] == :ruby_not_applicable

      BetterAuth::CLITestSupport::UpstreamCLIParity.owner_paths(entry).each do |owner_path|
        assert BetterAuth::CLITestSupport::UpstreamCLIParity.owner_exists?(owner_path),
          "Missing Ruby owner #{owner_path} for #{upstream_path}"
        refute owner_path.start_with?("reference/upstream-src"),
          "Owner must not point into upstream source tree: #{owner_path}"
      end
    end
  end

  def test_no_ruby_owner_points_into_upstream_source_tree
    BetterAuth::CLITestSupport::UpstreamCLIParity::RUBY_CLI_TEST_OWNERS.each_value do |entry|
      BetterAuth::CLITestSupport::UpstreamCLIParity.owner_paths(entry).each do |owner_path|
        refute_includes owner_path, "reference/upstream-src"
      end
    end
  end
end
