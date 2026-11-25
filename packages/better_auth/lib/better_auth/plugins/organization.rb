# frozen_string_literal: true

require "json"

require_relative "organization/error_codes"
require_relative "organization/access"
require_relative "organization/adapter"
require_relative "organization/permission"
require_relative "organization/has_permission"
require_relative "organization/hooks"
require_relative "organization/openapi"
require_relative "organization/routes/crud_org"
require_relative "organization/routes/crud_members"
require_relative "organization/routes/crud_invites"
require_relative "organization/routes/crud_team"
require_relative "organization/routes/crud_access_control"

module BetterAuth
  module Plugins
    module_function

    def organization(options = {})
      config = organization_config(options)
      endpoints = {
        create_organization: organization_create_endpoint(config),
        update_organization: organization_update_endpoint(config),
        delete_organization: organization_delete_endpoint(config),
        check_organization_slug: organization_check_slug_endpoint,
        set_active_organization: organization_set_active_endpoint,
        get_full_organization: organization_get_full_endpoint(config),
        list_organizations: organization_list_endpoint,
        create_invitation: organization_invite_endpoint(config),
        cancel_invitation: organization_cancel_invitation_endpoint(config),
        accept_invitation: organization_accept_invitation_endpoint(config),
        reject_invitation: organization_reject_invitation_endpoint(config),
        get_invitation: organization_get_invitation_endpoint(config),
        list_invitations: organization_list_invitations_endpoint(config),
        list_user_invitations: organization_list_user_invitations_endpoint,
        add_member: organization_add_member_endpoint(config),
        remove_member: organization_remove_member_endpoint(config),
        update_member_role: organization_update_member_role_endpoint(config),
        get_active_member: organization_get_active_member_endpoint(config),
        leave_organization: organization_leave_endpoint(config),
        list_members: organization_list_members_endpoint(config),
        get_active_member_role: organization_get_active_member_role_endpoint(config),
        has_permission: organization_has_permission_endpoint(config)
      }

      if org_truthy?(config.dig(:teams, :enabled))
        endpoints.merge!(
          create_team: organization_create_team_endpoint(config),
          remove_team: organization_remove_team_endpoint(config),
          update_team: organization_update_team_endpoint(config),
          list_organization_teams: organization_list_teams_endpoint(config),
          set_active_team: organization_set_active_team_endpoint(config),
          list_user_teams: organization_list_user_teams_endpoint,
          list_team_members: organization_list_team_members_endpoint(config),
          add_team_member: organization_add_team_member_endpoint(config),
          remove_team_member: organization_remove_team_member_endpoint(config)
        )
      end

      if org_truthy?(config.dig(:dynamic_access_control, :enabled))
        endpoints.merge!(
          create_org_role: organization_create_role_endpoint(config),
          delete_org_role: organization_delete_role_endpoint(config),
          list_org_roles: organization_list_roles_endpoint(config),
          get_org_role: organization_get_role_endpoint(config),
          update_org_role: organization_update_role_endpoint(config)
        )
      end

      Plugin.new(
        id: "organization",
        schema: OrganizationSchema.build(config),
        endpoints: endpoints,
        error_codes: ORGANIZATION_ERROR_CODES,
        options: config
      )
    end

    def organization_config(options)
      config = normalize_hash(options)
      config[:allow_user_to_create_organization] = true unless config.key?(:allow_user_to_create_organization)
      config[:creator_role] ||= "owner"
      config[:membership_limit] ||= 100
      config[:invitation_expires_in] ||= 60 * 60 * 48
      config[:invitation_limit] ||= 100
      config[:ac] ||= create_access_control(ORGANIZATION_DEFAULT_STATEMENTS)
      config[:roles] ||= organization_default_roles(config)
      config
    end

    def organization_has_permission_endpoint(config)
      Endpoint.new(path: "/organization/has-permission", method: "POST", metadata: organization_openapi("hasOrganizationPermission", "Check if the member has organization permission", response: organization_permission_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        organization_id = body[:organization_id] || session[:session]["activeOrganizationId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION")) unless organization_id
        member = require_member!(ctx, session[:user]["id"], organization_id)
        permissions = body[:permissions] || body[:permission]
        ctx.json({error: nil, success: organization_permission?(ctx, config, member["role"], permissions, organization_id)})
      end
    end

    def parse_roles(roles)
      Array(roles).join(",")
    end

    def normalized_role_names(roles)
      Array(roles).flat_map { |role| role.to_s.split(",") }.map(&:strip).reject(&:empty?)
    end

    def additional_input(hash, *exclude)
      data = normalize_hash(hash)
      additional = normalize_hash(data.delete(:additional_fields))
      extra_input(data, *exclude, :additional_fields).merge(additional)
    end

    def extra_input(hash, *exclude)
      normalize_hash(hash).except(*exclude.map(&:to_sym))
    end

    def org_truthy?(value)
      value == true || value.to_s == "true"
    end
  end
end
