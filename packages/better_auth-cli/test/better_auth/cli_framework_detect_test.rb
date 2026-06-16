# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "better_auth/cli/framework_detect"

class BetterAuthCLIFrameworkDetectTest < Minitest::Test
  def test_returns_empty_when_no_signals
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_nil result[:framework]
      assert_empty result[:ambiguous]
    end
  end

  def test_detects_rails_from_application_rb
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "Rails.application")

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "rails", result[:framework]
    end
  end

  def test_detects_rails_from_gemfile
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "rails"')

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "rails", result[:framework]
    end
  end

  def test_detects_rails_from_better_auth_rails_gem
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "better_auth-rails"')

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "rails", result[:framework]
    end
  end

  def test_detects_hanami_from_gemfile
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "hanami"')

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "hanami", result[:framework]
    end
  end

  def test_detects_hanami_from_structure
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      FileUtils.mkdir_p(File.join(dir, "apps"))
      File.write(File.join(dir, "config", "app.rb"), "Hanami.app")

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "hanami", result[:framework]
    end
  end

  def test_detects_sinatra_from_gemfile
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "sinatra"')

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "sinatra", result[:framework]
    end
  end

  def test_detects_roda_from_gemfile
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "roda"')

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "roda", result[:framework]
    end
  end

  def test_prefers_roda_over_sinatra_when_both_gems_present
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "sinatra"', 'gem "roda"')

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "roda", result[:framework]
    end
  end

  def test_reports_ambiguous_rails_and_sinatra
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      FileUtils.mkdir_p(File.join(dir, "config"))
      File.write(File.join(dir, "config", "application.rb"), "Rails.application")
      write_gemfile(dir, 'gem "sinatra"')

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_nil result[:framework]
      assert_equal %w[rails sinatra], result[:ambiguous]
    end
  end

  def test_does_not_detect_rack
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "rack"')

      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_nil result[:framework]
    end
  end

  def test_gem_in_gemfile_matches_single_and_double_quotes
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, "gem 'roda'")

      assert BetterAuth::CLI::FrameworkDetect.gem_in_gemfile?(dir, "roda")
    end
  end

  private

  def write_gemfile(dir, *lines)
    File.write(File.join(dir, "Gemfile"), lines.join("\n") + "\n")
  end
end
