# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def organization_create_team_endpoint(config)
      Endpoint.new(path: "/organization/create-team", method: "POST", metadata: organization_openapi("createOrganizationTeam", "Create an organization team", response: organization_ref_schema("Team"))) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        organization_id = body[:organization_id] || session[:session]["activeOrganizationId"]
        require_org_permission!(ctx, config, session, organization_id, {team: ["create"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_CREATE_TEAMS_IN_THIS_ORGANIZATION"))
        organization = organization_by_id(ctx, organization_id)
        team_data = {organizationId: organization_id, name: body[:name].to_s, createdAt: Time.now}.merge(additional_input(body, :organization_id, :name))
        merge_hook_data!(team_data, run_org_hook(config, :before_create_team, {team: team_data, user: session[:user], organization: organization_wire(ctx, organization)}, ctx))
        team = organization_transaction(ctx) do |adapter|
          lock_organization_capacity!(adapter, organization)
          max_teams = config.dig(:teams, :maximum_teams)
          if max_teams && adapter.count(model: "team", where: [{field: "organizationId", value: organization_id}]) >= max_teams.to_i
            raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_HAVE_REACHED_THE_MAXIMUM_NUMBER_OF_TEAMS"))
          end
          created = adapter.create(model: "team", data: team_data, force_allow_id: true)
          adapter.create(model: "teamMember", data: {teamId: created["id"], userId: session[:user]["id"], createdAt: Time.now})
          created
        end
        run_org_hook(config, :after_create_team, {team: team_wire(ctx, team), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        ctx.json(team_wire(ctx, team))
      end
    end

    def organization_list_teams_endpoint(_config)
      Endpoint.new(path: "/organization/list-teams", method: "GET", metadata: organization_openapi("listOrganizationTeams", "List organization teams", response: organization_array_schema("Team"))) do |ctx|
        session = Routes.current_session(ctx)
        organization_id = normalize_hash(ctx.query)[:organization_id] || session[:session]["activeOrganizationId"]
        require_member!(ctx, session[:user]["id"], organization_id)
        teams = ctx.context.adapter.find_many(model: "team", where: [{field: "organizationId", value: organization_id}])
        ctx.json(teams.map { |team| team_wire(ctx, team) })
      end
    end

    def organization_update_team_endpoint(config)
      Endpoint.new(path: "/organization/update-team", method: "POST", metadata: organization_openapi("updateOrganizationTeam", "Update an organization team", response: organization_ref_schema("Team"))) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        team = team_by_id(ctx, body[:team_id])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND")) unless team
        require_org_permission!(ctx, config, session, team["organizationId"], {team: ["update"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_THIS_TEAM"))
        organization = organization_by_id(ctx, team["organizationId"])
        update = additional_input(body[:data].is_a?(Hash) ? body[:data] : body, :team_id, :organization_id)
        merge_hook_data!(update, run_org_hook(config, :before_update_team, {team: team_wire(ctx, team), updates: update, user: session[:user], organization: organization_wire(ctx, organization)}, ctx))
        updated = ctx.context.adapter.update(model: "team", where: [{field: "id", value: team["id"]}], update: update)
        run_org_hook(config, :after_update_team, {team: team_wire(ctx, updated), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        ctx.json(team_wire(ctx, updated))
      end
    end

    def organization_remove_team_endpoint(config)
      Endpoint.new(path: "/organization/remove-team", method: "POST", metadata: organization_openapi("removeOrganizationTeam", "Remove an organization team", response: OpenAPI.status_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        team = team_by_id(ctx, normalize_hash(ctx.body)[:team_id])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND")) unless team
        require_org_permission!(ctx, config, session, team["organizationId"], {team: ["delete"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_DELETE_THIS_TEAM"))
        organization = organization_by_id(ctx, team["organizationId"])
        run_org_hook(config, :before_delete_team, {team: team_wire(ctx, team), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        organization_transaction(ctx) do |adapter|
          lock_organization_capacity!(adapter, organization)
          teams = adapter.find_many(model: "team", where: [{field: "organizationId", value: team["organizationId"]}])
          if teams.length <= 1 && config.dig(:teams, :allow_removing_all_teams) != true
            raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("UNABLE_TO_REMOVE_LAST_TEAM"))
          end
          adapter.delete_many(model: "teamMember", where: [{field: "teamId", value: team["id"]}])
          adapter.delete(model: "team", where: [{field: "id", value: team["id"]}])
          pending = adapter.find_many(model: "invitation", where: [{field: "organizationId", value: team["organizationId"]}, {field: "status", value: "pending"}])
          pending.each do |invitation|
            team_ids = organization_team_ids(invitation["teamId"])
            next unless team_ids.include?(team["id"])

            remaining = team_ids.reject { |team_id| team_id == team["id"] }
            adapter.update(model: "invitation", where: [{field: "id", value: invitation["id"]}], update: {teamId: remaining.any? ? remaining.join(",") : nil})
          end
        end
        run_org_hook(config, :after_delete_team, {team: team_wire(ctx, team), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        ctx.json({status: true})
      end
    end

    def organization_set_active_team_endpoint(_config)
      Endpoint.new(path: "/organization/set-active-team", method: "POST", metadata: organization_openapi("setActiveOrganizationTeam", "Set the active organization team", response: organization_nullable_schema("Team"))) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        if body.key?(:team_id) && body[:team_id].nil?
          updated_session = ctx.context.internal_adapter.update_session(session[:session]["token"], {activeTeamId: nil})
          Cookies.set_session_cookie(ctx, {session: updated_session || session[:session].merge("activeTeamId" => nil), user: session[:user]})
          next ctx.json({status: true})
        end
        team = team_by_id(ctx, body[:team_id])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND")) unless team
        active_organization_id = session[:session]["activeOrganizationId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION")) unless active_organization_id
        unless team["organizationId"] == active_organization_id
          raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND"))
        end
        require_team_member!(ctx, session[:user]["id"], team["id"])
        updated_session = ctx.context.internal_adapter.update_session(session[:session]["token"], {activeTeamId: team["id"]})
        Cookies.set_session_cookie(ctx, {session: updated_session || session[:session].merge("activeTeamId" => team["id"]), user: session[:user]})
        ctx.json(team_wire(ctx, team))
      end
    end

    def organization_list_user_teams_endpoint
      Endpoint.new(path: "/organization/list-user-teams", method: "GET", metadata: organization_openapi("listUserTeams", "List user teams", response: organization_array_schema("Team"))) do |ctx|
        session = Routes.current_session(ctx)
        memberships = ctx.context.adapter.find_many(model: "teamMember", where: [{field: "userId", value: session[:user]["id"]}])
        ctx.json(memberships.filter_map { |entry| team_by_id(ctx, entry["teamId"]) }.map { |team| team_wire(ctx, team) })
      end
    end

    def organization_list_team_members_endpoint(_config)
      Endpoint.new(path: "/organization/list-team-members", method: "GET", metadata: organization_openapi("listTeamMembers", "List team members", response: organization_array_schema("TeamMember"))) do |ctx|
        session = Routes.current_session(ctx)
        team_id = normalize_hash(ctx.query)[:team_id] || session[:session]["activeTeamId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("YOU_DO_NOT_HAVE_AN_ACTIVE_TEAM")) unless team_id
        team = team_by_id(ctx, team_id)
        require_member!(ctx, session[:user]["id"], team["organizationId"])
        members = ctx.context.adapter.find_many(model: "teamMember", where: [{field: "teamId", value: team_id}])
        ctx.json(members.map { |entry| team_member_wire(ctx, entry) })
      end
    end

    def organization_add_team_member_endpoint(config)
      Endpoint.new(path: "/organization/add-team-member", method: "POST", metadata: organization_openapi("addTeamMember", "Add a team member", response: organization_ref_schema("TeamMember"))) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        team = team_by_id(ctx, body[:team_id])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND")) unless team
        require_org_permission!(ctx, config, session, team["organizationId"], {team: ["update"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_CREATE_A_NEW_TEAM_MEMBER"))
        user_id = body[:user_id].to_s
        require_member!(ctx, user_id, team["organizationId"])
        user = ctx.context.internal_adapter.find_user_by_id(user_id)
        organization = organization_by_id(ctx, team["organizationId"])
        member_data = {teamId: team["id"], userId: user_id, createdAt: Time.now}
        run_org_hook(config, :before_add_team_member, {team_member: member_data, team: team_wire(ctx, team), user: user, organization: organization_wire(ctx, organization)}, ctx)
        member = organization_transaction(ctx) do |adapter|
          existing = adapter.find_one(model: "teamMember", where: [{field: "teamId", value: team["id"]}, {field: "userId", value: user_id}])
          next existing if existing

          ensure_team_member_capacity!(ctx, config, [team["id"]], adapter: adapter, lock: true)
          adapter.create(model: "teamMember", data: member_data)
        end
        run_org_hook(config, :after_add_team_member, {team_member: team_member_wire(ctx, member), team: team_wire(ctx, team), user: user, organization: organization_wire(ctx, organization)}, ctx)
        ctx.json(team_member_wire(ctx, member))
      end
    end

    def organization_remove_team_member_endpoint(config)
      Endpoint.new(path: "/organization/remove-team-member", method: "POST", metadata: organization_openapi("removeTeamMember", "Remove a team member", response: OpenAPI.status_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        team = team_by_id(ctx, body[:team_id])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND")) unless team
        require_org_permission!(ctx, config, session, team["organizationId"], {team: ["update"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_REMOVE_A_TEAM_MEMBER"))
        member = ctx.context.adapter.find_one(model: "teamMember", where: [{field: "teamId", value: team["id"]}, {field: "userId", value: body[:user_id]}])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("USER_IS_NOT_A_MEMBER_OF_THE_TEAM")) unless member
        user = ctx.context.internal_adapter.find_user_by_id(body[:user_id])
        organization = organization_by_id(ctx, team["organizationId"])
        run_org_hook(config, :before_remove_team_member, {team_member: team_member_wire(ctx, member), team: team_wire(ctx, team), user: user, organization: organization_wire(ctx, organization)}, ctx)
        ctx.context.adapter.delete_many(model: "teamMember", where: [{field: "teamId", value: team["id"]}, {field: "userId", value: body[:user_id]}])
        run_org_hook(config, :after_remove_team_member, {team_member: team_member_wire(ctx, member), team: team_wire(ctx, team), user: user, organization: organization_wire(ctx, organization)}, ctx)
        ctx.json({status: true})
      end
    end
  end
end
