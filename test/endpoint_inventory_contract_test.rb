# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/support/endpoint_inventory"

class BetterAuthEndpointInventoryContractTest < Minitest::Test
  def test_generated_inventory_has_no_duplicate_camel_case_and_snake_case_body_fields
    routes = EndpointInventory.routes
    bad = routes.select do |route|
      next false if route["path"].to_s.start_with?("/sso/saml2/")

      names = (route["body_fields"] || []).map { |field| field["name"] }
      names.any? { |name| name.include?("_") && names.include?(name.gsub(/_([a-z])/) { Regexp.last_match(1).upcase }) }
    end

    assert_empty bad.map { |route| "#{route["method"]} #{route["path"]}" }
  end

  def test_oauth_popup_inventory_records_hidden_query_contract
    routes = EndpointInventory.routes
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

  def test_admin_get_user_inventory_records_only_the_canonical_id_selector
    routes = EndpointInventory.routes
    get_user = routes.find { |route| route["method"] == "GET" && route["path"] == "/admin/get-user" }

    assert_equal(
      [{"name" => "id", "required" => false, "type" => "string"}],
      get_user.fetch("query_params")
    )
  end
end
