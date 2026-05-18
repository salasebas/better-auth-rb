# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth"
require "better_auth/telemetry/options"

class NormalizedOptionsTest < Minitest::Test
  NormalizedOptions = BetterAuth::Telemetry::NormalizedOptions

  # ---------------------------------------------------------------------
  # Hash input — snake_case and camelCase resolve identically
  # ---------------------------------------------------------------------

  def test_from_hash_snake_and_camel_case_resolve_identically
    snake = NormalizedOptions.from(
      app_name: "Acme",
      base_url: "https://example.test",
      telemetry: {enabled: true, debug: false}
    )
    camel = NormalizedOptions.from(
      appName: "Acme",
      baseURL: "https://example.test",
      telemetry: {enabled: true, debug: false}
    )

    assert_equal snake.app_name, camel.app_name
    assert_equal snake.base_url, camel.base_url
    assert_equal snake.telemetry_enabled, camel.telemetry_enabled
    assert_equal snake.telemetry_debug, camel.telemetry_debug
  end

  def test_from_hash_string_keys_resolve_identically
    string_keys = NormalizedOptions.from(
      "app_name" => "Acme",
      "base_url" => "https://example.test",
      "telemetry" => {"enabled" => true, "debug" => true}
    )

    assert_equal "Acme", string_keys.app_name
    assert_equal "https://example.test", string_keys.base_url
    assert_equal true, string_keys.telemetry_enabled
    assert_equal true, string_keys.telemetry_debug
  end

  # ---------------------------------------------------------------------
  # nil / missing keys produce nil readers
  # ---------------------------------------------------------------------

  def test_from_nil_returns_nil_readers
    options = NormalizedOptions.from(nil)

    assert_nil options.app_name
    assert_nil options.base_url
    assert_nil options.telemetry_enabled
    assert_nil options.telemetry_debug
    assert_nil options.configuration
    refute_nil options.logger
  end

  def test_from_empty_hash_returns_nil_readers
    options = NormalizedOptions.from({})

    assert_nil options.app_name
    assert_nil options.base_url
    assert_nil options.telemetry_enabled
    assert_nil options.telemetry_debug
    assert_nil options.configuration
  end

  def test_telemetry_enabled_can_be_explicit_false
    options = NormalizedOptions.from(telemetry: {enabled: false})

    assert_equal false, options.telemetry_enabled
  end

  def test_telemetry_enabled_can_be_explicit_true
    options = NormalizedOptions.from(telemetry: {enabled: true})

    assert_equal true, options.telemetry_enabled
  end

  def test_missing_telemetry_block_yields_nil_readers
    options = NormalizedOptions.from(app_name: "X")

    assert_nil options.telemetry_enabled
    assert_nil options.telemetry_debug
  end

  # ---------------------------------------------------------------------
  # BetterAuth::Configuration input
  # ---------------------------------------------------------------------

  def test_from_configuration_reads_app_name_base_url_and_telemetry
    config = BetterAuth::Configuration.new(
      app_name: "Acme",
      base_url: "https://example.test",
      secret: "x" * 64,
      database: :memory,
      telemetry: {enabled: true, debug: true}
    )

    options = NormalizedOptions.from(config)

    assert_same config, options.configuration
    assert_equal "Acme", options.app_name
    assert_equal "https://example.test", options.base_url
    assert_equal true, options.telemetry_enabled
    assert_equal true, options.telemetry_debug
  end

  def test_configuration_reader_is_nil_for_hash_input
    options = NormalizedOptions.from(app_name: "Acme")

    assert_nil options.configuration
  end

  # ---------------------------------------------------------------------
  # Logger handling
  # ---------------------------------------------------------------------

  def test_logger_wraps_supplied_logger_with_logger_adapter
    captured = []
    callable = ->(level, message) { captured << [level, message] }

    options = NormalizedOptions.from(logger: callable)

    assert_kind_of BetterAuth::Telemetry::LoggerAdapter, options.logger
    options.logger.info("hi")
    assert_equal [[:info, "hi"]], captured
  end

  def test_logger_falls_back_to_default_when_absent
    options = NormalizedOptions.from(nil)

    assert_kind_of BetterAuth::Telemetry::LoggerAdapter, options.logger
  end
end

class NormalizedContextTest < Minitest::Test
  NormalizedContext = BetterAuth::Telemetry::NormalizedContext

  # ---------------------------------------------------------------------
  # snake_case and camelCase parity
  # ---------------------------------------------------------------------

  def test_snake_and_camel_case_resolve_identically
    track = ->(_event) {}

    snake = NormalizedContext.from(
      custom_track: track,
      skip_test_check: true,
      database: "postgres",
      adapter: "BetterAuth::Adapters::Postgres"
    )
    camel = NormalizedContext.from(
      customTrack: track,
      skipTestCheck: true,
      database: "postgres",
      adapter: "BetterAuth::Adapters::Postgres"
    )

    assert_same track, snake.custom_track
    assert_same track, camel.custom_track
    assert_equal snake.skip_test_check, camel.skip_test_check
    assert_equal snake.database, camel.database
    assert_equal snake.adapter, camel.adapter
  end

  def test_string_keys_resolve_identically
    ctx = NormalizedContext.from(
      "custom_track" => :placeholder,
      "skip_test_check" => true,
      "database" => "sqlite",
      "adapter" => "BetterAuth::Adapters::SQLite"
    )

    assert_equal :placeholder, ctx.custom_track
    assert_equal true, ctx.skip_test_check
    assert_equal "sqlite", ctx.database
    assert_equal "BetterAuth::Adapters::SQLite", ctx.adapter
  end

  # ---------------------------------------------------------------------
  # nil / missing keys produce defaults
  # ---------------------------------------------------------------------

  def test_from_nil_yields_defaults
    ctx = NormalizedContext.from(nil)

    assert_nil ctx.custom_track
    assert_nil ctx.database
    assert_nil ctx.adapter
    assert_equal false, ctx.skip_test_check
  end

  def test_from_empty_hash_yields_defaults
    ctx = NormalizedContext.from({})

    assert_nil ctx.custom_track
    assert_nil ctx.database
    assert_nil ctx.adapter
    assert_equal false, ctx.skip_test_check
  end

  def test_explicit_skip_test_check_false_is_preserved
    ctx = NormalizedContext.from(skip_test_check: false)

    assert_equal false, ctx.skip_test_check
  end

  def test_skip_test_check_nil_defaults_to_false
    ctx = NormalizedContext.from(skip_test_check: nil)

    assert_equal false, ctx.skip_test_check
  end
end
