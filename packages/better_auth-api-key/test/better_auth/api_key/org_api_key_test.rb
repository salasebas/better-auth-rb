# frozen_string_literal: true

require "securerandom"

require_relative "test_support"

class BetterAuthAPIKeyOrgAPIKeyTest < Minitest::Test
  include APIKeyTestSupport

  def test_org_owned_key_requires_organization_plugin
    auth = build_api_key_auth([{config_id: "org-keys", references: "organization", default_key_length: 12}])
    cookie = sign_up_cookie(auth, email: "org-missing-plugin-key@example.com")

    error = assert_raises(BetterAuth::APIError) do
      auth.api.create_api_key(headers: {"cookie" => cookie}, body: {configId: "org-keys", organizationId: "org-id"})
    end

    assert_equal "INTERNAL_SERVER_ERROR", error.status
    assert_equal "ORGANIZATION_PLUGIN_REQUIRED", error.code
  end

  def test_organization_owner_has_full_crud_access
    auth = build_user_and_org_key_auth
    owner_cookie = sign_up_cookie(auth, email: "org-route-owner-key@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Owner API Org", slug: unique_slug("owner-api-org")})

    created = auth.api.create_api_key(headers: {"cookie" => owner_cookie}, body: {configId: "org-keys", organizationId: organization.fetch("id"), name: "owner-key"})
    fetched = auth.api.get_api_key(headers: {"cookie" => owner_cookie}, query: {id: created[:id], configId: "org-keys"})
    updated = auth.api.update_api_key(headers: {"cookie" => owner_cookie}, body: {keyId: created[:id], configId: "org-keys", name: "owner-updated"})
    deleted = auth.api.delete_api_key(headers: {"cookie" => owner_cookie}, body: {keyId: created[:id], configId: "org-keys"})

    assert_equal organization.fetch("id"), created[:referenceId]
    assert_equal created[:id], fetched[:id]
    assert_equal "owner-updated", updated[:name]
    assert_equal({success: true}, deleted)
  end

  def test_user_and_org_keys_are_listed_separately
    auth = build_user_and_org_key_auth
    cookie = sign_up_cookie(auth, email: "org-route-separate-key@example.com")
    user_id = auth.api.get_session(headers: {"cookie" => cookie})[:user]["id"]
    organization = auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Separate API Org", slug: unique_slug("separate-api-org")})
    user_key = auth.api.create_api_key(body: {configId: "user-keys", userId: user_id})
    org_key = auth.api.create_api_key(headers: {"cookie" => cookie}, body: {configId: "org-keys", organizationId: organization.fetch("id")})

    user_list = auth.api.list_api_keys(headers: {"cookie" => cookie})
    org_list = auth.api.list_api_keys(headers: {"cookie" => cookie}, query: {organizationId: organization.fetch("id")})

    assert_includes user_list[:apiKeys].map { |key| key[:id] }, user_key[:id]
    refute_includes user_list[:apiKeys].map { |key| key[:id] }, org_key[:id]
    assert_includes org_list[:apiKeys].map { |key| key[:id] }, org_key[:id]
    refute_includes org_list[:apiKeys].map { |key| key[:id] }, user_key[:id]
  end

  def test_read_only_member_can_read_but_not_create_update_or_delete
    auth = build_custom_org_api_key_auth
    owner_cookie = sign_up_cookie(auth, email: "org-route-read-owner-key@example.com")
    member_cookie = sign_up_cookie(auth, email: "org-route-read-member-key@example.com")
    member_id = auth.api.get_session(headers: {"cookie" => member_cookie})[:user]["id"]
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Read Only API Org", slug: unique_slug("read-only-api-org")})
    org_id = organization.fetch("id")
    org_key = auth.api.create_api_key(headers: {"cookie" => owner_cookie}, body: {configId: "org-keys", organizationId: org_id})
    auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: org_id, userId: member_id, role: "member"})

    listed = auth.api.list_api_keys(headers: {"cookie" => member_cookie}, query: {organizationId: org_id})
    fetched = auth.api.get_api_key(headers: {"cookie" => member_cookie}, query: {id: org_key[:id], configId: "org-keys"})

    assert_includes listed[:apiKeys].map { |key| key[:id] }, org_key[:id]
    assert_equal org_key[:id], fetched[:id]
    create_error = assert_raises(BetterAuth::APIError) do
      auth.api.create_api_key(headers: {"cookie" => member_cookie}, body: {configId: "org-keys", organizationId: org_id})
    end
    update_error = assert_raises(BetterAuth::APIError) do
      auth.api.update_api_key(headers: {"cookie" => member_cookie}, body: {keyId: org_key[:id], configId: "org-keys", name: "blocked"})
    end
    delete_error = assert_raises(BetterAuth::APIError) do
      auth.api.delete_api_key(headers: {"cookie" => member_cookie}, body: {keyId: org_key[:id], configId: "org-keys"})
    end

    [create_error, update_error, delete_error].each do |error|
      assert_equal "FORBIDDEN", error.status
      assert_equal "INSUFFICIENT_API_KEY_PERMISSIONS", error.code
    end
  end

  private

  def build_user_and_org_key_auth
    BetterAuth.auth(
      secret: APIKeyTestSupport::SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.organization,
        BetterAuth::Plugins.api_key([
          {config_id: "user-keys", default_prefix: "usr_", references: "user", default_key_length: 12},
          {config_id: "org-keys", default_prefix: "org_", references: "organization", default_key_length: 12}
        ])
      ]
    )
  end

  def build_custom_org_api_key_auth
    ac = BetterAuth::Plugins.create_access_control(
      organization: ["update", "delete"],
      member: ["create", "update", "delete"],
      invitation: ["create", "cancel"],
      team: ["create", "update", "delete"],
      ac: ["create", "read", "update", "delete"],
      apiKey: ["create", "read", "update", "delete"]
    )
    BetterAuth.auth(
      secret: APIKeyTestSupport::SECRET,
      email_and_password: {enabled: true},
      plugins: [
        BetterAuth::Plugins.organization(
          ac: ac,
          roles: {
            owner: ac.new_role(member: ["create", "update", "delete"], apiKey: ["create", "read", "update", "delete"]),
            member: ac.new_role(apiKey: ["read"])
          }
        ),
        BetterAuth::Plugins.api_key([{config_id: "org-keys", references: "organization", default_key_length: 12}])
      ]
    )
  end

  def unique_slug(prefix)
    "#{prefix}-#{SecureRandom.hex(4)}"
  end
end
