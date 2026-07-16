# frozen_string_literal: true

require "json"
require_relative "../test_helper"

class BetterAuthEndpointInventoryContractTest < Minitest::Test
  INVENTORY_PATH = File.expand_path("../../../../reference/endpoints-inventory.json", __dir__)

  def test_generated_inventory_has_no_duplicate_camel_case_and_snake_case_body_fields
    skip "Run `ruby scripts/generate-endpoint-inventory.rb` to generate #{INVENTORY_PATH}" unless File.exist?(INVENTORY_PATH)

    routes = JSON.parse(File.read(INVENTORY_PATH)).fetch("routes")
    bad = routes.select do |route|
      next false if route["path"].to_s.start_with?("/sso/saml2/")

      names = (route["body_fields"] || []).map { |field| field["name"] }
      names.any? { |name| name.include?("_") && names.include?(name.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }) }
    end

    assert_empty bad.map { |route| "#{route["method"]} #{route["path"]}" }
  end

  def test_oauth_popup_inventory_records_hidden_query_contract
    skip "Run `ruby scripts/generate-endpoint-inventory.rb` to generate #{INVENTORY_PATH}" unless File.exist?(INVENTORY_PATH)

    routes = JSON.parse(File.read(INVENTORY_PATH)).fetch("routes")
    popup = routes.find { |route| route["method"] == "GET" && route["path"] == "/oauth-popup/start" }

    assert_equal true, popup.fetch("hidden")
    assert_equal(
      %w[additionalData callbackURL errorCallbackURL newUserCallbackURL popupNonce popupOrigin provider requestSignUp scopes],
      popup.fetch("query_params").map { |parameter| parameter.fetch("name") }.sort
    )
    assert_equal(
      %w[popupOrigin provider],
      popup.fetch("query_params").select { |parameter| parameter.fetch("required") }.map { |parameter| parameter.fetch("name") }.sort
    )
    assert popup.fetch("query_params").all? { |parameter| parameter.fetch("type") == "string" }
  end
end
