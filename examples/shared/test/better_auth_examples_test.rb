# frozen_string_literal: true

require "minitest/autorun"
require "rack/mock"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift File.expand_path("../../../packages/better_auth/lib", __dir__)

require "better_auth_examples"

class BetterAuthExamplesTest < Minitest::Test
  def test_settings_round_trip_sanitizes_supported_values
    settings = BetterAuthExamples::Settings.normalize(
      "database" => "postgres",
      "rate_adapter" => "redis",
      "rate_window" => "25",
      "rate_max" => "9"
    )

    assert_equal "postgres", settings[:database]
    assert_equal "redis", settings[:rate_adapter]
    assert_equal 25, settings[:rate_window]
    assert_equal 9, settings[:rate_max]

    cookie = BetterAuthExamples::Settings.cookie_value(settings)
    parsed = BetterAuthExamples::Settings.from_cookie(cookie)

    assert_equal settings, parsed
  end

  def test_rate_limit_config_uses_global_custom_rule
    settings = BetterAuthExamples::Settings.normalize(
      database: "memory",
      rate_adapter: "memory",
      rate_window: 2,
      rate_max: 1
    )

    config = BetterAuthExamples::RateLimitSettings.config(settings)

    assert_equal true, config[:enabled]
    assert_equal "memory", config[:storage]
    assert_equal({window: 2, max: 1}, config[:custom_rules].fetch("*"))
  end

  def test_auth_registry_uses_cached_auth_and_can_reset
    registry = BetterAuthExamples::AuthRegistry.new(
      app_name: "Test Example",
      base_url: "http://example.test",
      root_path: File.expand_path("tmp", __dir__)
    )
    settings = BetterAuthExamples::Settings.normalize(database: "memory")

    first = registry.auth_for(settings)
    second = registry.auth_for(settings)
    assert_same first, second

    registry.reset!(settings)
    refute_same first, registry.auth_for(settings)
  end

  def test_auth_registry_uses_dynamic_localhost_base_url
    registry = BetterAuthExamples::AuthRegistry.new(
      app_name: "Test Example",
      base_url: "http://localhost:3456",
      root_path: File.expand_path("tmp", __dir__)
    )

    auth = registry.auth_for(BetterAuthExamples::Settings.normalize(database: "memory"))

    assert_equal(
      {
        allowed_hosts: ["localhost:*", "127.0.0.1:*", "[::1]:*"],
        protocol: "http",
        fallback: "http://localhost:3456"
      },
      auth.options.base_url_config
    )
  end
end
