# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def organization_create_endpoint(config)
      Endpoint.new(path: "/organization/create", method: "POST", metadata: organization_openapi("createOrganization", "Create an organization", response: organization_ref_schema("Organization"))) do |ctx|
        body = normalize_hash(ctx.body)
        session = Routes.current_session(ctx, allow_nil: true)
        user = session ? session[:user] : ctx.context.internal_adapter.find_user_by_id(body[:user_id])
        raise APIError.new("UNAUTHORIZED") unless user
        name = body[:name].to_s
        slug = body[:slug].to_s
        raise APIError.new("BAD_REQUEST", message: "name is required") if name.empty?
        raise APIError.new("BAD_REQUEST", message: "slug is required") if slug.empty?

        allowed = config[:allow_user_to_create_organization]
        allowed = allowed.call(user) if allowed.respond_to?(:call)
        raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_CREATE_A_NEW_ORGANIZATION")) unless allowed

        if config[:organization_limit]
          limit_reached = config[:organization_limit].respond_to?(:call) ? config[:organization_limit].call(user) : organization_created_count(ctx, user["id"]) >= config[:organization_limit].to_i
          raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_HAVE_REACHED_THE_MAXIMUM_NUMBER_OF_ORGANIZATIONS")) if limit_reached
        end

        if organization_by_slug(ctx, slug)
          raise APIError.new("CONFLICT", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_ALREADY_EXISTS"))
        end

        data = {
          name: name,
          slug: slug,
          logo: body[:logo],
          metadata: serialize_metadata(body[:metadata]),
          createdAt: Time.now
        }.merge(additional_input(body, :name, :slug, :logo, :metadata, :keep_current_active_organization, :user_id))
        merge_hook_data!(data, run_org_hook(config, :before_create_organization, {organization: data, user: user}, ctx))
        organization = ctx.context.adapter.create(model: "organization", data: data, force_allow_id: true)
        member_data = {organizationId: organization["id"], userId: user["id"], role: config[:creator_role], createdAt: Time.now}
        merge_hook_data!(member_data, run_org_hook(config, :before_add_member, {member: member_data, user: user, organization: organization_wire(ctx, organization)}, ctx))
        member = ctx.context.adapter.create(model: "member", data: member_data)
        run_org_hook(config, :after_add_member, {member: member_wire(ctx, member), user: user, organization: organization_wire(ctx, organization)}, ctx)
        default_team = create_default_team(ctx, config, organization, {user: user}) if org_truthy?(config.dig(:teams, :enabled)) && config.dig(:teams, :default_team, :enabled) != false
        run_org_hook(config, :after_create_organization, {organization: organization_wire(ctx, organization), member: member, user: user}, ctx)
        if session && !org_truthy?(body[:keep_current_active_organization])
          update = {activeOrganizationId: organization["id"], activeTeamId: default_team && default_team["id"]}
          updated_session = ctx.context.internal_adapter.update_session(session[:session]["token"], update)
          Cookies.set_session_cookie(ctx, {session: updated_session || session[:session].merge(update.transform_keys(&:to_s)), user: user})
        end
        ctx.json(organization_wire(ctx, organization).merge(members: [member_wire(ctx, member)]))
      end
    end

    def organization_check_slug_endpoint
      Endpoint.new(path: "/organization/check-slug", method: "POST", metadata: organization_openapi("checkOrganizationSlug", "Check if an organization slug is available", response: OpenAPI.status_response_schema)) do |ctx|
        Routes.request_only_session(ctx)
        slug = normalize_hash(ctx.body)[:slug].to_s
        if slug.empty? || organization_by_slug(ctx, slug)
          raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_SLUG_ALREADY_TAKEN"))
        end
        ctx.json({status: true})
      end
    end

    def organization_list_endpoint
      Endpoint.new(path: "/organization/list", method: "GET", metadata: organization_openapi("listOrganizations", "List organizations", response: organization_array_schema("Organization"))) do |ctx|
        session = Routes.current_session(ctx)
        members = ctx.context.adapter.find_many(model: "member", where: [{field: "userId", value: session[:user]["id"]}])
        organizations = members.filter_map { |member| organization_by_id(ctx, member["organizationId"]) }
        ctx.json(organizations.map { |entry| organization_wire(ctx, entry) })
      end
    end

    def organization_update_endpoint(config)
      Endpoint.new(path: "/organization/update", method: "POST", metadata: organization_openapi("updateOrganization", "Update an organization", response: organization_ref_schema("Organization"))) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        id = body[:organization_id] || body[:organizationId]
        data = normalize_hash(body[:data] || body)
        organization = organization_by_id(ctx, id) || organization_by_slug(ctx, body[:organization_slug])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization
        member = require_org_permission!(ctx, config, session, organization["id"], {organization: ["update"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_THIS_ORGANIZATION"))
        if data[:slug] && data[:slug].to_s.empty?
          raise APIError.new("BAD_REQUEST", message: "slug is required")
        end
        if data[:name] && data[:name].to_s.empty?
          raise APIError.new("BAD_REQUEST", message: "name is required")
        end
        existing = data[:slug] ? organization_by_slug(ctx, data[:slug]) : nil
        raise APIError.new("CONFLICT", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_SLUG_ALREADY_TAKEN")) if existing && existing["id"] != organization["id"]
        update = additional_input(data, :organization_id, :organizationId, :organization_slug, :data)
        update[:metadata] = serialize_metadata(update[:metadata]) if update.key?(:metadata)
        merge_hook_data!(update, run_org_hook(config, :before_update_organization, {organization: update, user: session[:user], member: member_wire(ctx, member)}, ctx))
        updated = ctx.context.adapter.update(model: "organization", where: [{field: "id", value: organization["id"]}], update: update)
        run_org_hook(config, :after_update_organization, {organization: organization_wire(ctx, updated), user: session[:user], member: member_wire(ctx, member)}, ctx)
        ctx.json(organization_wire(ctx, updated))
      end
    end

    def organization_delete_endpoint(config)
      Endpoint.new(path: "/organization/delete", method: "POST", metadata: organization_openapi("deleteOrganization", "Delete an organization", response: OpenAPI.status_response_schema)) do |ctx|
        if org_truthy?(config[:disable_organization_deletion])
          raise APIError.new("NOT_FOUND", code: "ORGANIZATION_DELETION_DISABLED", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_DELETION_DISABLED"))
        end
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        organization = organization_by_id(ctx, body[:organization_id]) || organization_by_slug(ctx, body[:organization_slug])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization
        require_org_permission!(ctx, config, session, organization["id"], {organization: ["delete"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_DELETE_THIS_ORGANIZATION"))
        run_org_hook(config, :before_delete_organization, {organization: organization_wire(ctx, organization), user: session[:user]}, ctx)
        organization_transaction(ctx) do |adapter|
          if org_truthy?(config.dig(:teams, :enabled))
            team_ids = adapter.find_many(model: "team", where: [{field: "organizationId", value: organization["id"]}]).map { |team| team["id"] }
            adapter.delete_many(model: "teamMember", where: [{field: "teamId", value: team_ids, operator: "in"}]) if team_ids.any?
            adapter.delete_many(model: "team", where: [{field: "organizationId", value: organization["id"]}])
          end
          adapter.delete_many(model: "invitation", where: [{field: "organizationId", value: organization["id"]}])
          adapter.delete_many(model: "member", where: [{field: "organizationId", value: organization["id"]}])
          adapter.delete_many(model: "organizationRole", where: [{field: "organizationId", value: organization["id"]}]) if org_truthy?(config.dig(:dynamic_access_control, :enabled))
          adapter.delete(model: "organization", where: [{field: "id", value: organization["id"]}])
        end
        clear_active_organization_session(ctx, session, organization["id"])
        run_org_hook(config, :after_delete_organization, {organization: organization_wire(ctx, organization), user: session[:user]}, ctx)
        ctx.json({status: true})
      end
    end

    def organization_set_active_endpoint
      Endpoint.new(path: "/organization/set-active", method: "POST", metadata: organization_openapi("setActiveOrganization", "Set the active organization", response: organization_nullable_schema("Organization"))) do |ctx|
        session = Routes.current_session(ctx, sensitive: true)
        body = normalize_hash(ctx.body)
        if body.key?(:organization_id) && body[:organization_id].nil?
          updated_session = ctx.context.internal_adapter.update_session(session[:session]["token"], {activeOrganizationId: nil, activeTeamId: nil})
          Cookies.set_session_cookie(ctx, {session: updated_session || session[:session].merge("activeOrganizationId" => nil, "activeTeamId" => nil), user: session[:user]})
          next ctx.json(nil)
        end

        organization = organization_by_id(ctx, body[:organization_id]) || organization_by_slug(ctx, body[:organization_slug])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization
        require_member!(ctx, session[:user]["id"], organization["id"])
        updated_session = ctx.context.internal_adapter.update_session(session[:session]["token"], {activeOrganizationId: organization["id"], activeTeamId: nil})
        Cookies.set_session_cookie(ctx, {session: updated_session || session[:session].merge("activeOrganizationId" => organization["id"], "activeTeamId" => nil), user: session[:user]})
        ctx.json(organization_wire(ctx, organization))
      end
    end

    def organization_get_full_endpoint(config)
      Endpoint.new(path: "/organization/get-full-organization", method: "GET", metadata: organization_openapi("getOrganization", "Get the full organization", response: organization_nullable_schema("Organization"))) do |ctx|
        session = Routes.current_session(ctx)
        query = normalize_hash(ctx.query)
        explicit_lookup = query.key?(:organization_slug) || query.key?(:organization_id)
        organization = organization_by_slug(ctx, query[:organization_slug]) || organization_by_id(ctx, query[:organization_id] || session[:session]["activeOrganizationId"])
        unless organization
          raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) if explicit_lookup

          next ctx.json(nil)
        end

        require_member!(ctx, session[:user]["id"], organization["id"])
        members = list_members_for(ctx, organization["id"], {limit: query[:members_limit] || config[:membership_limit]})
        invitations = ctx.context.adapter.find_many(model: "invitation", where: [{field: "organizationId", value: organization["id"]}])
        result = organization_wire(ctx, organization).merge(
          members: members.fetch(:members),
          invitations: invitations.map { |entry| invitation_wire(ctx, entry) }
        )
        if org_truthy?(config.dig(:teams, :enabled))
          teams = ctx.context.adapter.find_many(model: "team", where: [{field: "organizationId", value: organization["id"]}])
          result[:teams] = teams.map { |team| team_wire(ctx, team) }
        end
        ctx.json(result)
      end
    end

    def create_default_team(ctx, config, organization, session)
      custom = config.dig(:teams, :default_team, :custom_create_default_team)
      team_data = {organizationId: organization["id"], name: organization["name"], createdAt: Time.now}
      merge_hook_data!(team_data, run_org_hook(config, :before_create_team, {team: team_data, user: session[:user], organization: organization_wire(ctx, organization)}, ctx))
      team = if custom.respond_to?(:call)
        custom.call(organization_wire(ctx, organization), ctx)
      else
        ctx.context.adapter.create(model: "team", data: team_data, force_allow_id: true)
      end
      ctx.context.adapter.create(model: "teamMember", data: {teamId: team["id"], userId: session[:user]["id"], createdAt: Time.now})
      run_org_hook(config, :after_create_team, {team: team_wire(ctx, team), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
      team
    end
  end
end
