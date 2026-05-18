# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry"

require_relative "support/env_helpers"
require_relative "support/recording_track"

# Verifies that `BetterAuth::Telemetry.create` composes and emits a
# single init event whose shape matches Requirement 6 and the design's
# init-event sequence diagram.
#
# Specifically:
#
#   - Exactly one event is recorded with `type: "init"`
#     (Requirement 6.1).
#   - `anonymousId` matches the value
#     `BetterAuth::Telemetry.project_id(base_url)` resolves under the
#     same `app_name` scope (Requirement 6.2).
#   - The `payload` hash carries the seven required camelCase keys
#     `:config, :runtime, :database, :framework, :environment,
#     :systemInfo, :packageManager` (Requirement 6.3).
#   - `runtime[:name] == "ruby"` (Requirement 6.5 / 7.1).
#   - `environment` is one of `production / ci / test / development`
#     (Requirement 6.6 / 8).
#   - `systemInfo` does not carry a `:cpuSpeed` key (Requirement 6.8 —
#     Ruby-specific deviation).
class CreateInitEventTest < Minitest::Test
  Telemetry = BetterAuth::Telemetry
  Publisher = BetterAuth::Telemetry::Publisher
  EnvHelpers = BetterAuth::Telemetry::Test::EnvHelpers
  RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack

  BASE_URL = "https://example.com"
  APP_NAME = "InitEventTestApp"

  REQUIRED_PAYLOAD_KEYS = %i[
    config
    runtime
    database
    framework
    environment
    systemInfo
    packageManager
  ].freeze

  ALLOWED_ENVIRONMENTS = %w[production ci test development].freeze

  def setup
    Telemetry.reset_project_id!
  end

  def teardown
    Telemetry.reset_project_id!
  end

  def test_create_emits_single_init_event_with_required_shape
    recorder = RecordingTrack.new

    EnvHelpers.with_env(neutral_env_overrides) do
      publisher = Telemetry.create(
        {
          telemetry: {enabled: true},
          app_name: APP_NAME,
          base_url: BASE_URL
        },
        {custom_track: recorder, skip_test_check: true}
      )

      assert_kind_of Publisher, publisher
      assert_predicate publisher, :enabled?
    end

    events = recorder.events
    assert_equal 1, events.size, "expected exactly one init event at create time"

    event = events.first
    assert_equal "init", event[:type], "init event must have type: \"init\""

    payload = event[:payload]
    assert_kind_of Hash, payload
    assert_equal REQUIRED_PAYLOAD_KEYS.sort, payload.keys.sort,
      "payload must have exactly the seven camelCase keys"

    expected_id = Telemetry::CurrentOptions.with_app_name(APP_NAME) do
      Telemetry.project_id(BASE_URL)
    end
    assert_equal expected_id, event[:anonymousId],
      "anonymousId must equal BetterAuth::Telemetry.project_id(base_url) under the same app_name scope"

    runtime = payload[:runtime]
    assert_kind_of Hash, runtime
    assert_equal "ruby", runtime[:name]

    assert_includes ALLOWED_ENVIRONMENTS, payload[:environment]

    system_info = payload[:systemInfo]
    assert_kind_of Hash, system_info
    refute_includes system_info.keys, :cpuSpeed,
      "systemInfo must not carry a :cpuSpeed key (Ruby-specific deviation)"
  end

  private

  # Baseline ENV overrides: clear telemetry env vars and the test-env
  # markers so the test drives only the variables it cares about.
  def neutral_env_overrides
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
end
