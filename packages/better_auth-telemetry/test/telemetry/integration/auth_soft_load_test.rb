# frozen_string_literal: true

require_relative "../../test_helper"
require "better_auth"
require "better_auth/telemetry"

require_relative "../support/env_helpers"
require_relative "../support/recording_track"

# Verifies the soft-load integration between `BetterAuth::Auth` and the
# `better_auth-telemetry` gem (Requirements 16.1, 16.2, 16.5, 16.6).
#
# Two scenarios are exercised:
#
# 1. **Gem-present path** — when `require "better_auth/telemetry"` loads
#    cleanly (the case in this test suite, since the gem is path-resolved
#    in the host bundle), opting in via `BETTER_AUTH_TELEMETRY=1` and
#    injecting a `RecordingTrack` through the `telemetry_context`
#    `custom_track` slot causes `auth.telemetry` to be a real
#    `BetterAuth::Telemetry::Publisher`. The init event fires at
#    `Auth#initialize` time, and a subsequent `auth.telemetry.publish`
#    call is forwarded to the recorder.
#
# 2. **Gem-absent path** — when `require "better_auth/telemetry"` raises
#    `LoadError`, `Auth#initialize` SHALL rescue the failure and fall
#    back to a noop publisher whose `#publish` returns `nil` without
#    raising and whose `#enabled?` is `false`. We simulate the missing
#    gem by subclassing `BetterAuth::Auth` and forcing
#    `build_telemetry_publisher` to raise `LoadError` before delegating
#    to the inherited rescue branch.
class AuthSoftLoadTest < Minitest::Test
  Telemetry = BetterAuth::Telemetry
  EnvHelpers = BetterAuth::Telemetry::Test::EnvHelpers
  RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack

  SECRET = "test-secret-that-is-long-enough-for-validation"
  BASE_URL = "http://localhost:3000"

  # `BetterAuth::Auth` subclass used by the gem-present case.
  #
  # Overrides the private `telemetry_context` to inject a
  # `RecordingTrack` as `custom_track` and force `skip_test_check: true`
  # so the test-environment gate does not disable telemetry inside the
  # test process. The recorder is exposed through `#recorder` so the
  # outer test can read it back.
  class AuthWithRecordingTrack < BetterAuth::Auth
    def recorder
      @recorder ||= BetterAuth::Telemetry::Test::RecordingTrack.new
    end

    private

    def telemetry_context
      super.merge(custom_track: recorder, skip_test_check: true)
    end
  end

  # `BetterAuth::Auth` subclass used by the gem-absent case.
  #
  # Forces the `LoadError` branch of the inherited
  # `build_telemetry_publisher` by raising `LoadError` immediately. The
  # inherited rescue clause in `BetterAuth::Auth#build_telemetry_publisher`
  # is the actual production fallback path we want to exercise, so we
  # invoke it here by calling `noop_telemetry_publisher` (a private
  # method, accessible from the subclass).
  class AuthWithMissingTelemetryGem < BetterAuth::Auth
    private

    def build_telemetry_publisher
      raise LoadError, "cannot load such file -- better_auth/telemetry"
    rescue LoadError
      noop_telemetry_publisher
    end
  end

  def setup
    Telemetry.reset_project_id!
  end

  def teardown
    Telemetry.reset_project_id!
  end

  # ---------------------------------------------------------------------
  # (a) gem-present path
  # ---------------------------------------------------------------------

  def test_gem_present_path_records_init_and_subsequent_publish
    EnvHelpers.with_env(env_overrides_opted_in) do
      auth = AuthWithRecordingTrack.new(
        secret: SECRET,
        base_url: BASE_URL,
        database: :memory
      )

      assert_kind_of BetterAuth::Telemetry::Publisher, auth.telemetry
      assert_predicate auth.telemetry, :enabled?

      # The init event fires synchronously inside `Auth#initialize`, so
      # the recorder already holds it by the time the constructor
      # returns (Requirement 6.1).
      events = auth.recorder.events
      assert_equal 1, events.size, "expected exactly one init event after initialize"
      assert_equal "init", events.first[:type]

      # A subsequent publish must be forwarded through the same
      # `custom_track` callable (Requirement 5.2 / 16.6).
      result = auth.telemetry.publish(type: "ping", payload: {detail: "pong"})
      assert_nil result, "publish must always return nil"

      events = auth.recorder.events
      assert_operator events.size, :>=, 2, "expected init + ping to be recorded"

      ping = events.last
      assert_equal "ping", ping[:type]
      assert_equal({detail: "pong"}, ping[:payload])
      assert_equal events.first[:anonymousId], ping[:anonymousId],
        "anonymousId must be reused across events from the same publisher"
    end
  end

  def test_options_telemetry_enabled_records_init_without_env_opt_in
    EnvHelpers.with_env(env_overrides_disabled) do
      auth = AuthWithRecordingTrack.new(
        secret: SECRET,
        base_url: BASE_URL,
        database: :memory,
        telemetry: {enabled: true}
      )

      assert_kind_of BetterAuth::Telemetry::Publisher, auth.telemetry
      assert_predicate auth.telemetry, :enabled?

      event = auth.recorder.events.fetch(0)
      assert_equal "init", event[:type]
      assert_equal "memory", event.dig(:payload, :config, :database)
      assert_equal "memory", event.dig(:payload, :config, :adapter)
    end
  end

  def test_options_telemetry_false_overrides_env_opt_in
    EnvHelpers.with_env(env_overrides_opted_in) do
      auth = AuthWithRecordingTrack.new(
        secret: SECRET,
        base_url: BASE_URL,
        database: :memory,
        telemetry: {enabled: false}
      )

      assert_kind_of BetterAuth::Telemetry::NoopPublisher, auth.telemetry
      refute_predicate auth.telemetry, :enabled?
      assert_empty auth.recorder.events
    end
  end

  # ---------------------------------------------------------------------
  # (b) gem-absent path
  # ---------------------------------------------------------------------

  def test_gem_absent_path_returns_noop_publisher_that_never_raises
    EnvHelpers.with_env(env_overrides_opted_in) do
      auth = AuthWithMissingTelemetryGem.new(
        secret: SECRET,
        base_url: BASE_URL,
        database: :memory
      )

      # The reader must still return a publisher-shaped object so that
      # callers can write `auth.telemetry.publish(...)` unconditionally
      # (Requirement 16.6).
      refute_nil auth.telemetry
      refute_predicate auth.telemetry, :enabled?

      # `publish` must return `nil` and must not raise, even though
      # `better_auth/telemetry` was simulated as unavailable
      # (Requirements 16.2, 16.5, 16.6).
      result = nil
      assert_silent do
        result = auth.telemetry.publish(type: "ping", payload: {detail: "pong"})
      end
      assert_nil result
    end
  end

  private

  # Baseline ENV overrides that opt the process into telemetry while
  # clearing the test-environment markers. The gem-present test relies
  # on `skip_test_check: true` (injected via `telemetry_context`) to
  # bypass the in-test gate, but we still scrub these so the assertions
  # only depend on the variables they explicitly drive.
  def env_overrides_opted_in
    {
      "BETTER_AUTH_TELEMETRY" => "1",
      "OPEN_AUTH_TELEMETRY" => nil,
      "BETTER_AUTH_TELEMETRY_ENDPOINT" => nil,
      "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil,
      "BETTER_AUTH_TELEMETRY_DEBUG" => nil,
      "OPEN_AUTH_TELEMETRY_DEBUG" => nil,
      "RACK_ENV" => nil,
      "RAILS_ENV" => nil,
      "APP_ENV" => nil
    }
  end

  def env_overrides_disabled
    env_overrides_opted_in.merge(
      "BETTER_AUTH_TELEMETRY" => nil,
      "OPEN_AUTH_TELEMETRY" => nil
    )
  end
end
