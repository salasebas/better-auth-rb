# frozen_string_literal: true

require "minitest/autorun"
require "rubygems"

class RubyAuthAliasPackageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_rubyauth_frozen_version_matches_its_dependency_and_documentation
    package_dir = File.join(ROOT, "packages", "rubyauth")
    gemspec_path = File.join(package_dir, "rubyauth.gemspec")
    readme_path = File.join(package_dir, "README.md")
    require_path = File.join(package_dir, "lib", "rubyauth.rb")

    assert_path_exists gemspec_path
    assert_path_exists readme_path
    assert_path_exists require_path

    spec = Gem::Specification.load(gemspec_path)
    assert_equal "rubyauth", spec.name
    assert_equal "0.10.0", spec.version.to_s
    dependency = spec.runtime_dependencies.find { |candidate| candidate.name == "better_auth" }
    assert dependency
    assert_equal Gem::Requirement.new("= #{spec.version}"), dependency.requirement

    readme = File.read(readme_path)
    assert_includes readme, "https://better-auth-rb.vercel.app/"
    assert_includes readme, 'gem "rubyauth"'
    assert_includes readme, 'require "rubyauth"'
    assert_includes readme, "better_auth"
  end

  def test_rubyauth_exposes_core_constants_directly
    add_package_libs_to_load_path
    require "rubyauth"

    expected_aliases = BetterAuth.constants(false)
    missing_aliases = expected_aliases.reject { |constant_name| RubyAuth.const_defined?(constant_name, false) }

    assert_empty missing_aliases, "RubyAuth is missing direct aliases for: #{missing_aliases.sort.join(", ")}"

    assert_same BetterAuth::Adapters::Memory, RubyAuth::Adapters::Memory
    assert_same BetterAuth::Plugins, RubyAuth::Plugins
  end

  private

  def add_package_libs_to_load_path
    Dir[File.join(ROOT, "packages", "*", "lib")].sort.reverse_each do |path|
      $LOAD_PATH.unshift(path) unless $LOAD_PATH.include?(path)
    end
  end
end
