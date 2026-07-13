# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthPluginsOrganizationOrgCrudTest < Minitest::Test
  include BetterAuthTestHelpers

  def test_create_organization_rejects_empty_name_and_slug
    auth = build_organization_auth
    cookie = sign_up_cookie(auth, email: "empty-fields@example.com")

    empty_name = assert_raises(BetterAuth::APIError) do
      auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "", slug: "valid-slug"})
    end
    assert_equal 400, empty_name.status_code
    assert_equal "name is required", empty_name.message

    empty_slug = assert_raises(BetterAuth::APIError) do
      auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Valid Name", slug: ""})
    end
    assert_equal 400, empty_slug.status_code
    assert_equal "slug is required", empty_slug.message
  end

  def test_create_organization_rejects_duplicate_slug
    auth = build_organization_auth
    cookie = sign_up_cookie(auth, email: "duplicate-slug@example.com")
    auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "First Org", slug: "duplicate-slug"})

    duplicate = assert_raises(BetterAuth::APIError) do
      auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Second Org", slug: "duplicate-slug"})
    end
    assert_equal 409, duplicate.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_ALREADY_EXISTS"), duplicate.message
  end

  def test_create_organization_respects_allow_user_to_create_organization
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(allow_user_to_create_organization: false)])
    cookie = sign_up_cookie(auth, email: "blocked-create@example.com")

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Blocked", slug: "blocked"})
    end
    assert_equal 403, blocked.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_CREATE_A_NEW_ORGANIZATION"), blocked.message
  end

  def test_create_organization_respects_allow_user_to_create_organization_callable
    auth = build_organization_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          allow_user_to_create_organization: lambda { |user|
            user.fetch("email") == "allowed-create@example.com"
          }
        )
      ]
    )
    allowed_cookie = sign_up_cookie(auth, email: "allowed-create@example.com")
    blocked_cookie = sign_up_cookie(auth, email: "callable-blocked@example.com")

    created = auth.api.create_organization(headers: {"cookie" => allowed_cookie}, body: {name: "Allowed", slug: "allowed"})
    assert_equal "allowed", created.fetch("slug")

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.create_organization(headers: {"cookie" => blocked_cookie}, body: {name: "Blocked", slug: "callable-blocked"})
    end
    assert_equal 403, blocked.status_code
  end

  def test_create_organization_respects_organization_limit
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(organization_limit: 1)])
    cookie = sign_up_cookie(auth, email: "org-limit@example.com")

    auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "First", slug: "org-limit-first"})

    limited = assert_raises(BetterAuth::APIError) do
      auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Second", slug: "org-limit-second"})
    end
    assert_equal 403, limited.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("YOU_HAVE_REACHED_THE_MAXIMUM_NUMBER_OF_ORGANIZATIONS"), limited.message
  end

  def test_create_organization_respects_organization_limit_callable
    checks = []
    auth = build_organization_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          organization_limit: lambda { |user|
            checks << user.fetch("id")
            checks.count(user.fetch("id")) > 1
          }
        )
      ]
    )
    cookie = sign_up_cookie(auth, email: "callable-limit@example.com")

    auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "First", slug: "callable-limit-first"})

    limited = assert_raises(BetterAuth::APIError) do
      auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Second", slug: "callable-limit-second"})
    end
    assert_equal 403, limited.status_code
  end

  def test_update_organization_by_slug_rejects_empty_and_duplicate_values
    auth = build_organization_auth
    cookie = sign_up_cookie(auth, email: "update-slug@example.com")
    first = auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "First Org", slug: "update-first"})
    second = auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Second Org", slug: "update-second"})

    empty_slug = assert_raises(BetterAuth::APIError) do
      auth.api.update_organization(headers: {"cookie" => cookie}, body: {organizationSlug: "update-first", data: {slug: ""}})
    end
    assert_equal 400, empty_slug.status_code
    assert_equal "slug is required", empty_slug.message

    duplicate = assert_raises(BetterAuth::APIError) do
      auth.api.update_organization(headers: {"cookie" => cookie}, body: {organizationId: first.fetch("id"), data: {slug: "update-second"}})
    end
    assert_equal 409, duplicate.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_SLUG_ALREADY_TAKEN"), duplicate.message

    updated = auth.api.update_organization(
      headers: {"cookie" => cookie},
      body: {organizationSlug: "update-first", data: {name: "Renamed First", metadata: {tier: "pro"}}}
    )
    assert_equal "Renamed First", updated.fetch("name")
    assert_equal({"tier" => "pro"}, updated.fetch("metadata"))
    refute_equal second.fetch("id"), updated.fetch("id")
  end

  def test_update_organization_hooks_can_mutate_data_and_receive_member
    calls = []
    auth = build_organization_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          organization_hooks: {
            before_update_organization: lambda { |data, _ctx|
              calls << [:before, data[:organization][:name], data[:member].fetch("role")]
              {data: {name: "Hook Renamed"}}
            },
            after_update_organization: lambda { |data, _ctx|
              calls << [:after, data[:organization].fetch("name"), data[:member].fetch("role"), data[:user].fetch("email")]
            }
          }
        )
      ]
    )
    cookie = sign_up_cookie(auth, email: "update-hooks@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Update Hooks", slug: "update-hooks"})

    updated = auth.api.update_organization(
      headers: {"cookie" => cookie},
      body: {organizationId: organization.fetch("id"), data: {name: "Requested Name"}}
    )

    assert_equal "Hook Renamed", updated.fetch("name")
    assert_equal [
      [:before, "Requested Name", "owner"],
      [:after, "Hook Renamed", "owner", "update-hooks@example.com"]
    ], calls
  end

  def test_set_active_organization_by_slug
    auth = build_organization_auth
    cookie = sign_up_cookie(auth, email: "active-slug@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Slug Active", slug: "slug-active"})

    active = auth.api.set_active_organization(
      headers: {"cookie" => cookie},
      body: {organizationSlug: organization.fetch("slug")},
      return_headers: true
    )
    active_cookie = [cookie, cookie_header(active.fetch(:headers).fetch("set-cookie"))].join("; ")
    session = auth.api.get_session(headers: {"cookie" => active_cookie})

    assert_equal organization.fetch("id"), active.fetch(:response).fetch("id")
    assert_equal organization.fetch("id"), session.fetch(:session).fetch("activeOrganizationId")
  end

  def test_get_full_organization_uses_active_org_and_includes_invitations_and_teams
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: true})])
    cookie = sign_up_cookie(auth, email: "full-active@example.com")
    created = auth.api.create_organization(
      headers: {"cookie" => cookie},
      body: {name: "Full Active", slug: "full-active", logo: "https://cdn.example/logo.png"},
      return_headers: true
    )
    active_cookie = [cookie, cookie_header(created.fetch(:headers).fetch("set-cookie"))].join("; ")
    organization_id = created.fetch(:response).fetch("id")

    invitation = auth.api.create_invitation(
      headers: {"cookie" => active_cookie},
      body: {email: "pending-invite@example.com", role: "member"}
    )
    team = auth.api.create_team(headers: {"cookie" => active_cookie}, body: {name: "Platform"})

    full = auth.api.get_full_organization(headers: {"cookie" => active_cookie})
    assert_equal organization_id, full.fetch("id")
    assert_equal "https://cdn.example/logo.png", full.fetch("logo")
    assert_equal 1, full.fetch(:members).length
    assert_equal [invitation.fetch("id")], full.fetch(:invitations).map { |entry| entry.fetch("id") }
    assert_includes full.fetch(:teams).map { |entry| entry.fetch("id") }, team.fetch("id")
  end

  def test_delete_organization_removes_related_records
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: true})])
    cookie = sign_up_cookie(auth, email: "delete-cleanup@example.com")
    created = auth.api.create_organization(
      headers: {"cookie" => cookie},
      body: {name: "Delete Cleanup", slug: "delete-cleanup"},
      return_headers: true
    )
    active_cookie = [cookie, cookie_header(created.fetch(:headers).fetch("set-cookie"))].join("; ")
    organization_id = created.fetch(:response).fetch("id")

    auth.api.create_invitation(headers: {"cookie" => active_cookie}, body: {email: "delete-invite@example.com", role: "member"})
    team = auth.api.create_team(headers: {"cookie" => active_cookie}, body: {name: "Cleanup Team"})
    auth.api.create_org_role(headers: {"cookie" => active_cookie}, body: {role: "cleanup", permission: {organization: ["update"]}})

    auth.api.delete_organization(headers: {"cookie" => active_cookie}, body: {organizationId: organization_id})

    assert_nil auth.context.adapter.find_one(model: "organization", where: [{field: "id", value: organization_id}])
    assert_empty auth.context.adapter.find_many(model: "member", where: [{field: "organizationId", value: organization_id}])
    assert_empty auth.context.adapter.find_many(model: "invitation", where: [{field: "organizationId", value: organization_id}])
    assert_empty auth.context.adapter.find_many(model: "team", where: [{field: "organizationId", value: organization_id}])
    assert_empty auth.context.adapter.find_many(model: "organizationRole", where: [{field: "organizationId", value: organization_id}])
    assert_empty auth.context.adapter.find_many(model: "teamMember", where: [{field: "teamId", value: team.fetch("id")}])
    assert_empty auth.api.list_organizations(headers: {"cookie" => active_cookie})
  end

  def test_delete_organization_can_be_disabled_and_leaves_records_intact
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(disable_organization_deletion: true)])
    cookie = sign_up_cookie(auth, email: "delete-disabled@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Delete Disabled", slug: "delete-disabled"})

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.delete_organization(headers: {"cookie" => cookie}, body: {organizationId: organization.fetch("id")})
    end

    assert_equal 404, blocked.status_code
    assert_equal "Organization deletion is disabled", blocked.message
    assert_equal "ORGANIZATION_DELETION_DISABLED", blocked.code
    assert auth.context.adapter.find_one(model: "organization", where: [{field: "id", value: organization.fetch("id")}])
    assert auth.context.adapter.find_one(model: "member", where: [{field: "organizationId", value: organization.fetch("id")}])
  end

  def test_delete_active_organization_clears_active_org_and_team
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true})])
    cookie = sign_up_cookie(auth, email: "delete-active@example.com")
    created = auth.api.create_organization(
      headers: {"cookie" => cookie},
      body: {name: "Delete Active", slug: "delete-active"},
      return_headers: true
    )
    active_cookie = [cookie, cookie_header(created.fetch(:headers).fetch("set-cookie"))].join("; ")
    session = auth.api.get_session(headers: {"cookie" => active_cookie})
    assert_equal created.fetch(:response).fetch("id"), session.fetch(:session).fetch("activeOrganizationId")
    refute_nil session.fetch(:session).fetch("activeTeamId")

    deleted = auth.api.delete_organization(
      headers: {"cookie" => active_cookie},
      body: {organizationId: created.fetch(:response).fetch("id")},
      return_headers: true
    )
    cleared_cookie = [active_cookie, cookie_header(deleted.fetch(:headers).fetch("set-cookie"))].join("; ")
    cleared = auth.api.get_session(headers: {"cookie" => cleared_cookie})

    assert_equal({status: true}, deleted.fetch(:response))
    assert_nil cleared.fetch(:session)["activeOrganizationId"]
    assert_nil cleared.fetch(:session)["activeTeamId"]
  end

  def test_delete_organization_hooks_fire_in_order
    calls = []
    auth = build_organization_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          organization_hooks: {
            before_delete_organization: ->(data, _ctx) { calls << [:before, data[:organization].fetch("slug"), data[:user].fetch("email")] },
            after_delete_organization: lambda { |data, ctx|
              persisted = ctx.context.adapter.find_one(model: "organization", where: [{field: "id", value: data[:organization].fetch("id")}])
              calls << [:after, data[:organization].fetch("slug"), persisted.nil?]
            }
          }
        )
      ]
    )
    cookie = sign_up_cookie(auth, email: "delete-hooks@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => cookie}, body: {name: "Delete Hooks", slug: "delete-hooks"})

    auth.api.delete_organization(headers: {"cookie" => cookie}, body: {organizationId: organization.fetch("id")})

    assert_equal [
      [:before, "delete-hooks", "delete-hooks@example.com"],
      [:after, "delete-hooks", true]
    ], calls
  end

  def test_create_organization_creates_default_team_when_enabled
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true})])
    cookie = sign_up_cookie(auth, email: "default-team@example.com")
    created = auth.api.create_organization(
      headers: {"cookie" => cookie},
      body: {name: "Default Team Org", slug: "default-team-org"},
      return_headers: true
    )
    active_cookie = [cookie, cookie_header(created.fetch(:headers).fetch("set-cookie"))].join("; ")
    organization_id = created.fetch(:response).fetch("id")

    teams = auth.api.list_organization_teams(headers: {"cookie" => active_cookie}, query: {organizationId: organization_id})
    assert_equal 1, teams.length
    assert_equal "Default Team Org", teams.first.fetch("name")

    session = auth.api.get_session(headers: {"cookie" => active_cookie})
    assert_equal teams.first.fetch("id"), session.fetch(:session).fetch("activeTeamId")
  end

  private

  def build_organization_auth(options = {})
    build_auth({
      plugins: [BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: true})]
    }.merge(options))
  end
end
