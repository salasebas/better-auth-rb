# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "../test_helper"

class BetterAuthMongoAdapterCompatibilityTest < Minitest::Test
  def test_mongo_adapter_constant_aliases_canonical_mongodb_module
    assert_same BetterAuth::MongoDB, BetterAuth::MongoAdapter
  end

  def test_compatibility_entrypoint_warns_and_aliases_in_fresh_process
    script = <<~RUBY
      require "better_auth/mongo_adapter"
      puts BetterAuth::MongoAdapter.equal?(BetterAuth::MongoDB)
      puts BetterAuth::Adapters::MongoDB.name
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I",
      File.expand_path("../../lib", __dir__),
      "-e",
      script
    )

    assert status.success?, stderr
    assert_includes stderr, "better_auth-mongo-adapter gem is deprecated"
    assert_equal ["true", "BetterAuth::Adapters::MongoDB"], stdout.lines.map(&:strip)
  end

  def test_gemspec_pins_canonical_mongodb_dependency_to_compatibility_version
    package_root = File.expand_path("../..", __dir__)
    spec = Dir.chdir(package_root) do
      Gem::Specification.load(File.join(package_root, "better_auth-mongo-adapter.gemspec"))
    end
    dependency = spec.dependencies.find { |entry| entry.name == "better_auth-mongodb" }

    assert dependency, "expected better_auth-mongodb dependency"
    assert_equal [["=", Gem::Version.new(BetterAuth::MongoDB::VERSION)]], dependency.requirement.requirements
  end
end
