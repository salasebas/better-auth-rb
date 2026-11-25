# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def organization_add_member_endpoint(config)
      schema = OrganizationSchema.create_body(config, :member, :organization_id, :user_id, :role, :team_id)
      Endpoint.new(path: "/organization/add-member", method: "POST", body_schema: schema, metadata: organization_openapi("addOrganizationMember", "Add an organization member", response: organization_ref_schema("Member"))) do |ctx|
        session = Routes.current_session(ctx)
        body = ctx.body
        organization_id = body[:organization_id] || session[:session]["activeOrganizationId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION")) unless organization_id

        organization = organization_by_id(ctx, organization_id)
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization

        require_org_permission!(ctx, config, session, organization_id, {member: ["create"]}, ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_MEMBERSHIP_LIMIT_REACHED"))
        user_id = body[:user_id].to_s
        raise APIError.new("BAD_REQUEST", message: "userId is required") if user_id.empty?

        user = ctx.context.internal_adapter.find_user_by_id(user_id)
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES.fetch("USER_NOT_FOUND")) unless user

        if require_member(ctx, user_id, organization_id)
          raise APIError.new("CONFLICT", message: ORGANIZATION_ERROR_CODES.fetch("USER_IS_ALREADY_A_MEMBER_OF_THIS_ORGANIZATION"))
        end
        team_id = body[:team_id]
        if team_id
          unless org_truthy?(config.dig(:teams, :enabled))
            raise APIError.new("BAD_REQUEST", message: "Teams are not enabled")
          end
          team = team_by_id(ctx, team_id)
          unless team && team["organizationId"] == organization_id
            raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND"))
          end
        end

        member_data = {organizationId: organization_id, userId: user_id, role: parse_roles(body[:role] || "member"), createdAt: Time.now}.merge(body.fetch(:additional_fields))
        merge_hook_data!(member_data, run_org_hook(config, :before_add_member, {member: member_data, user: user, organization: organization_wire(ctx, organization)}, ctx))
        member = organization_transaction(ctx) do |adapter|
          lock_organization_capacity!(adapter, organization)
          validate_organization_roles!(ctx, config, organization_id, normalized_role_names(member_data[:role]), adapter: adapter)
          ensure_organization_member_capacity!(ctx, config, user, organization, adapter: adapter)
          ensure_team_member_capacity!(ctx, config, [team_id], adapter: adapter, lock: true) if team_id
          if adapter.find_one(model: "member", where: [{field: "userId", value: user_id}, {field: "organizationId", value: organization_id}])
            raise APIError.new("CONFLICT", message: ORGANIZATION_ERROR_CODES.fetch("USER_IS_ALREADY_A_MEMBER_OF_THIS_ORGANIZATION"))
          end
          created = adapter.create(model: "member", data: member_data)
          adapter.create(model: "teamMember", data: {teamId: team_id, userId: user_id, createdAt: Time.now}) if team_id
          created
        end
        run_org_hook(config, :after_add_member, {member: member_wire(ctx, member), user: user, organization: organization_wire(ctx, organization)}, ctx)
        ctx.json(member_wire(ctx, member))
      end
    end

    def organization_remove_member_endpoint(config)
      Endpoint.new(path: "/organization/remove-member", method: "POST", metadata: organization_openapi("removeOrganizationMember", "Remove an organization member", response: OpenAPI.status_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        member = member_by_id(ctx, body[:member_id]) || require_member(ctx, body[:user_id], body[:organization_id])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("MEMBER_NOT_FOUND")) unless member
        require_org_permission!(ctx, config, session, member["organizationId"], {member: ["delete"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_DELETE_THIS_MEMBER"))
        organization = organization_by_id(ctx, member["organizationId"])
        user = ctx.context.internal_adapter.find_user_by_id(member["userId"])
        run_org_hook(config, :before_remove_member, {member: member_wire(ctx, member), user: user, organization: organization_wire(ctx, organization)}, ctx)
        organization_transaction(ctx) do |adapter|
          lock_organization_capacity!(adapter, organization)
          ensure_not_last_owner!(ctx, member, adapter: adapter)
          adapter.delete(model: "member", where: [{field: "id", value: member["id"]}])
          if org_truthy?(config.dig(:teams, :enabled))
            team_ids = adapter.find_many(model: "team", where: [{field: "organizationId", value: member["organizationId"]}]).map { |team| team["id"] }
            adapter.delete_many(model: "teamMember", where: [{field: "userId", value: member["userId"]}, {field: "teamId", value: team_ids, operator: "in"}]) if team_ids.any?
          end
        end
        run_org_hook(config, :after_remove_member, {member: member_wire(ctx, member), user: user, organization: organization_wire(ctx, organization)}, ctx)
        ctx.json({status: true})
      end
    end

    def organization_update_member_role_endpoint(config)
      Endpoint.new(path: "/organization/update-member-role", method: "POST", metadata: organization_openapi("updateOrganizationMemberRole", "Update an organization member role", response: organization_ref_schema("Member"))) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        organization_id = body[:organization_id] || session[:session]["activeOrganizationId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION")) unless organization_id

        role_names = normalized_role_names(body[:role])
        raise APIError.new("BAD_REQUEST") if role_names.empty?

        validate_organization_roles!(ctx, config, organization_id, role_names)

        updating_member = require_member(ctx, session[:user]["id"], organization_id)
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("MEMBER_NOT_FOUND")) unless updating_member

        member = if body[:member_id]
          (body[:member_id].to_s == updating_member["id"]) ? updating_member : member_by_id(ctx, body[:member_id])
        else
          require_member(ctx, body[:user_id], organization_id)
        end
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("MEMBER_NOT_FOUND")) unless member
        unless member["organizationId"] == organization_id
          raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_THIS_MEMBER"))
        end

        creator_role = config[:creator_role]
        updating_member_roles = normalized_role_names(updating_member["role"])
        member_roles = normalized_role_names(member["role"])
        updater_is_creator = updating_member_roles.include?(creator_role)
        updating_creator = member_roles.include?(creator_role)
        setting_creator_role = role_names.include?(creator_role)

        if (updating_creator && !updater_is_creator) || (setting_creator_role && !updater_is_creator)
          raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_THIS_MEMBER"))
        end

        if updater_is_creator && updating_member["id"] == member["id"] && !setting_creator_role
          creator_count = count_members_with_role(ctx, organization_id, creator_role)
          if creator_count <= 1
            raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("YOU_CANNOT_LEAVE_THE_ORGANIZATION_WITHOUT_AN_OWNER"))
          end
        end

        unless updater_is_creator
          require_org_permission!(ctx, config, session, organization_id, {member: ["update"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_THIS_MEMBER"))
        end
        organization = organization_by_id(ctx, organization_id)
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization
        user = ctx.context.internal_adapter.find_user_by_id(member["userId"])
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES.fetch("USER_NOT_FOUND")) unless user
        previous_role = member["role"]
        update = {role: parse_roles(role_names)}
        merge_hook_data!(update, run_org_hook(config, :before_update_member_role, {member: member_wire(ctx, member), new_role: update[:role], user: user, organization: organization_wire(ctx, organization)}, ctx))
        updated = ctx.context.adapter.update(model: "member", where: [{field: "id", value: member["id"]}], update: update)
        run_org_hook(config, :after_update_member_role, {member: member_wire(ctx, updated), previous_role: previous_role, user: user, organization: organization_wire(ctx, organization)}, ctx)
        ctx.json(member_wire(ctx, updated))
      end
    end

    def organization_get_active_member_endpoint(_config)
      Endpoint.new(path: "/organization/get-active-member", method: "GET", metadata: organization_openapi("getActiveOrganizationMember", "Get the active organization member", response: organization_ref_schema("Member"))) do |ctx|
        session = Routes.current_session(ctx)
        organization_id = normalize_hash(ctx.query)[:organization_id] || session[:session]["activeOrganizationId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION")) unless organization_id
        member = require_member!(ctx, session[:user]["id"], organization_id)
        ctx.json(member_wire(ctx, member))
      end
    end

    def organization_get_active_member_role_endpoint(_config)
      Endpoint.new(path: "/organization/get-active-member-role", method: "GET", metadata: organization_openapi("getActiveOrganizationMemberRole", "Get the active organization member role", response: organization_active_member_role_schema)) do |ctx|
        session = Routes.current_session(ctx)
        query = normalize_hash(ctx.query)
        organization_id = query[:organization_id] || session[:session]["activeOrganizationId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION")) unless organization_id
        require_member!(ctx, session[:user]["id"], organization_id)
        member = require_member!(ctx, query[:user_id] || session[:user]["id"], organization_id)
        ctx.json({role: member["role"], member: member_wire(ctx, member)})
      end
    end

    def organization_leave_endpoint(config)
      Endpoint.new(path: "/organization/leave", method: "POST", metadata: organization_openapi("leaveOrganization", "Leave an organization", response: OpenAPI.status_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        organization_id = normalize_hash(ctx.body)[:organization_id]
        member = require_member!(ctx, session[:user]["id"], organization_id)
        organization = organization_by_id(ctx, organization_id)
        organization_transaction(ctx) do |adapter|
          lock_organization_capacity!(adapter, organization)
          ensure_not_last_owner!(ctx, member, adapter: adapter)
          adapter.delete(model: "member", where: [{field: "id", value: member["id"]}])
          if org_truthy?(config.dig(:teams, :enabled))
            team_ids = adapter.find_many(model: "team", where: [{field: "organizationId", value: organization_id}]).map { |team| team["id"] }
            adapter.delete_many(model: "teamMember", where: [{field: "userId", value: session[:user]["id"]}, {field: "teamId", value: team_ids, operator: "in"}]) if team_ids.any?
          end
        end
        clear_active_organization_session(ctx, session, organization_id)
        ctx.json({status: true})
      end
    end

    def organization_list_members_endpoint(config)
      Endpoint.new(path: "/organization/list-members", method: "GET", metadata: organization_openapi("listOrganizationMembers", "List organization members", response: organization_members_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        query = normalize_hash(ctx.query)
        organization_id = query[:organization_id] || organization_by_slug(ctx, query[:organization_slug])&.fetch("id") || session[:session]["activeOrganizationId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION")) unless organization_id
        require_member!(ctx, session[:user]["id"], organization_id)
        ctx.json(list_members_for(ctx, organization_id, query, config, session[:user]))
      end
    end

    def ensure_not_last_owner!(ctx, member, adapter: ctx.context.adapter)
      return unless member["role"].to_s.split(",").include?("owner")

      owner_count = 0
      organization_each_adapter_record(adapter, "member", where: [{field: "organizationId", value: member["organizationId"]}]) do |entry|
        owner_count += 1 if entry["role"].to_s.split(",").include?("owner")
      end
      raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("YOU_CANNOT_LEAVE_THE_ORGANIZATION_AS_THE_ONLY_OWNER")) if owner_count <= 1
    end
  end
end
