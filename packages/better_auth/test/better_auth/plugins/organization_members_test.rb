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
