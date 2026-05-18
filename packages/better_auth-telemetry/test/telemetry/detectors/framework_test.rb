# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/mock"
require "better_auth/telemetry/detectors/framework"

class FrameworkDetectorTest < Minitest::Test
  Framework = BetterAuth::Telemetry::Detectors::Framework

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  # Run the block with `Gem.loaded_specs` stubbed to `specs` (a
  # `Hash<String, Gem::Specification|FakeSpec>`). Restores the real
  # value on the way out.
  def with_loaded_specs(specs)
    ::Gem.stub(:loaded_specs, specs) do
      yield
    end
  end

  # Minimal stand-in for `Gem::Specification` that responds to
  # `#version` with a real `Gem::Version`. Used to drive the gem
  # fallback branch without depending on the live gem environment.
  FakeSpec = Struct.new(:version) do
    def self.with_version(string)
      new(::Gem::Version.new(string))
    end
  end

  # ---------------------------------------------------------------------
  # Empty / no-match cases (Requirement 11.3)
  # ---------------------------------------------------------------------

  def test_returns_nil_when_no_gems_loaded
    with_loaded_specs({}) do
      assert_nil Framework.call
    end
  end

  def test_returns_nil_when_only_unrelated_gems_loaded
    specs = {
      "redis" => FakeSpec.with_version("5.0.0"),
      "pg" => FakeSpec.with_version("1.5.6")
    }

    with_loaded_specs(specs) do
      assert_nil Framework.call
    end
  end

  # ---------------------------------------------------------------------
  # Single-gem probes (Requirement 11.2)
  # ---------------------------------------------------------------------

  def test_each_supported_gem_resolves_in_isolation
    Framework::GEMS.each do |gem_name|
      specs = {gem_name => FakeSpec.with_version("9.9.9")}

      with_loaded_specs(specs) do
        assert_equal(
          {name: gem_name, version: "9.9.9"},
          Framework.call,
          "expected the lone presence of #{gem_name.inspect} to win"
        )
      end
    end
  end

  # ---------------------------------------------------------------------
  # Declaration-order precedence (Requirement 11.1)
  # ---------------------------------------------------------------------

  def test_rails_wins_over_sinatra_hanami_and_rack
    specs = {
      "rack" => FakeSpec.with_version("3.1.0"),
      "sinatra" => FakeSpec.with_version("4.0.0"),
      "hanami" => FakeSpec.with_version("2.1.0"),
      "rails" => FakeSpec.with_version("7.1.3")
    }

    with_loaded_specs(specs) do
      assert_equal({name: "rails", version: "7.1.3"}, Framework.call)
    end
  end

  def test_sinatra_wins_when_rails_absent
    specs = {
      "rack" => FakeSpec.with_version("3.1.0"),
      "roda" => FakeSpec.with_version("3.79.0"),
      "sinatra" => FakeSpec.with_version("4.0.0")
    }

    with_loaded_specs(specs) do
      assert_equal({name: "sinatra", version: "4.0.0"}, Framework.call)
    end
  end

  def test_hanami_wins_over_hanami_router
    specs = {
      "rack" => FakeSpec.with_version("3.1.0"),
      "hanami-router" => FakeSpec.with_version("2.1.0"),
      "hanami" => FakeSpec.with_version("2.1.0")
    }

    with_loaded_specs(specs) do
      assert_equal({name: "hanami", version: "2.1.0"}, Framework.call)
    end
  end

  def test_hanami_router_wins_when_hanami_absent
    specs = {
      "rack" => FakeSpec.with_version("3.1.0"),
      "roda" => FakeSpec.with_version("3.79.0"),
      "hanami-router" => FakeSpec.with_version("2.1.0")
    }

    with_loaded_specs(specs) do
      assert_equal({name: "hanami-router", version: "2.1.0"}, Framework.call)
    end
  end

  def test_roda_wins_over_grape_and_rack
    specs = {
      "rack" => FakeSpec.with_version("3.1.0"),
      "grape" => FakeSpec.with_version("2.0.0"),
      "roda" => FakeSpec.with_version("3.79.0")
    }

    with_loaded_specs(specs) do
      assert_equal({name: "roda", version: "3.79.0"}, Framework.call)
    end
  end

  def test_grape_wins_over_rack
    specs = {
      "rack" => FakeSpec.with_version("3.1.0"),
      "grape" => FakeSpec.with_version("2.0.0")
    }

    with_loaded_specs(specs) do
      assert_equal({name: "grape", version: "2.0.0"}, Framework.call)
    end
  end

  def test_rack_wins_only_when_no_other_supported_framework_present
    specs = {"rack" => FakeSpec.with_version("3.1.0")}

    with_loaded_specs(specs) do
      assert_equal({name: "rack", version: "3.1.0"}, Framework.call)
    end
  end

  # ---------------------------------------------------------------------
  # Node-only frameworks must never match (Requirement 11.4)
  # ---------------------------------------------------------------------

  def test_node_only_framework_names_do_not_match
    specs = {
      "next" => FakeSpec.with_version("14.0.0"),
      "nuxt" => FakeSpec.with_version("3.0.0"),
      "astro" => FakeSpec.with_version("4.0.0"),
      "sveltekit" => FakeSpec.with_version("2.0.0"),
      "express" => FakeSpec.with_version("4.18.0"),
      "hono" => FakeSpec.with_version("4.0.0")
    }

    with_loaded_specs(specs) do
      assert_nil Framework.call
    end
  end

  # ---------------------------------------------------------------------
  # Failure handling: the whole call is wrapped in `rescue StandardError`.
  # ---------------------------------------------------------------------

  def test_returns_nil_when_gem_loaded_specs_raises
    raising = lambda { raise "boom" }

    ::Gem.stub(:loaded_specs, raising) do
      assert_nil Framework.call
    end
  end
end
