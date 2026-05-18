# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry"
require_relative "support/env_helpers"
require_relative "support/recording_track"

# Verifies the eight-cell decision table from Property 3 of the
# telemetry-port design (Requirements 4.1–4.7) for
# `BetterAuth::Telemetry.create`.
#
# Inputs vary along four axes:
#
#   - `options_enabled`  ∈ {nil, true, false}   (options[:telemetry][:enabled])
#   - `env_truthy`       ∈ {true, false}        (BETTER_AUTH_TELEMETRY)
#   - `in_test`          ∈ {true, false}        (RACK_ENV/RAILS_ENV/APP_ENV)
#   - `skip_test_check`  ∈ {true, false}        (context[:skip_test_check])
#
# Twenty-four cells in total. The test asserts each call returns either a
# {BetterAuth::Telemetry::NoopPublisher} (when disabled) or a
# {BetterAuth::Telemetry::Publisher} whose `enabled?` is `true` (when
# enabled) — matching the decision-table outcome.
#
# The decision table only applies when at least one delivery channel is
# present (endpoint set OR `custom_track` supplied). To exercise the
# table we either set `BETTER_AUTH_TELEMETRY_ENDPOINT` via env or pass a
# {RecordingTrack} as `context[:custom_track]`. Two dedicated cases at
# the end pin down the no-delivery-channel short-circuit (always returns
# NoopPublisher regardless of the table).
class CreateDecisionTest < Minitest::Test
  Telemetry = BetterAuth::Telemetry
  NoopPublisher = BetterAuth::Telemetry::NoopPublisher
  Publisher = BetterAuth::Telemetry::Publisher
  EnvHelpers = BetterAuth::Telemetry::Test::EnvHelpers
  RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack

  ENDPOINT = "https://telemetry.example.test/collect"

  # Decision-table outcome computed straight from Property 3 so the test
  # body stays declarative.
  def expected_enabled?(options_enabled:, env_truthy:, in_test:, skip_test_check:)
    opt_in = options_enabled == true || (options_enabled.nil? && env_truthy)
    overridden = options_enabled == false
    in_test_gate = in_test && !skip_test_check
    opt_in && !overridden && !in_test_gate
  end

  # Drive every cell of the matrix.
  def test_decision_table_eight_cells_options_nil
    each_outer_cell(options_enabled: nil) do |env_truthy, in_test, skip|
      assert_decision(options_enabled: nil, env_truthy: env_truthy, in_test: in_test, skip_test_check: skip)
    end
  end

  def test_decision_table_eight_cells_options_true
    each_outer_cell(options_enabled: true) do |env_truthy, in_test, skip|
      assert_decision(options_enabled: true, env_truthy: env_truthy, in_test: in_test, skip_test_check: skip)
    end
  end

  def test_decision_table_eight_cells_options_false
    # options_enabled == false must always disable, regardless of env /
    # in_test / skip_test_check (explicit false beats env truthy).
    each_outer_cell(options_enabled: false) do |env_truthy, in_test, skip|
      assert_decision(options_enabled: false, env_truthy: env_truthy, in_test: in_test, skip_test_check: skip)
    end
  end

  # ---------------------------------------------------------------------
  # No-delivery-channel short-circuit (Requirement 5.1).
  # ---------------------------------------------------------------------

  def test_short_circuits_to_noop_when_no_endpoint_and_no_custom_track
    # Even with the strongest opt-in signals (env truthy, options true,
    # not in test, skip set), the absence of both `endpoint` and
    # `custom_track` must yield a NoopPublisher.
    EnvHelpers.with_env(
      "BETTER_AUTH_TELEMETRY_ENDPOINT" => nil,
      "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil,
      "BETTER_AUTH_TELEMETRY" => "1",
      "OPEN_AUTH_TELEMETRY" => nil,
      "RACK_ENV" => nil,
      "RAILS_ENV" => nil,
      "APP_ENV" => nil
    ) do
      publisher = Telemetry.create({telemetry: {enabled: true}}, {skip_test_check: true})
      assert_kind_of NoopPublisher, publisher
    end
  end

  def test_custom_track_alone_provides_delivery_channel_when_endpoint_absent
    # The decision table still applies once `custom_track` is supplied,
    # even with no endpoint configured.
    EnvHelpers.with_env(
      "BETTER_AUTH_TELEMETRY_ENDPOINT" => nil,
      "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil,
      "BETTER_AUTH_TELEMETRY" => nil,
      "OPEN_AUTH_TELEMETRY" => nil,
      "RACK_ENV" => nil,
      "RAILS_ENV" => nil,
      "APP_ENV" => nil
    ) do
      publisher = Telemetry.create(
        {telemetry: {enabled: true}},
        {custom_track: RecordingTrack.new}
      )
      assert_kind_of Publisher, publisher
      assert_predicate publisher, :enabled?
    end
  end

  private

  def each_outer_cell(options_enabled:)
    [true, false].each do |env_truthy|
      [true, false].each do |in_test|
        [true, false].each do |skip|
          yield(env_truthy, in_test, skip)
        end
      end
    end
  end

  # Drive a single cell of the decision table. We always set
  # `BETTER_AUTH_TELEMETRY_ENDPOINT` so the no-delivery-channel
  # short-circuit does not interfere with the assertion.
  def assert_decision(options_enabled:, env_truthy:, in_test:, skip_test_check:)
    overrides = {
      "BETTER_AUTH_TELEMETRY_ENDPOINT" => ENDPOINT,
      "OPEN_AUTH_TELEMETRY_ENDPOINT" => nil,
      "BETTER_AUTH_TELEMETRY" => env_truthy ? "1" : nil,
      "OPEN_AUTH_TELEMETRY" => nil,
      "RACK_ENV" => in_test ? "test" : nil,
      "RAILS_ENV" => nil,
      "APP_ENV" => nil
    }

    EnvHelpers.with_env(overrides) do
      options = build_options(options_enabled)
      context = {skip_test_check: skip_test_check}

      publisher = Telemetry.create(options, context)
      expected = expected_enabled?(
        options_enabled: options_enabled,
        env_truthy: env_truthy,
        in_test: in_test,
        skip_test_check: skip_test_check
      )

      label = "options_enabled=#{options_enabled.inspect} env_truthy=#{env_truthy} " \
              "in_test=#{in_test} skip=#{skip_test_check} -> expected_enabled=#{expected}"

      if expected
        assert_kind_of Publisher, publisher, "expected Publisher for #{label}"
        assert_predicate publisher, :enabled?, "expected enabled? to be true for #{label}"
      else
        assert_kind_of NoopPublisher, publisher, "expected NoopPublisher for #{label}"
        refute_predicate publisher, :enabled?, "expected enabled? to be false for #{label}"
      end
    end
  end

  def build_options(options_enabled)
    case options_enabled
    when nil then {}
    when true then {telemetry: {enabled: true}}
    when false then {telemetry: {enabled: false}}
    end
  end
end
