# frozen_string_literal: true

require_relative "../test_helper"
require "base64"
require "digest"
require "minitest/mock"
require "better_auth/telemetry/project_id"

class ProjectIdDerivationTest < Minitest::Test
  CurrentOptions = BetterAuth::Telemetry::CurrentOptions
  ProjectId = BetterAuth::Telemetry::ProjectId
  Telemetry = BetterAuth::Telemetry

  def setup
    Telemetry.reset_project_id!
    CurrentOptions.app_name = nil
  end

  def teardown
    Telemetry.reset_project_id!
    CurrentOptions.app_name = nil
  end

  # Rule 1: project name resolvable AND base_url non-empty.
  def test_returns_base64_sha256_of_base_url_plus_name
    expected = base64_sha256("https://example.com" + "MyProject")

    CurrentOptions.with_app_name("MyProject") do
      assert_equal expected, Telemetry.project_id("https://example.com")
    end
  end

  # Rule 2: project name resolvable AND base_url nil/empty.
  def test_returns_base64_sha256_of_name_when_base_url_is_nil
    expected = base64_sha256("MyProject")

    CurrentOptions.with_app_name("MyProject") do
      assert_equal expected, Telemetry.project_id(nil)
    end
  end

  def test_returns_base64_sha256_of_name_when_base_url_is_empty
    Telemetry.reset_project_id!
    expected = base64_sha256("MyProject")

    CurrentOptions.with_app_name("MyProject") do
      assert_equal expected, Telemetry.project_id("")
    end
  end

  # Rule 3: no project name AND base_url non-empty.
  def test_returns_base64_sha256_of_base_url_when_no_project_name_resolvable
    expected = base64_sha256("https://example.com")

    ProjectId.stub(:resolve_project_name, nil) do
      assert_equal expected, Telemetry.project_id("https://example.com")
    end
  end

  # Rule 4: no project name AND base_url nil/empty -> random 32-char id.
  def test_returns_random_alphanumeric_id_when_neither_name_nor_base_url
    ProjectId.stub(:resolve_project_name, nil) do
      id = Telemetry.project_id(nil)

      assert_equal 32, id.length
      assert_match(/\A[a-zA-Z0-9]{32}\z/, id)
    end
  end

  def test_returns_random_alphanumeric_id_when_name_missing_and_base_url_empty
    ProjectId.stub(:resolve_project_name, nil) do
      id = Telemetry.project_id("")

      assert_equal 32, id.length
      assert_match(/\A[a-zA-Z0-9]{32}\z/, id)
    end
  end

  def test_memoizes_by_derivation_input_instead_of_first_process_value
    first = CurrentOptions.with_app_name("MyProject") do
      Telemetry.project_id("https://a.example")
    end

    second = CurrentOptions.with_app_name("OtherProject") do
      Telemetry.project_id("https://b.example")
    end

    assert_equal first, CurrentOptions.with_app_name("MyProject") { Telemetry.project_id("https://a.example") }
    refute_equal first, second
  end

  def test_reset_project_id_re_runs_derivation
    first = CurrentOptions.with_app_name("MyProject") do
      Telemetry.project_id("https://a.example")
    end

    Telemetry.reset_project_id!

    second = CurrentOptions.with_app_name("OtherProject") do
      Telemetry.project_id("https://a.example")
    end

    refute_equal first, second
    assert_equal base64_sha256("https://a.example" + "OtherProject"), second
  end

  # Requirement 14.8: a missing or broken Bundler must not raise. The
  # whole resolver chain is wrapped in `rescue StandardError; nil`, so
  # a probe that raises degrades to the next rule.
  def test_does_not_raise_when_bundler_probes_fail
    # Stub both Bundler-backed probes to simulate a process where
    # Bundler is absent (or `Bundler.locked_gems` raises). The
    # resolver should fall through to "no project name resolvable",
    # which combined with a base_url falls into rule 3 — no raise.
    ProjectId.stub(:from_locked_gems, nil) do
      ProjectId.stub(:from_bundler_root, nil) do
        id = Telemetry.project_id("https://example.com")

        assert_equal base64_sha256("https://example.com"), id
      end
    end
  end

  def test_does_not_raise_when_bundler_probes_themselves_raise
    # Even when an underlying probe raises, `resolve_project_name`'s
    # outer `rescue StandardError` (and the per-probe rescues that
    # short-circuit before propagation in the real implementation)
    # absorb the failure. With both Bundler-backed probes raising and
    # no app_name set, the resolver yields `nil` for the project name
    # and the chain falls into rule 3 — `base64(sha256(base_url))`.
    raising = ->(*) { raise "bundler unavailable" }

    ProjectId.stub(:from_locked_gems, raising) do
      ProjectId.stub(:from_bundler_root, raising) do
        id = Telemetry.project_id("https://example.com")

        assert_equal base64_sha256("https://example.com"), id
      end
    end
  end

  # Requirement 14.7: the project-name resolver treats the literal
  # "Better Auth" sentinel as "not configured" and falls through to
  # the Bundler-derived rules.
  def test_default_app_name_is_treated_as_not_configured
    expected_with_bundler = nil
    fallback = "fallback-project"

    ProjectId.stub(:from_locked_gems, fallback) do
      ProjectId.stub(:from_bundler_root, fallback) do
        CurrentOptions.with_app_name(ProjectId::DEFAULT_APP_NAME) do
          expected_with_bundler = Telemetry.project_id("https://example.com")
        end
      end
    end

    assert_equal base64_sha256("https://example.com" + fallback), expected_with_bundler
  end

  def test_project_id_uses_bundler_root_fallback_not_first_locked_gem
    ProjectId.stub(:from_app_name, nil) do
      ProjectId.stub(:from_locked_gems, "rake") do
        ProjectId.stub(:from_bundler_root, "my_app") do
          assert_equal base64_sha256("https://example.com" + "my_app"), Telemetry.project_id("https://example.com")
        end
      end
    end
  end

  private

  def base64_sha256(input)
    Base64.strict_encode64(Digest::SHA256.digest(input))
  end
