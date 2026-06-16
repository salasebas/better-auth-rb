# frozen_string_literal: true

require_relative "../support/cli_test_case"

class CliFrameworkDetectParityTest < BetterAuthCLITestCase
  def test_detects_hanami_from_better_auth_hanami_gem
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "better_auth-hanami"')
      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "hanami", result[:framework]
    end
  end

  def test_detects_sinatra_from_better_auth_sinatra_gem
    Dir.mktmpdir("better-auth-framework-detect") do |dir|
      write_gemfile(dir, 'gem "better_auth-sinatra"')
      result = BetterAuth::CLI::FrameworkDetect.detect(dir)
      assert_equal "sinatra", result[:framework]
    end
  end

  def test_supported_frameworks_list_includes_rack
    assert_includes BetterAuth::CLI::FrameworkDetect::SUPPORTED, "rack"
  end

  private

  def write_gemfile(dir, *lines)
    File.write(File.join(dir, "Gemfile"), lines.join("\n") + "\n")
  end
end
