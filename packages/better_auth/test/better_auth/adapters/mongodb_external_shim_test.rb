# frozen_string_literal: true

require_relative "../../test_helper"

class MongoDBExternalShimTest < Minitest::Test
  def test_core_entrypoint_does_not_define_mongodb_adapter
    refute BetterAuth::Adapters.const_defined?(:MongoDB, false)
  end

  def test_mongodb_adapter_shim_has_helpful_error_when_external_package_is_missing
    error = assert_raises(LoadError) do
      load File.expand_path("../../../lib/better_auth/adapters/mongodb.rb", __dir__)
    end

    assert_includes error.message, "better_auth-mongodb"
    assert_includes error.message, "require \"better_auth/mongodb\""
  end
end