end

class ProjectIdResolveProjectNameTest < Minitest::Test
  CurrentOptions = BetterAuth::Telemetry::CurrentOptions
  ProjectId = BetterAuth::Telemetry::ProjectId

  def setup
    CurrentOptions.app_name = nil
  end

  def teardown
    CurrentOptions.app_name = nil
  end

  def test_from_app_name_returns_nil_when_unset
    assert_nil ProjectId.from_app_name
  end

  def test_from_app_name_returns_nil_for_default_better_auth_sentinel
    CurrentOptions.with_app_name("Better Auth") do
      assert_nil ProjectId.from_app_name
    end
  end

  def test_from_app_name_returns_value_when_custom
    CurrentOptions.with_app_name("MyApp") do
      assert_equal "MyApp", ProjectId.from_app_name
    end
  end

  def test_from_app_name_returns_nil_for_empty_string
    CurrentOptions.with_app_name("") do
      assert_nil ProjectId.from_app_name
    end
  end

  def test_resolve_project_name_returns_nil_when_no_rule_matches
    ProjectId.stub(:from_app_name, nil) do
      ProjectId.stub(:from_locked_gems, nil) do
        ProjectId.stub(:from_bundler_root, nil) do
          assert_nil ProjectId.resolve_project_name
        end
      end
    end
  end

  def test_resolve_project_name_first_wins
    ProjectId.stub(:from_app_name, "first") do
      ProjectId.stub(:from_locked_gems, "second") do
        ProjectId.stub(:from_bundler_root, "third") do
          assert_equal "first", ProjectId.resolve_project_name
        end
      end
    end
  end

  def test_resolve_project_name_falls_through_on_nil
    ProjectId.stub(:from_app_name, nil) do
      ProjectId.stub(:from_locked_gems, "second") do
        ProjectId.stub(:from_bundler_root, "third") do
          assert_equal "third", ProjectId.resolve_project_name
        end
      end
    end
  end

  def test_resolve_project_name_swallows_unexpected_errors
    boom = -> { raise "kaboom" }

    ProjectId.stub(:from_app_name, boom) do
      assert_nil ProjectId.resolve_project_name
    end
  end
end

class ProjectIdCurrentOptionsTest < Minitest::Test
  CurrentOptions = BetterAuth::Telemetry::CurrentOptions

  def setup
    CurrentOptions.app_name = nil
  end

  def teardown
    CurrentOptions.app_name = nil
  end

  def test_app_name_defaults_to_nil
    assert_nil CurrentOptions.app_name
  end

  def test_app_name_setter_round_trips
    CurrentOptions.app_name = "MyApp"

    assert_equal "MyApp", CurrentOptions.app_name
  ensure
    CurrentOptions.app_name = nil
  end

  def test_with_app_name_sets_value_inside_block
    captured = nil

    CurrentOptions.with_app_name("scoped") do
      captured = CurrentOptions.app_name
    end

    assert_equal "scoped", captured
  end

  def test_with_app_name_restores_prior_value
    CurrentOptions.app_name = "outer"

    CurrentOptions.with_app_name("inner") do
      assert_equal "inner", CurrentOptions.app_name
    end

    assert_equal "outer", CurrentOptions.app_name
  end

  def test_with_app_name_restores_when_block_raises
    CurrentOptions.app_name = "outer"

    assert_raises(RuntimeError) do
      CurrentOptions.with_app_name("inner") { raise "boom" }
    end

    assert_equal "outer", CurrentOptions.app_name
  end

  def test_with_app_name_returns_block_value
    result = CurrentOptions.with_app_name("scoped") { 42 }

    assert_equal 42, result
  end

  def test_app_name_is_thread_local
    CurrentOptions.app_name = "main-thread"

    other = Thread.new {
      CurrentOptions.app_name = "other-thread"
      CurrentOptions.app_name
    }.value

    assert_equal "other-thread", other
    assert_equal "main-thread", CurrentOptions.app_name
  end
end
