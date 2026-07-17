# frozen_string_literal: true

require "minitest/autorun"

class ReleaseAutomationTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  PREEXISTING_GEM_HELPER_PACKAGES = %w[
    better_auth-grape
    better_auth-hanami
    better_auth-rails
    better_auth-roda
    better_auth-sinatra
  ].freeze

  def test_release_scripts_are_limited_to_the_publisher
    expected = %w[publish_gems.rb]
    actual = Dir[File.join(ROOT, "scripts/release/*")]
      .select { |path| File.file?(path) }
      .map { |path| File.basename(path) }
      .sort

    assert_equal expected, actual
  end

  def test_package_rakefiles_do_not_recreate_release_please_tags
    rakefiles = Dir[File.join(ROOT, "packages", "better_auth*", "Rakefile")]
    assert_equal 19, rakefiles.size

    rakefiles.each do |path|
      package = File.basename(File.dirname(path))
      contents = File.read(path)

      refute_includes contents, "Bundler::GemHelper.tag_prefix", package
      if PREEXISTING_GEM_HELPER_PACKAGES.include?(package)
        assert_equal 1, contents.scan("Bundler::GemHelper.install_tasks").size, package
      else
        refute_includes contents, "Bundler::GemHelper.install_tasks", package
      end
    end

    %w[better_auth better_auth-cli].each do |package|
      contents = File.read(File.join(ROOT, "packages", package, "Rakefile"))
      assert_includes contents, 'require "bundler/gem_tasks"'
    end
  end
end
