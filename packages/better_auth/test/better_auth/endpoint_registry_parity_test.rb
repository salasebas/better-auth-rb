# frozen_string_literal: true

require "json"
require_relative "../test_helper"

INVENTORY_AUTH_PATH = File.expand_path("../../../../scripts/support/inventory_auth.rb", __dir__)
INVENTORY_AUTH_AVAILABLE = File.exist?(INVENTORY_AUTH_PATH)

if INVENTORY_AUTH_AVAILABLE
  begin
    require_relative "../../../../scripts/support/inventory_auth"
    require_relative "../../../../scripts/support/endpoint_naming"
    InventoryAuth.require_plugin_gems!
  rescue LoadError
    INVENTORY_AUTH_AVAILABLE = false
  end
end

class BetterAuthEndpointRegistryParityTest < Minitest::Test
  REGISTRY_PATH = File.expand_path("../../../../reference/upstream-endpoint-registry.json", __dir__)
  SKIP_PLUGINS = %w[mcp electron oidc-provider].freeze
  KNOWN_GAPS = [].freeze
  PASSKEY_METHOD_OVERRIDES = {
    "GET /passkey/generate-authenticate-options" => "POST",
    "GET /passkey/generate-register-options" => "POST"
  }.freeze

  def setup
    skip "Run from workspace bundle with plugin gems loaded" unless INVENTORY_AUTH_AVAILABLE
    skip "Run `ruby scripts/generate-upstream-endpoint-registry.rb` first" unless File.exist?(REGISTRY_PATH)

    @registry = JSON.parse(File.read(REGISTRY_PATH)).fetch("entries")
    @auth = InventoryAuth.build_inventory_auth
    @endpoints = @auth.api.endpoints
    @inventory_index = inventory_index
    @inventory_by_path = inventory_by_path
  end

  def test_email_otp_password_reset_mapping
    entry = find_entry("/email-otp/request-password-reset", "POST")
    assert_equal "request_password_reset_email_otp", entry.fetch("ruby_registry_key")
    assert_registry_entry_present(entry)
  end

  def test_oauth_create_client_mapping
    entry = find_entry("/oauth2/create-client", "POST")
    assert_equal "create_oauth_client", entry.fetch("ruby_registry_key")
    assert_registry_entry_present(entry)
  end

  def test_scim_list_users_mapping
    entry = find_entry("/scim/v2/Users", "GET")
    skip "SCIM list users not in upstream registry scan" unless entry

    assert_equal "list_scim_users", entry.fetch("ruby_registry_key")
    assert_registry_entry_present(entry)
  end

  def test_sso_register_provider_mapping
    entry = @registry.find { |row| row["registry_key"] == "registerSSOProvider" }
    skip "SSO register provider not in upstream registry scan" unless entry

    assert_equal "register_sso_provider", entry.fetch("ruby_registry_key")
    assert_registry_entry_present(entry)
  end

  def test_passkey_registration_options_mapping
    entry = find_entry("/passkey/generate-register-options", "GET")

    refute_nil entry
    assert_registry_entry_present(entry)
    assert_respond_to @auth.api, entry.fetch("ruby_registry_key").to_sym
  end

  def test_api_key_create_mapping
    entry = find_entry("/api-key/create", "POST")

    refute_nil entry
    assert_equal "create_api_key", entry.fetch("ruby_registry_key")
    assert_registry_entry_present(entry)
  end

  def test_non_deprecated_registry_entries_with_loaded_plugins_align
    mismatches = supported_entries.filter_map do |entry|
      next if entry["deprecated"]

      inventory = find_inventory_row(entry)
      next "#{entry["method"]} #{entry["path"]}: missing inventory row" unless inventory

      ruby_key = inventory["endpoint_key"]
      next if EndpointNaming.registry_keys_equivalent?(entry["registry_key"], ruby_key)

      "expected #{entry["ruby_registry_key"]}, got #{ruby_key} for #{entry["method"]} #{entry["path"]}"
    end

    assert_empty mismatches.first(20), mismatches.join("\n")
  end

  private

  def supported_entries
    @registry.reject do |entry|
      skip_plugin?(entry["plugin_id"]) || known_gap?(entry) || entry["server_only"]
    end
  end

  def known_gap?(entry)
    KNOWN_GAPS.include?([entry["plugin_id"].to_s, entry["method"].to_s.upcase, entry["path"].to_s])
  end

  def skip_plugin?(plugin_id)
    SKIP_PLUGINS.include?(plugin_id.to_s)
  end

  def find_entry(path, method)
    @registry.find { |row| row["path"] == path && row["method"].to_s.upcase == method.to_s.upcase }
  end

  def inventory_index
    inventory = JSON.parse(File.read(File.expand_path("../../../../reference/endpoints-inventory.json", __dir__)))
    inventory.fetch("routes").each_with_object({}) do |row, index|
      index[[row["path"], row["method"].to_s.upcase]] = row
    end
  end

  def inventory_by_path
    inventory = JSON.parse(File.read(File.expand_path("../../../../reference/endpoints-inventory.json", __dir__)))
    inventory.fetch("routes").group_by { |row| row["path"] }
  end

  def normalized_upstream_method(entry)
    override = PASSKEY_METHOD_OVERRIDES["#{entry["method"].to_s.upcase} #{entry["path"]}"]
    return override if override

    entry["method"].to_s.upcase
  end

  def find_inventory_row(entry)
    method = normalized_upstream_method(entry)
    return @inventory_index[[entry["path"], method]] if method != "*"

    rows = @inventory_by_path[entry["path"]] || []
    rows.find { |row| row["method"].to_s.upcase == "GET" } || rows.first
  end

  def assert_registry_entry_present(entry)
    inventory = find_inventory_row(entry)
    assert inventory, "missing inventory row for #{entry["method"]} #{entry["path"]}"

    ruby_key = entry.fetch("ruby_registry_key")
    assert_equal ruby_key, inventory.fetch("endpoint_key"), "inventory endpoint key mismatch"
    assert @endpoints.key?(ruby_key.to_sym), "auth.api missing #{ruby_key}"
    assert_respond_to @auth.api, ruby_key.to_sym
  end
end
