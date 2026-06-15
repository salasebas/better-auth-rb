# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/doctor"
require "sqlite3"

class BetterAuthDoctorTest < Minitest::Test
  HARDENED_SECRET = "doctor-secret-1234567890-ABCDEFGHIJKLMNOPQRSTUVWXYZ"

  def test_reports_errors_warnings_and_ok_items
    config = BetterAuth::Configuration.new(
      secret: BetterAuth::Configuration::DEFAULT_SECRET,
      base_url: "http://example.test",
      database: ->(options) { BetterAuth::Adapters::SQLite.new(options, connection: sqlite_connection) }
    )

    result = BetterAuth::Doctor.check(config)

    assert result.errors.any? { |error| error.include?("secret uses the default") }
    assert result.warnings.any? { |warning| warning.include?("base_url is not HTTPS") }
    assert result.warnings.any? { |warning| warning.include?("rate_limit uses memory storage") }
    assert result.warnings.any? { |warning| warning.include?("pending Better Auth migrations") }
    assert_includes result.ok, "config loaded"
  end

  def test_passes_for_hardened_config_with_current_schema
    connection = sqlite_connection
    config = BetterAuth::Configuration.new(
      secret: HARDENED_SECRET,
      base_url: "https://example.test",
      rate_limit: {enabled: true, storage: "database"},
      database: ->(options) { BetterAuth::Adapters::SQLite.new(options, connection: connection) }
    )
    BetterAuth::SQLMigration.migrate_pending(BetterAuth.auth(config.to_h))

    result = BetterAuth::Doctor.check(config)

    assert_empty result.errors
    assert_empty result.warnings
    assert_includes result.ok, "secret length and entropy look acceptable"
    assert_includes result.ok, "database schema is up to date"
  end

  def test_missing_secret_returns_error
    config = BetterAuth::Configuration.new(secret: HARDENED_SECRET, database: :memory)
    config.define_singleton_method(:secret) { "" }
    result = BetterAuth::Doctor::Result.new(ok: [], warnings: [], errors: [])

    BetterAuth::Doctor.check_secret(config, result)

    assert result.errors.any? { |error| error.include?("secret is missing") }
  end

  def test_short_secret_returns_error
    config = BetterAuth::Configuration.new(secret: "too-short", database: :memory)

    result = BetterAuth::Doctor.check(config)

    assert result.errors.any? { |error| error.include?("at least 32 characters") }
  end

  def test_low_entropy_secret_returns_error
    config = BetterAuth::Configuration.new(secret: "a" * 32, database: :memory)

    result = BetterAuth::Doctor.check(config)

    assert result.errors.any? { |error| error.include?("low-entropy") }
  end

  def test_missing_base_url_returns_warning
    config = BetterAuth::Configuration.new(secret: HARDENED_SECRET, database: :memory)

    result = BetterAuth::Doctor.check(config)

    assert result.warnings.any? { |warning| warning.include?("base_url is not configured") }
  end

  def test_http_base_url_returns_warning
    config = BetterAuth::Configuration.new(
      secret: HARDENED_SECRET,
      base_url: "http://example.test",
      database: :memory
    )

    result = BetterAuth::Doctor.check(config)

    assert result.warnings.any? { |warning| warning.include?("base_url is not HTTPS") }
    refute_includes result.ok, "base_url uses HTTPS"
  end

  def test_https_base_url_returns_ok
    config = BetterAuth::Configuration.new(
      secret: HARDENED_SECRET,
      base_url: "https://example.test",
      database: :memory
    )

    result = BetterAuth::Doctor.check(config)

    assert_includes result.ok, "base_url uses HTTPS"
  end

  def test_disabled_rate_limit_warns
    config = BetterAuth::Configuration.new(
      secret: HARDENED_SECRET,
      database: :memory,
      rate_limit: {enabled: false, storage: "memory"}
    )

    result = BetterAuth::Doctor.check(config)

    assert result.warnings.any? { |warning| warning.include?("rate_limit is disabled") }
  end

  def test_memory_rate_limit_storage_warns
    config = BetterAuth::Configuration.new(
      secret: HARDENED_SECRET,
      database: :memory,
      rate_limit: {enabled: true, storage: "memory"}
    )

    result = BetterAuth::Doctor.check(config)

    assert result.warnings.any? { |warning| warning.include?("rate_limit uses memory storage") }
  end

  def test_database_rate_limit_storage_is_ok
    connection = sqlite_connection
    config = BetterAuth::Configuration.new(
      secret: HARDENED_SECRET,
      base_url: "https://example.test",
      database: ->(options) { BetterAuth::Adapters::SQLite.new(options, connection: connection) },
      rate_limit: {enabled: true, storage: "database"}
    )
    BetterAuth::SQLMigration.migrate_pending(BetterAuth.auth(config.to_h))

    result = BetterAuth::Doctor.check(config)

    assert_includes result.ok, "rate_limit storage is database"
    refute result.warnings.any? { |warning| warning.include?("rate_limit uses memory storage") }
  end

  def test_secondary_storage_rate_limit_is_ok
    config = BetterAuth::Configuration.new(
      secret: HARDENED_SECRET,
      database: :memory,
      rate_limit: {enabled: true, storage: "secondary-storage"}
    )

    result = BetterAuth::Doctor.check(config)

    assert_includes result.ok, "rate_limit storage is secondary-storage"
    refute result.warnings.any? { |warning| warning.include?("rate_limit uses memory storage") }
  end

  def test_non_introspectable_adapter_skips_schema_drift_check
    config = BetterAuth::Configuration.new(secret: HARDENED_SECRET, database: :memory)

    result = BetterAuth::Doctor.check(config)

    assert result.warnings.any? { |warning| warning.include?("schema drift check skipped") }
    refute result.warnings.any? { |warning| warning.include?("pending Better Auth migrations") }
  end

  def test_type_mismatch_warnings_surface_through_doctor
    connection = sqlite_connection
    connection.execute('CREATE TABLE "users" ("id" text PRIMARY KEY, "email" integer);')
    config = BetterAuth::Configuration.new(
      secret: HARDENED_SECRET,
      database: ->(options) { BetterAuth::Adapters::SQLite.new(options, connection: connection) }
    )

    result = BetterAuth::Doctor.check(config)

    assert result.warnings.any? { |warning| warning.include?("users.email") }
    assert result.warnings.any? { |warning| warning.include?("pending Better Auth migrations") }
  end

  private

  def sqlite_connection
    SQLite3::Database.new(":memory:").tap do |connection|
      connection.results_as_hash = true
      connection.execute("PRAGMA foreign_keys = ON")
    end
  end
end
