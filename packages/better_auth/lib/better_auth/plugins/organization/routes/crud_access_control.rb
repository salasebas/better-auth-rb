# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def organization_create_role_endpoint(config)
      schema = OrganizationSchema.create_body(config, :organization_role, :organization_id, :role, :role_name, :permission, :permissions, nested: true)
      Endpoint.new(path: "/organization/create-role", method: "POST", body_schema: schema, metadata: organization_openapi("createOrganizationRole", "Create an organization role", response: organization_role_action_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = ctx.body
        organization_id = body[:organization_id] || session[:session]["activeOrganizationId"]
        require_org_permission!(ctx, config, session, organization_id, {ac: ["create"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_CREATE_A_ROLE"))
        role_name = (body[:role] || body[:role_name]).to_s
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ROLE_NAME_IS_ALREADY_TAKEN")) if organization_roles(config).key?(role_name) || organization_role_by_name(ctx, organization_id, role_name)
        permission = stringify_permission(body[:permission] || body[:permissions])
        validate_permission_resources!(config, permission)
        unless organization_can_delegate_permissions?(ctx, config, require_member!(ctx, session[:user]["id"], organization_id)["role"], permission, organization_id)
          raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_CREATE_A_ROLE"))
        end
        role = ctx.context.adapter.create(model: "organizationRole", data: {organizationId: organization_id, role: role_name, permission: JSON.generate(permission), createdAt: Time.now}.merge(body.fetch(:additional_fields)))
        wired = organization_role_wire(role)
        ctx.json({success: true, roleData: wired, statements: (config[:ac] || create_access_control(ORGANIZATION_DEFAULT_STATEMENTS)).new_role(permission).statements})
      end
    end

    def organization_list_roles_endpoint(config)
      Endpoint.new(path: "/organization/list-roles", method: "GET", metadata: organization_openapi("listOrganizationRoles", "List organization roles", response: {type: "array", items: organization_role_schema})) do |ctx|
        session = Routes.current_session(ctx)
        organization_id = normalize_hash(ctx.query)[:organization_id] || session[:session]["activeOrganizationId"]
        require_org_permission!(ctx, config, session, organization_id, {ac: ["read"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_LIST_A_ROLE"))
        defaults = organization_roles(config).keys.map { |role| {"role" => role, "permission" => {}} }
        dynamic = ctx.context.adapter.find_many(model: "organizationRole", where: [{field: "organizationId", value: organization_id}]).map { |role| organization_role_wire(role) }
        ctx.json(defaults + dynamic)
      end
    end

    def organization_get_role_endpoint(config)
      Endpoint.new(path: "/organization/get-role", method: "GET", metadata: organization_openapi("getOrganizationRole", "Get an organization role", response: organization_role_schema)) do |ctx|
        session = Routes.current_session(ctx)
        query = normalize_hash(ctx.query)
        organization_id = query[:organization_id] || session[:session]["activeOrganizationId"]
        require_org_permission!(ctx, config, session, organization_id, {ac: ["read"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_GET_A_ROLE"))
        role = organization_role_by_id(ctx, query[:role_id]) || organization_role_by_name(ctx, organization_id, query[:role])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ROLE_NOT_FOUND")) unless role
        ctx.json(organization_role_wire(role))
      end
    end

    def organization_update_role_endpoint(config)
      schema = OrganizationSchema.update_body(config, :organization_role, :role, :role_name, :permission, :permissions, outer: %i[organization_id role_id role role_name permission permissions])
      Endpoint.new(path: "/organization/update-role", method: "POST", body_schema: schema, metadata: organization_openapi("updateOrganizationRole", "Update an organization role", response: organization_role_action_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = ctx.body
        organization_id = body[:organization_id] || session[:session]["activeOrganizationId"]
        require_org_permission!(ctx, config, session, organization_id, {ac: ["update"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_A_ROLE"))
        role = organization_role_by_id(ctx, body[:role_id]) || organization_role_by_name(ctx, organization_id, body[:role] || body[:role_name])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ROLE_NOT_FOUND")) unless role
        data = body.fetch(:data)
        update = data.except(:role, :role_name, :permission, :permissions)
        update[:role] = data[:role] || data[:role_name] if data[:role] || data[:role_name]
        permission = body[:permission] || body[:permissions] || body.dig(:data, :permission) || body.dig(:data, :permissions)
        if permission
          permission = stringify_permission(permission)
          validate_permission_resources!(config, permission)
          unless organization_can_delegate_permissions?(ctx, config, require_member!(ctx, session[:user]["id"], organization_id)["role"], permission, organization_id)
            raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_UPDATE_A_ROLE"))
          end
          update[:permission] = JSON.generate(permission)
        end
        updated = ctx.context.adapter.update(model: "organizationRole", where: [{field: "id", value: role["id"]}], update: update)
        ctx.json({success: true, roleData: organization_role_wire(updated)})
      end
    end

    def organization_delete_role_endpoint(config)
      Endpoint.new(path: "/organization/delete-role", method: "POST", metadata: organization_openapi("deleteOrganizationRole", "Delete an organization role", response: OpenAPI.success_response_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        organization_id = body[:organization_id] || session[:session]["activeOrganizationId"]
        require_org_permission!(ctx, config, session, organization_id, {ac: ["delete"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_DELETE_A_ROLE"))
        role_name = body[:role] || body[:role_name]
        if role_name && organization_roles(config).key?(role_name.to_s)
          raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("CANNOT_DELETE_A_PRE_DEFINED_ROLE"))
        end
        role = organization_role_by_id(ctx, body[:role_id]) || organization_role_by_name(ctx, organization_id, role_name)
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ROLE_NOT_FOUND")) unless role
        assigned = ctx.context.adapter.find_many(model: "member", where: [{field: "organizationId", value: organization_id}]).any? do |member|
          member["role"].to_s.split(",").map(&:strip).include?(role["role"])
        end
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ROLE_IS_ASSIGNED_TO_MEMBERS")) if assigned
        ctx.context.adapter.delete(model: "organizationRole", where: [{field: "id", value: role["id"]}])
        ctx.json({success: true})
      end
    end

    def organization_can_delegate_permissions?(ctx, config, role_string, permissions, organization_id)
      permissions.all? do |resource, actions|
        actions.all? do |action|
          organization_permission?(ctx, config, role_string, {resource => [action]}, organization_id)
        end
      end
    end

    def validate_permission_resources!(config, permission)
      valid = (config[:ac] || create_access_control(ORGANIZATION_DEFAULT_STATEMENTS)).statements.keys
      invalid = permission.keys - valid
      raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("INVALID_RESOURCE")) if invalid.any?
    end
  end
end
