# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthStripePluginFactoryTest < Minitest::Test
  def test_build_returns_stripe_plugin_with_schema_endpoints_and_error_codes
    plugin = BetterAuth::Stripe::PluginFactory.build(subscription: {enabled: true, plans: []})

    assert_equal "stripe", plugin.id
    assert_equal BetterAuth::Stripe::ERROR_CODES, plugin.error_codes
    assert plugin.schema.key?(:subscription)
    assert plugin.endpoints.key?(:upgrade_subscription)
  end

  def test_visible_endpoints_have_complete_open_api_metadata
    plugin = BetterAuth::Stripe::PluginFactory.build(subscription: {enabled: true, plans: []})
    missing = plugin.endpoints.filter_map do |key, endpoint|
      next unless endpoint.path
      next if endpoint.metadata[:hide] || endpoint.metadata[:SERVER_ONLY] || endpoint.metadata[:server_only]

      "#{plugin.id}.#{key}" unless rich_openapi?(endpoint)
    end

    assert_empty missing
  end

  def test_public_facade_delegates_to_plugin_factory
    plugin = BetterAuth::Plugins.stripe(subscription: {enabled: true, plans: []})

    assert_equal "stripe", plugin.id
    assert plugin.endpoints.key?(:stripe_webhook)
  end

  def test_plugin_version_is_exposed
    plugin = BetterAuth::Stripe::PluginFactory.build

    assert_equal BetterAuth::Stripe::VERSION, plugin.version
  end

  private

  def rich_openapi?(endpoint)
    openapi = endpoint.metadata[:openapi]
    return false unless openapi.is_a?(Hash)
    return false if openapi[:operationId].to_s.empty?
    return false if endpoint.methods.any? { |method| openapi[:description].to_s == "#{method} #{endpoint.path}" }
    return false unless openapi[:responses].is_a?(Hash) && openapi[:responses].any?
    return false if endpoint.methods.any? { |method| %w[POST PUT PATCH].include?(method) } && !meaningful_schema?(openapi.dig(:requestBody, :content, "application/json", :schema))

    true
  end

  def meaningful_schema?(schema)
    schema.is_a?(Hash) && (schema[:additionalProperties] || schema[:$ref] || schema[:items] || schema[:properties]&.any?)
  end
end
