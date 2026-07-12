# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthPluginsOrganizationMembersTest < Minitest::Test
  include BetterAuthTestHelpers

  def test_reject_invitation_marks_rejected_and_excludes_from_user_list
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "reject-owner@example.com")
    invitee_cookie = sign_up_cookie(auth, email: "reject-invitee@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Reject Org", slug: "reject-org"})

    invitation = auth.api.create_invitation(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), email: "reject-invitee@example.com", role: "member"}
    )

    rejected = auth.api.reject_invitation(headers: {"cookie" => invitee_cookie}, body: {invitationId: invitation.fetch("id")})
    assert_equal "rejected", rejected.fetch("status")
    assert_empty auth.api.list_user_invitations(headers: {"cookie" => invitee_cookie})
    assert_equal "rejected", auth.api.get_invitation(query: {invitationId: invitation.fetch("id")}).fetch("status")
  end

  def test_invitation_accept_reject_and_cancel_hooks_fire
    calls = []
    auth = build_organization_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          organization_hooks: {
            before_accept_invitation: ->(data, _ctx) { calls << [:before_accept, data[:invitation].fetch("email"), data[:organization].fetch("slug")] },
            after_accept_invitation: ->(data, _ctx) { calls << [:after_accept, data[:invitation].fetch("status"), data[:member].fetch("role")] },
            before_reject_invitation: ->(data, _ctx) { calls << [:before_reject, data[:invitation].fetch("email"), data[:user].fetch("email")] },
            after_reject_invitation: ->(data, _ctx) { calls << [:after_reject, data[:invitation].fetch("status"), data[:organization].fetch("slug")] },
            before_cancel_invitation: ->(data, _ctx) { calls << [:before_cancel, data[:invitation].fetch("email"), data[:cancelled_by].fetch("email")] },
            after_cancel_invitation: ->(data, _ctx) { calls << [:after_cancel, data[:invitation].fetch("status"), data[:organization].fetch("slug")] }
          }
        )
      ]
    )
    owner_cookie = sign_up_cookie(auth, email: "invitation-hooks-owner@example.com")
    accepted_cookie = sign_up_cookie(auth, email: "invitation-hooks-accepted@example.com")
    rejected_cookie = sign_up_cookie(auth, email: "invitation-hooks-rejected@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Invitation Hooks", slug: "invitation-hooks"})

    accepted_invitation = auth.api.create_invitation(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), email: "invitation-hooks-accepted@example.com", role: "member"})
    rejected_invitation = auth.api.create_invitation(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), email: "invitation-hooks-rejected@example.com", role: "member"})
    canceled_invitation = auth.api.create_invitation(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), email: "invitation-hooks-canceled@example.com", role: "member"})

    auth.api.accept_invitation(headers: {"cookie" => accepted_cookie}, body: {invitationId: accepted_invitation.fetch("id")})
    auth.api.reject_invitation(headers: {"cookie" => rejected_cookie}, body: {invitationId: rejected_invitation.fetch("id")})
    auth.api.cancel_invitation(headers: {"cookie" => owner_cookie}, body: {invitationId: canceled_invitation.fetch("id")})

    assert_equal [
      [:before_accept, "invitation-hooks-accepted@example.com", "invitation-hooks"],
      [:after_accept, "accepted", "member"],
      [:before_reject, "invitation-hooks-rejected@example.com", "invitation-hooks-rejected@example.com"],
      [:after_reject, "rejected", "invitation-hooks"],
      [:before_cancel, "invitation-hooks-canceled@example.com", "invitation-hooks-owner@example.com"],
      [:after_cancel, "canceled", "invitation-hooks"]
    ], calls
  end

  def test_require_email_verification_on_invitation_when_configured
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(require_email_verification_on_invitation: true)])
    owner_cookie = sign_up_cookie(auth, email: "verify-owner@example.com")
    invitee_cookie = sign_up_cookie(auth, email: "verify-invitee@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Verify Org", slug: "verify-org"})

    invitation = auth.api.create_invitation(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), email: "verify-invitee@example.com", role: "member"}
    )

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.accept_invitation(headers: {"cookie" => invitee_cookie}, body: {invitationId: invitation.fetch("id")})
    end
    assert_equal 403, blocked.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("EMAIL_VERIFICATION_REQUIRED_BEFORE_ACCEPTING_OR_REJECTING_INVITATION"), blocked.message
  end

  def test_invite_rejects_existing_member_and_invalid_role
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "invite-guards@example.com")
    member_cookie = sign_up_cookie(auth, email: "invite-guards-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Invite Guards", slug: "invite-guards"})

    auth.api.add_member(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member"}
    )

    existing_member = assert_raises(BetterAuth::APIError) do
      auth.api.create_invitation(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), email: member_user.fetch("email"), role: "member"}
      )
    end
    assert_equal 409, existing_member.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("USER_IS_ALREADY_A_MEMBER_OF_THIS_ORGANIZATION"), existing_member.message

    invalid_role = assert_raises(BetterAuth::APIError) do
      auth.api.create_invitation(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), email: "new-invite@example.com", role: "missing-role"}
      )
    end
    assert_equal 400, invalid_role.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("ROLE_NOT_FOUND"), invalid_role.message
  end

  def test_add_member_rejects_duplicate_member
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "duplicate-member-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "duplicate-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Duplicate Member", slug: "duplicate-member"})

    auth.api.add_member(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member"}
    )

    duplicate = assert_raises(BetterAuth::APIError) do
      auth.api.add_member(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "admin"}
      )
    end
    assert_equal 409, duplicate.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("USER_IS_ALREADY_A_MEMBER_OF_THIS_ORGANIZATION"), duplicate.message
  end

  def test_add_member_rejects_missing_target_user
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "missing-target-owner@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Missing Target", slug: "missing-target"})
    missing_user_id = "missing-user-id"

    missing = assert_raises(BetterAuth::APIError) do
      auth.api.add_member(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), userId: missing_user_id, role: "member"}
      )
    end

    assert_equal 400, missing.status_code
    assert_equal BetterAuth::BASE_ERROR_CODES.fetch("USER_NOT_FOUND"), missing.message
    assert_nil auth.context.adapter.find_one(
      model: "member",
      where: [{field: "userId", value: missing_user_id}, {field: "organizationId", value: organization.fetch("id")}]
    )
  end

  def test_add_member_uses_active_organization_and_requires_one
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "active-add-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "active-add-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    created = auth.api.create_organization(
      headers: {"cookie" => owner_cookie},
      body: {name: "Active Add", slug: "active-add"},
      return_headers: true
    )
    active_cookie = [owner_cookie, cookie_header(created.fetch(:headers).fetch("set-cookie"))].join("; ")

    member = auth.api.add_member(
      headers: {"cookie" => active_cookie},
      body: {userId: member_user.fetch("id"), role: "member"}
    )

    assert_equal created.fetch(:response).fetch("id"), member.fetch("organizationId")
    no_active_cookie = sign_up_cookie(auth, email: "active-add-no-active@example.com")
    no_active = assert_raises(BetterAuth::APIError) do
      auth.api.add_member(
        headers: {"cookie" => no_active_cookie},
        body: {userId: member_user.fetch("id"), role: "member"}
      )
    end
    assert_equal 400, no_active.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION"), no_active.message
  end

  def test_add_member_validates_and_assigns_team
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true, default_team: {enabled: false}})])
    owner_cookie = sign_up_cookie(auth, email: "team-add-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "team-add-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Team Add", slug: "team-add"})
    team = auth.api.create_team(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), name: "Engineering"})

    member = auth.api.add_member(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member", teamId: team.fetch("id")}
    )

    assert_equal member_user.fetch("id"), member.fetch("userId")
    assert auth.context.adapter.find_one(
      model: "teamMember",
      where: [{field: "teamId", value: team.fetch("id")}, {field: "userId", value: member_user.fetch("id")}]
    )
  end

  def test_add_member_with_team_id_enforces_team_member_limit_without_mutation
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true, maximum_members_per_team: 1, default_team: {enabled: false}})])
    owner_cookie = sign_up_cookie(auth, email: "team-capacity-owner@example.com")
    target_cookie = sign_up_cookie(auth, email: "team-capacity-target@example.com")
    target_user = auth.api.get_session(headers: {"cookie" => target_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Team Capacity", slug: "team-capacity"})
    team = auth.api.create_team(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), name: "Full Team"})

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.add_member(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), userId: target_user.fetch("id"), role: "member", teamId: team.fetch("id")}
      )
    end

    assert_equal 403, blocked.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("TEAM_MEMBER_LIMIT_REACHED"), blocked.message
    assert_nil auth.context.adapter.find_one(
      model: "member",
      where: [{field: "organizationId", value: organization.fetch("id")}, {field: "userId", value: target_user.fetch("id")}]
    )
    assert_nil auth.context.adapter.find_one(
      model: "teamMember",
      where: [{field: "teamId", value: team.fetch("id")}, {field: "userId", value: target_user.fetch("id")}]
    )
  end

  def test_add_member_rejects_unknown_team_and_disabled_teams
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true, default_team: {enabled: false}})])
    owner_cookie = sign_up_cookie(auth, email: "team-add-guard-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "team-add-guard-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Team Add Guard", slug: "team-add-guard"})

    missing_team = assert_raises(BetterAuth::APIError) do
      auth.api.add_member(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member", teamId: "missing-team-id"}
      )
    end
    assert_equal 400, missing_team.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND"), missing_team.message

    disabled_auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: false})])
    disabled_owner_cookie = sign_up_cookie(disabled_auth, email: "disabled-team-owner@example.com")
    disabled_member_cookie = sign_up_cookie(disabled_auth, email: "disabled-team-member@example.com")
    disabled_member_user = disabled_auth.api.get_session(headers: {"cookie" => disabled_member_cookie}).fetch(:user)
    disabled_organization = disabled_auth.api.create_organization(headers: {"cookie" => disabled_owner_cookie}, body: {name: "Disabled Team", slug: "disabled-team"})

    disabled = assert_raises(BetterAuth::APIError) do
      disabled_auth.api.add_member(
        headers: {"cookie" => disabled_owner_cookie},
        body: {organizationId: disabled_organization.fetch("id"), userId: disabled_member_user.fetch("id"), role: "member", teamId: "team-id"}
      )
    end
    assert_equal 400, disabled.status_code
    assert_equal "Teams are not enabled", disabled.message
  end

  def test_leave_organization_removes_membership
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true})])
    owner_cookie = sign_up_cookie(auth, email: "leave-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "leave-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Leave Org", slug: "leave-org"})

    auth.api.add_member(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member"}
    )

    left = auth.api.leave_organization(headers: {"cookie" => member_cookie}, body: {organizationId: organization.fetch("id")})
    assert_equal({status: true}, left)
    assert_nil auth.context.adapter.find_one(
      model: "member",
      where: [{field: "userId", value: member_user.fetch("id")}, {field: "organizationId", value: organization.fetch("id")}]
    )
  end

  def test_leave_active_organization_clears_active_org_and_team
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true, default_team: {enabled: false}})])
    owner_cookie = sign_up_cookie(auth, email: "leave-active-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "leave-active-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Leave Active", slug: "leave-active"})
    team = auth.api.create_team(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), name: "Core"})
    auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member", teamId: team.fetch("id")})
    active_org = auth.api.set_active_organization(headers: {"cookie" => member_cookie}, body: {organizationId: organization.fetch("id")}, return_headers: true)
    active_org_cookie = [member_cookie, cookie_header(active_org.fetch(:headers).fetch("set-cookie"))].join("; ")
    active_team = auth.api.set_active_team(headers: {"cookie" => active_org_cookie}, body: {teamId: team.fetch("id")}, return_headers: true)
    active_cookie = [active_org_cookie, cookie_header(active_team.fetch(:headers).fetch("set-cookie"))].join("; ")

    left = auth.api.leave_organization(
      headers: {"cookie" => active_cookie},
      body: {organizationId: organization.fetch("id")},
      return_headers: true
    )
    cleared_cookie = [active_cookie, cookie_header(left.fetch(:headers).fetch("set-cookie"))].join("; ")
    cleared = auth.api.get_session(headers: {"cookie" => cleared_cookie})

    assert_equal({status: true}, left.fetch(:response))
    assert_nil cleared.fetch(:session)["activeOrganizationId"]
    assert_nil cleared.fetch(:session)["activeTeamId"]
  end

  def test_remove_member_hooks_fire_and_before_hook_can_abort
    calls = []
    auth = build_organization_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          organization_hooks: {
            before_remove_member: lambda { |data, _ctx|
              calls << [:before, data[:member].fetch("role"), data[:user].fetch("email")]
              raise BetterAuth::APIError.new("BAD_REQUEST", message: "blocked removal") if data[:user].fetch("email") == "blocked-remove@example.com"
            },
            after_remove_member: ->(data, _ctx) { calls << [:after, data[:member].fetch("role"), data[:organization].fetch("slug")] }
          }
        )
      ]
    )
    owner_cookie = sign_up_cookie(auth, email: "remove-hooks-owner@example.com")
    blocked_cookie = sign_up_cookie(auth, email: "blocked-remove@example.com")
    removed_cookie = sign_up_cookie(auth, email: "removed-member@example.com")
    blocked_user = auth.api.get_session(headers: {"cookie" => blocked_cookie}).fetch(:user)
    removed_user = auth.api.get_session(headers: {"cookie" => removed_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Remove Hooks", slug: "remove-hooks"})
    blocked_member = auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), userId: blocked_user.fetch("id"), role: "member"})
    removed_member = auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), userId: removed_user.fetch("id"), role: "member"})

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.remove_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), memberId: blocked_member.fetch("id")})
    end
    assert_equal "blocked removal", blocked.message
    assert auth.context.adapter.find_one(model: "member", where: [{field: "id", value: blocked_member.fetch("id")}])

    auth.api.remove_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), memberId: removed_member.fetch("id")})

    assert_equal [
      [:before, "member", "blocked-remove@example.com"],
      [:before, "member", "removed-member@example.com"],
      [:after, "member", "remove-hooks"]
    ], calls
  end

  def test_update_member_role_hooks_can_override_role_and_receive_previous_role
    calls = []
    auth = build_organization_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          organization_hooks: {
            before_update_member_role: lambda { |data, _ctx|
              calls << [:before, data[:member].fetch("role"), data[:new_role]]
              {data: {role: "admin"}}
            },
            after_update_member_role: lambda { |data, _ctx|
              calls << [:after, data[:member].fetch("role"), data[:previous_role], data[:organization].fetch("slug")]
            }
          }
        )
      ]
    )
    owner_cookie = sign_up_cookie(auth, email: "role-hooks-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "role-hooks-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Role Hooks", slug: "role-hooks"})
    member = auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member"})

    updated = auth.api.update_member_role(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), memberId: member.fetch("id"), role: "owner"})

    assert_equal "admin", updated.fetch("role")
    assert_equal [
      [:before, "member", "owner"],
      [:after, "admin", "member", "role-hooks"]
    ], calls
  end

  def test_update_member_role_prevents_admin_from_assigning_or_modifying_owner_role
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "role-guard-owner@example.com")
    admin_cookie = sign_up_cookie(auth, email: "role-guard-admin@example.com")
    member_cookie = sign_up_cookie(auth, email: "role-guard-member@example.com")
    admin_user = auth.api.get_session(headers: {"cookie" => admin_cookie}).fetch(:user)
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Role Guards", slug: "role-guards"})
    owner_member = auth.api.get_active_member(headers: {"cookie" => owner_cookie}, query: {organizationId: organization.fetch("id")})
    admin_member = auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), userId: admin_user.fetch("id"), role: "admin"})
    member = auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member"})

    [
      {memberId: admin_member.fetch("id"), role: "owner"},
      {memberId: member.fetch("id"), role: "owner"},
      {memberId: member.fetch("id"), role: "admin, owner"},
      {memberId: owner_member.fetch("id"), role: "member"}
    ].each do |update|
      error = assert_raises(BetterAuth::APIError) do
        auth.api.update_member_role(
          headers: {"cookie" => admin_cookie},
          body: {organizationId: organization.fetch("id")}.merge(update)
        )
      end
      assert_equal 403, error.status_code
      assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_THIS_MEMBER"), error.message
    end

    assert_equal "admin", auth.context.adapter.find_one(model: "member", where: [{field: "id", value: admin_member.fetch("id")}]).fetch("role")
    assert_equal "member", auth.context.adapter.find_one(model: "member", where: [{field: "id", value: member.fetch("id")}]).fetch("role")
    assert_equal "owner", auth.context.adapter.find_one(model: "member", where: [{field: "id", value: owner_member.fetch("id")}]).fetch("role")
  end

  def test_update_member_role_preserves_at_least_one_creator
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "creator-count-owner@example.com")
    second_cookie = sign_up_cookie(auth, email: "creator-count-second@example.com")
    second_user = auth.api.get_session(headers: {"cookie" => second_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Creator Count", slug: "creator-count"})
    owner_member = auth.api.get_active_member(headers: {"cookie" => owner_cookie}, query: {organizationId: organization.fetch("id")})
    second_member = auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), userId: second_user.fetch("id"), role: "member"})

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.update_member_role(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), memberId: owner_member.fetch("id"), role: "admin"}
      )
    end
    assert_equal 400, blocked.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("YOU_CANNOT_LEAVE_THE_ORGANIZATION_WITHOUT_AN_OWNER"), blocked.message

    auth.api.update_member_role(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), memberId: second_member.fetch("id"), role: ["member", "owner"]}
    )
    updated = auth.api.update_member_role(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), memberId: owner_member.fetch("id"), role: "admin"}
    )

    assert_equal "admin", updated.fetch("role")
    assert_equal "member,owner", auth.context.adapter.find_one(model: "member", where: [{field: "id", value: second_member.fetch("id")}]).fetch("role")
  end

  def test_update_member_role_honors_custom_creator_role
    ac = BetterAuth::Plugins.create_access_control(BetterAuth::Plugins::ORGANIZATION_DEFAULT_STATEMENTS)
    auth = build_organization_auth(
      plugins: [
        BetterAuth::Plugins.organization(
          creator_role: "founder",
          ac: ac,
          roles: {
            founder: ac.new_role(member: ["create"]),
            admin: ac.new_role(member: ["create", "update", "delete"]),
            member: ac.new_role(ac: ["read"])
          }
        )
      ]
    )
    founder_cookie = sign_up_cookie(auth, email: "custom-creator-founder@example.com")
    admin_cookie = sign_up_cookie(auth, email: "custom-creator-admin@example.com")
    admin_user = auth.api.get_session(headers: {"cookie" => admin_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => founder_cookie}, body: {name: "Custom Creator", slug: "custom-creator"})
    founder_member = auth.api.get_active_member(headers: {"cookie" => founder_cookie}, query: {organizationId: organization.fetch("id")})
    admin_member = auth.api.add_member(headers: {"cookie" => founder_cookie}, body: {organizationId: organization.fetch("id"), userId: admin_user.fetch("id"), role: "admin"})

    assigning = assert_raises(BetterAuth::APIError) do
      auth.api.update_member_role(headers: {"cookie" => admin_cookie}, body: {organizationId: organization.fetch("id"), memberId: admin_member.fetch("id"), role: "admin, founder"})
    end
    modifying = assert_raises(BetterAuth::APIError) do
      auth.api.update_member_role(headers: {"cookie" => admin_cookie}, body: {organizationId: organization.fetch("id"), memberId: founder_member.fetch("id"), role: "member"})
    end
    demoting = assert_raises(BetterAuth::APIError) do
      auth.api.update_member_role(headers: {"cookie" => founder_cookie}, body: {organizationId: organization.fetch("id"), memberId: founder_member.fetch("id"), role: "member"})
    end

    assert_equal [403, 403, 400], [assigning.status_code, modifying.status_code, demoting.status_code]

    updated = auth.api.update_member_role(
      headers: {"cookie" => founder_cookie},
      body: {organizationId: organization.fetch("id"), memberId: admin_member.fetch("id"), role: "member"}
    )
    assert_equal "member", updated.fetch("role")
  end

  def test_update_member_role_validates_roles_and_accepts_dynamic_roles
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(dynamic_access_control: {enabled: true})])
    owner_cookie = sign_up_cookie(auth, email: "role-validation-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "role-validation-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Role Validation", slug: "role-validation"})
    member = auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member"})

    unknown = assert_raises(BetterAuth::APIError) do
      auth.api.update_member_role(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), memberId: member.fetch("id"), role: "missing-role"})
    end
    empty = assert_raises(BetterAuth::APIError) do
      auth.api.update_member_role(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), memberId: member.fetch("id"), role: [" ", ","]})
    end
    assert_equal 400, unknown.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("ROLE_NOT_FOUND"), unknown.message
    assert_equal 400, empty.status_code

    auth.api.create_org_role(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), role: "auditor", permission: {ac: ["read"]}}
    )
    updated = auth.api.update_member_role(
      headers: {"cookie" => owner_cookie},
      body: {organizationId: organization.fetch("id"), memberId: member.fetch("id"), role: " member, auditor "}
    )
    assert_equal "member,auditor", updated.fetch("role")
  end

  def test_update_member_role_rejects_target_from_another_organization
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "organization-binding-owner@example.com")
    member_cookie = sign_up_cookie(auth, email: "organization-binding-member@example.com")
    member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
    first = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "First Binding", slug: "first-binding"})
    second = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Second Binding", slug: "second-binding"})
    second_member = auth.api.add_member(headers: {"cookie" => owner_cookie}, body: {organizationId: second.fetch("id"), userId: member_user.fetch("id"), role: "member"})

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.update_member_role(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: first.fetch("id"), memberId: second_member.fetch("id"), role: "admin"}
      )
    end

    assert_equal 403, blocked.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_THIS_MEMBER"), blocked.message
    assert_equal "member", auth.context.adapter.find_one(model: "member", where: [{field: "id", value: second_member.fetch("id")}]).fetch("role")
  end

  def test_leave_and_remove_member_reject_last_owner
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "last-owner@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Last Owner", slug: "last-owner"})
    owner_member = auth.api.get_active_member(headers: {"cookie" => owner_cookie}, query: {organizationId: organization.fetch("id")})

    leave_blocked = assert_raises(BetterAuth::APIError) do
      auth.api.leave_organization(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id")})
    end
    assert_equal 400, leave_blocked.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("YOU_CANNOT_LEAVE_THE_ORGANIZATION_AS_THE_ONLY_OWNER"), leave_blocked.message

    remove_blocked = assert_raises(BetterAuth::APIError) do
      auth.api.remove_member(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), memberId: owner_member.fetch("id")}
      )
    end
    assert_equal 400, remove_blocked.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("YOU_CANNOT_LEAVE_THE_ORGANIZATION_AS_THE_ONLY_OWNER"), remove_blocked.message
  end

  def test_list_members_supports_sort_and_filter
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "list-sort-owner@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "List Sort", slug: "list-sort"})

    %w[alpha beta gamma].each do |label|
      member_cookie = sign_up_cookie(auth, email: "#{label}-member@example.com", name: label.capitalize)
      member_user = auth.api.get_session(headers: {"cookie" => member_cookie}).fetch(:user)
      auth.api.add_member(
        headers: {"cookie" => owner_cookie},
        body: {organizationId: organization.fetch("id"), userId: member_user.fetch("id"), role: "member"}
      )
    end

    sorted = auth.api.list_members(
      headers: {"cookie" => owner_cookie},
      query: {organizationId: organization.fetch("id"), sortBy: "createdAt", sortDirection: "asc", limit: 2}
    )
    assert_equal 4, sorted.fetch(:total)
    assert_equal 2, sorted.fetch(:members).length

    filtered = auth.api.list_members(
      headers: {"cookie" => owner_cookie},
      query: {organizationId: organization.fetch("id"), filterField: "role", filterValue: "owner", filterOperator: "eq"}
    )
    assert_equal 1, filtered.fetch(:total)
    assert_equal "owner", filtered.fetch(:members).first.fetch("role")
  end

  def test_get_active_member_returns_current_membership
    auth = build_organization_auth
    owner_cookie = sign_up_cookie(auth, email: "active-member-owner@example.com")
    created = auth.api.create_organization(
      headers: {"cookie" => owner_cookie},
      body: {name: "Active Member", slug: "active-member"},
      return_headers: true
    )
    active_cookie = [owner_cookie, cookie_header(created.fetch(:headers).fetch("set-cookie"))].join("; ")

    member = auth.api.get_active_member(headers: {"cookie" => active_cookie})
    assert_equal "owner", member.fetch("role")
    assert_equal created.fetch(:response).fetch("id"), member.fetch("organizationId")
  end

  def test_teams_disabled_does_not_register_team_endpoints
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: false}, dynamic_access_control: {enabled: true})])

    refute auth.api.respond_to?(:create_team)
    refute auth.api.respond_to?(:list_organization_teams)
    refute auth.api.respond_to?(:set_active_team)
  end

  def test_dynamic_access_control_disabled_does_not_register_role_endpoints
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: false})])

    refute auth.api.respond_to?(:create_org_role)
    refute auth.api.respond_to?(:delete_org_role)
    refute auth.api.respond_to?(:list_org_roles)
  end

  def test_delete_org_role_rejects_predefined_roles
    auth = build_organization_auth(plugins: [BetterAuth::Plugins.organization(dynamic_access_control: {enabled: true})])
    owner_cookie = sign_up_cookie(auth, email: "predefined-role-owner@example.com")
    organization = auth.api.create_organization(headers: {"cookie" => owner_cookie}, body: {name: "Predefined Role", slug: "predefined-role"})

    blocked = assert_raises(BetterAuth::APIError) do
      auth.api.delete_org_role(headers: {"cookie" => owner_cookie}, body: {organizationId: organization.fetch("id"), roleName: "owner"})
    end
    assert_equal 400, blocked.status_code
    assert_equal BetterAuth::Plugins::ORGANIZATION_ERROR_CODES.fetch("CANNOT_DELETE_A_PRE_DEFINED_ROLE"), blocked.message
  end

  private

  def build_organization_auth(options = {})
    build_auth({
      plugins: [BetterAuth::Plugins.organization(teams: {enabled: true}, dynamic_access_control: {enabled: true})]
    }.merge(options))
  end
end
