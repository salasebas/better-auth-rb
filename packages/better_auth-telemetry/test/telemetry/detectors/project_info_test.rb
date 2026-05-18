# frozen_string_literal: true

require_relative "../../test_helper"
require "minitest/mock"
require "better_auth/telemetry/detectors/project_info"

class ProjectInfoDetectorTest < Minitest::Test
  ProjectInfo = BetterAuth::Telemetry::Detectors::ProjectInfo

  # ---------------------------------------------------------------------
  # Bundler-present (Requirement 12.1)
  # ---------------------------------------------------------------------

  def test_returns_bundler_name_and_version_when_bundler_loaded_and_gemfile_locatable
    skip "Bundler not loaded in this environment" unless defined?(::Bundler)

    ProjectInfo.stub(:bundler_loaded?, true) do
      ProjectInfo.stub(:default_gemfile_locatable?, true) do
        result = ProjectInfo.call

        assert_equal({name: "bundler", version: ::Bundler::VERSION}, result)
      end
    end
  end

  def test_returned_version_is_a_string
    skip "Bundler not loaded in this environment" unless defined?(::Bundler)

    ProjectInfo.stub(:bundler_loaded?, true) do
      ProjectInfo.stub(:default_gemfile_locatable?, true) do
        assert_kind_of String, ProjectInfo.call[:version]
      end
    end
  end

  def test_returned_keys_are_exactly_name_and_version
    skip "Bundler not loaded in this environment" unless defined?(::Bundler)

    ProjectInfo.stub(:bundler_loaded?, true) do
      ProjectInfo.stub(:default_gemfile_locatable?, true) do
        assert_equal [:name, :version], ProjectInfo.call.keys.sort
      end
    end
  end

  # ---------------------------------------------------------------------
  # Bundler-absent (Requirement 12.2)
  # ---------------------------------------------------------------------

  def test_returns_nil_when_bundler_constant_not_defined
    ProjectInfo.stub(:bundler_loaded?, false) do
      assert_nil ProjectInfo.call
    end
  end

  def test_returns_nil_when_bundler_loaded_but_no_gemfile_locatable
    ProjectInfo.stub(:bundler_loaded?, true) do
      ProjectInfo.stub(:default_gemfile_locatable?, false) do
        assert_nil ProjectInfo.call
      end
    end
  end

  # ---------------------------------------------------------------------
  # Failure handling: the whole call is wrapped in `rescue StandardError`.
  # ---------------------------------------------------------------------

  def test_returns_nil_when_bundler_loaded_probe_raises
    raising = ->(*) { raise "boom" }

    ProjectInfo.stub(:bundler_loaded?, raising) do
      assert_nil ProjectInfo.call
    end
  end

  def test_returns_nil_when_default_gemfile_locatable_probe_raises
    raising = ->(*) { raise "boom" }

    ProjectInfo.stub(:bundler_loaded?, true) do
      ProjectInfo.stub(:default_gemfile_locatable?, raising) do
        assert_nil ProjectInfo.call
      end
    end
  end

  # ---------------------------------------------------------------------
  # default_gemfile_locatable? swallows Bundler::GemfileNotFound itself.
  # ---------------------------------------------------------------------

  def test_default_gemfile_locatable_returns_false_when_bundler_raises
    skip "Bundler not loaded in this environment" unless defined?(::Bundler)

    ::Bundler.stub(:default_gemfile, ->(*) { raise "no gemfile" }) do
      refute ProjectInfo.default_gemfile_locatable?
    end
  end

  def test_default_gemfile_locatable_returns_true_when_bundler_resolves
    skip "Bundler not loaded in this environment" unless defined?(::Bundler)

    ::Bundler.stub(:default_gemfile, Pathname.new("/tmp/Gemfile")) do
      assert ProjectInfo.default_gemfile_locatable?
    end
  end

  def test_default_gemfile_locatable_returns_false_when_bundler_returns_nil
    skip "Bundler not loaded in this environment" unless defined?(::Bundler)

    ::Bundler.stub(:default_gemfile, nil) do
      refute ProjectInfo.default_gemfile_locatable?
    end
  end

  # ---------------------------------------------------------------------
  # bundler_loaded? reflects the real environment.
  # ---------------------------------------------------------------------

  def test_bundler_loaded_matches_defined_bundler
    expected = defined?(::Bundler) ? true : false

    assert_equal expected, ProjectInfo.bundler_loaded?
  end
end
