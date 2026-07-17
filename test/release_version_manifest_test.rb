# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "yaml"

class ReleaseVersionManifestTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_release_manifest_matches_all_gemspec_versions
    manifest = release_manifest
    version = manifest.fetch("version")

    manifest.fetch("version_files").each do |path|
      full_path = File.join(ROOT, path)
      assert_path_exists full_path
      assert_equal version, File.read(full_path)[/VERSION\s*=\s*"([^"]+)"/, 1], "#{path} must match .release.yml"
    end

    package_paths = manifest.fetch("version_files").map { |path| path.split("/").first(2).join("/") }
    gemspecs = Dir[File.join(ROOT, "packages", "better_auth*", "*.gemspec")]
      .map { |path| File.dirname(path).delete_prefix("#{ROOT}/") }
    assert_equal gemspecs.sort, package_paths.sort
    assert_equal 19, package_paths.size
    assert package_paths.all? { |path| File.basename(path).match?(/\Abetter_auth(?:-[a-z0-9-]+)?\z/) }
  end

  def test_release_please_config_and_manifest_cover_exactly_the_release_packages
    config = JSON.parse(File.read(File.join(ROOT, "release-please-config.json")))
    release_please_manifest = JSON.parse(File.read(File.join(ROOT, ".release-please-manifest.json")))
    paths = release_manifest.fetch("version_files").map { |path| path.split("/").first(2).join("/") }

    assert_equal paths.sort, config.fetch("packages").keys.sort
    assert_equal paths.sort, release_please_manifest.keys.sort
    assert_equal [release_manifest.fetch("version")], release_please_manifest.values.uniq
    assert_equal config.fetch("packages").values.map { |package| package.fetch("component") }.sort,
      config.fetch("plugins").first.fetch("components").sort
    refute config.key?("skip-github-release")
    refute config.fetch("separate-pull-requests")
    assert config.fetch("bump-minor-pre-major")
    assert config.fetch("sequential-calls")
    assert_equal "/", config.fetch("tag-separator")
    config.fetch("packages").each_value { |package| refute_empty package.fetch("version-file") }
    assert_equal [
      {"type" => "yaml", "path" => "/.release.yml", "jsonpath" => "$.version"}
    ], config.fetch("packages").fetch("packages/better_auth").fetch("extra-files")
  end

  def test_exact_internal_dependency_versions_use_package_constants
    sso = File.read(File.join(ROOT, "packages/better_auth-sso/better_auth-sso.gemspec"))

    assert_includes sso, 'spec.add_dependency "better_auth-oidc", BetterAuth::SSO::VERSION'
    assert_includes sso, 'spec.add_development_dependency "better_auth-saml", BetterAuth::SSO::VERSION'
  end

  def test_sync_versions_script_is_registered_as_rake_task
    rakefile = File.read(File.join(ROOT, "Rakefile"))

    assert_includes rakefile, "scripts/sync_versions.rb"
    assert_match(/task\s+"release:sync_versions"/, rakefile)
  end

  private

  def release_manifest
    YAML.safe_load_file(File.join(ROOT, ".release.yml"))
  end
end
