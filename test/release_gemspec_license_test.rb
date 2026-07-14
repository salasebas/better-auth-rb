# frozen_string_literal: true

require "minitest/autorun"
require "rubygems"
require "yaml"

class ReleaseGemspecLicenseTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  ROOT_LICENSE = File.join(ROOT, "LICENSE.md")

  def test_every_mit_release_gem_includes_the_root_license
    assert_equal 20, release_gemspec_paths.length
    assert_includes release_gemspec_paths, "packages/better_auth-rails/better_auth-rails.gemspec"
    refute_includes release_gemspec_paths, "packages/better_auth-rails/better_auth_rails.gemspec"
    assert_empty release_gemspec_paths.grep(%r{\Apackages/openauth})

    release_gemspec_paths.each do |path|
      specification = load_gemspec(path)

      assert specification, "#{path} must load as a gem specification"
      next unless specification.licenses.include?("MIT")

      package_license = File.join(ROOT, File.dirname(path), "LICENSE.md")
      assert_path_exists package_license
      assert_equal File.read(ROOT_LICENSE), File.read(package_license), "#{package_license} must match the root license"
      assert_equal 1, specification.files.count("LICENSE.md"), "#{path} must package one relative LICENSE.md"
    end
  end

  private

  def release_gemspec_paths
    @release_gemspec_paths ||= begin
      manifest = YAML.safe_load_file(File.join(ROOT, ".release.yml"))
      packages = manifest.fetch("version_files").map { |path| path.split("/")[1] }.uniq

      (
        packages.flat_map { |package| Dir[File.join(ROOT, "packages", package, "*.gemspec")] } +
          manifest.fetch("literal_gemspec_versions").map { |path| File.join(ROOT, path) }
      ).uniq.sort.map { |path| path.delete_prefix("#{ROOT}/") }
    end
  end

  def load_gemspec(path)
    full_path = File.join(ROOT, path)
    Dir.chdir(File.dirname(full_path)) do
      Gem::Specification.load(full_path)
    end
  end
end
