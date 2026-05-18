# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/mock"
require "better_auth/telemetry/detectors/system_info"
require_relative "../support/env_helpers"

class SystemInfoDetectorTest < Minitest::Test
  include BetterAuth::Telemetry::Test::EnvHelpers

  SystemInfo = BetterAuth::Telemetry::Detectors::SystemInfo

  REQUIRED_KEYS = %i[
    deploymentVendor
    systemPlatform
    systemRelease
    systemArchitecture
    cpuCount
    cpuModel
    memory
    isWSL
    isDocker
    isTTY
  ].freeze

  # All marker variables across the entire vendor table. Tests that
  # exercise vendor detection snapshot every one of these so a
  # vendor-flavored CI host (which exports `VERCEL`, `CF_PAGES`, …)
  # cannot bleed into the assertion.
  ALL_VENDOR_MARKERS = SystemInfo::VENDORS.flat_map { |(_, keys)| keys }.uniq.freeze

  def clean_vendor_env(extra = {})
    base = ALL_VENDOR_MARKERS.each_with_object({}) { |key, acc| acc[key] = nil }
    base.merge(extra.transform_keys(&:to_s))
  end

  # ---------------------------------------------------------------------
  # Required key set (Requirement 9.1) and `cpuSpeed` absence
  # (Ruby-specific deviation documented in design).
  # ---------------------------------------------------------------------

  def test_returns_hash_with_every_required_key
    with_env(clean_vendor_env) do
      result = SystemInfo.call

      assert_kind_of Hash, result
      REQUIRED_KEYS.each do |key|
        assert result.key?(key), "expected key #{key.inspect} to be present"
      end
    end
  end

  def test_does_not_include_cpu_speed_key
    with_env(clean_vendor_env) do
      result = SystemInfo.call

      refute result.key?(:cpuSpeed), "expected :cpuSpeed to be absent from systemInfo"
      refute result.key?("cpuSpeed"), "expected \"cpuSpeed\" to be absent from systemInfo"
    end
  end

  def test_cpu_model_is_nil
    with_env(clean_vendor_env) do
      assert_nil SystemInfo.call[:cpuModel]
    end
  end

  # ---------------------------------------------------------------------
  # Deployment vendor table (Requirement 9.10).
  # ---------------------------------------------------------------------

  def test_each_vendor_marker_resolves_to_matching_vendor
    SystemInfo::VENDORS.each do |(vendor, markers)|
      markers.each do |marker|
        with_env(clean_vendor_env(marker => "1")) do
          actual = SystemInfo.call[:deploymentVendor]
          assert_equal vendor, actual,
            "expected #{marker}=1 to resolve to deploymentVendor=#{vendor.inspect}, got #{actual.inspect}"
        end
      end
    end
  end

  def test_deployment_vendor_is_nil_when_no_marker_is_set
    with_env(clean_vendor_env) do
      assert_nil SystemInfo.call[:deploymentVendor]
    end
  end

  def test_empty_marker_value_is_treated_as_unset
    with_env(clean_vendor_env("VERCEL" => "")) do
      assert_nil SystemInfo.call[:deploymentVendor]
    end
  end

  def test_first_vendor_in_table_wins
    # cloudflare appears before vercel in VENDORS, so when both
    # marker sets are populated cloudflare must win.
    with_env(clean_vendor_env("CF_PAGES" => "1", "VERCEL" => "1")) do
      assert_equal "cloudflare", SystemInfo.call[:deploymentVendor]
    end
  end

  # ---------------------------------------------------------------------
  # Per-field rescue (Requirement 9.11): a probe that raises returns
  # `nil` for that field instead of raising out of `.call`.
  # ---------------------------------------------------------------------

  def test_raising_platform_probe_yields_nil_platform
    with_env(clean_vendor_env) do
      SystemInfo.stub(:platform, ->(*) { raise "boom" }) do
        result = SystemInfo.call
        assert_nil result[:systemPlatform]
        # Other fields still populated.
        assert result.key?(:systemRelease)
      end
    end
  end

  def test_raising_release_probe_yields_nil_release
    with_env(clean_vendor_env) do
      SystemInfo.stub(:release, ->(*) { raise "boom" }) do
        assert_nil SystemInfo.call[:systemRelease]
      end
    end
  end

  def test_raising_architecture_probe_yields_nil_architecture
    with_env(clean_vendor_env) do
      SystemInfo.stub(:architecture, ->(*) { raise "boom" }) do
        assert_nil SystemInfo.call[:systemArchitecture]
      end
    end
  end

  def test_raising_cpu_count_probe_yields_nil_cpu_count
    with_env(clean_vendor_env) do
      SystemInfo.stub(:cpu_count, ->(*) { raise "boom" }) do
        assert_nil SystemInfo.call[:cpuCount]
      end
    end
  end

  def test_raising_memory_probe_yields_nil_memory
    with_env(clean_vendor_env) do
      SystemInfo.stub(:total_memory_bytes, ->(*) { raise "boom" }) do
        assert_nil SystemInfo.call[:memory]
      end
    end
  end

  def test_raising_vendor_probe_yields_nil_vendor
    with_env(clean_vendor_env) do
      SystemInfo.stub(:detect_vendor, ->(*) { raise "boom" }) do
        assert_nil SystemInfo.call[:deploymentVendor]
      end
    end
  end

  def test_raising_docker_probe_yields_nil_is_docker
    with_env(clean_vendor_env) do
      SystemInfo.stub(:docker?, ->(*) { raise "boom" }) do
        assert_nil SystemInfo.call[:isDocker]
      end
    end
  end

  def test_raising_wsl_probe_yields_nil_is_wsl
    with_env(clean_vendor_env) do
      SystemInfo.stub(:wsl?, ->(*) { raise "boom" }) do
        assert_nil SystemInfo.call[:isWSL]
      end
    end
  end

  def test_raising_tty_probe_yields_nil_is_tty
    with_env(clean_vendor_env) do
      SystemInfo.stub(:tty?, ->(*) { raise "boom" }) do
        assert_nil SystemInfo.call[:isTTY]
      end
    end
  end

  def test_call_does_not_raise_when_every_probe_raises
    with_env(clean_vendor_env) do
      raising = ->(*) { raise "boom" }
      SystemInfo.stub(:detect_vendor, raising) do
        SystemInfo.stub(:platform, raising) do
          SystemInfo.stub(:release, raising) do
            SystemInfo.stub(:architecture, raising) do
              SystemInfo.stub(:cpu_count, raising) do
                SystemInfo.stub(:total_memory_bytes, raising) do
                  SystemInfo.stub(:wsl?, raising) do
                    SystemInfo.stub(:docker?, raising) do
                      SystemInfo.stub(:tty?, raising) do
                        result = SystemInfo.call

                        REQUIRED_KEYS.each do |key|
                          assert result.key?(key)
                          assert_nil result[key], "expected #{key} to be nil when its probe raises"
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  # ---------------------------------------------------------------------
  # isTTY reflects $stdout.tty? (Requirement 9.9).
  # ---------------------------------------------------------------------

  def test_is_tty_reflects_stdout_tty
    with_env(clean_vendor_env) do
      assert_equal $stdout.tty?, SystemInfo.call[:isTTY]
    end
  end

  def test_is_tty_true_when_stub_returns_true
    with_env(clean_vendor_env) do
      SystemInfo.stub(:tty?, true) do
        assert_equal true, SystemInfo.call[:isTTY]
      end
    end
  end

  def test_is_tty_false_when_stub_returns_false
    with_env(clean_vendor_env) do
      SystemInfo.stub(:tty?, false) do
        assert_equal false, SystemInfo.call[:isTTY]
      end
    end
  end

  # ---------------------------------------------------------------------
  # Architecture / platform helper smoke tests on the host.
  # ---------------------------------------------------------------------

  def test_platform_returns_a_known_short_identifier_or_nil_on_unknown_hosts
    value = SystemInfo.platform
    return assert_nil(value) if value.nil?

    assert_kind_of String, value
    refute_empty value
  end

  def test_architecture_returns_a_known_short_identifier_or_nil_on_unknown_hosts
    value = SystemInfo.architecture
    return assert_nil(value) if value.nil?

    assert_kind_of String, value
    refute_empty value
  end

  def test_release_is_a_string_or_nil
    value = SystemInfo.release
    return assert_nil(value) if value.nil?

    assert_kind_of String, value
  end
end
