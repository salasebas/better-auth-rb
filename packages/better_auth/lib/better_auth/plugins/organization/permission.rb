# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def validate_organization_roles!(ctx, config, organization_id, role_names, adapter: ctx.context.adapter)
      valid_static_roles = (organization_default_roles(config).keys + organization_roles(config).keys).uniq
      unknown_roles = role_names.reject { |role| valid_static_roles.include?(role) }.uniq
      return if unknown_roles.empty?

      if org_truthy?(config.dig(:dynamic_access_control, :enabled))
        found_roles = adapter.find_many(
          model: "organizationRole",
          where: [{field: "organizationId", value: organization_id}, {field: "role", value: unknown_roles, operator: "in"}]
        ).map { |role| role["role"] }
        unknown_roles -= found_roles
      end
      return if unknown_roles.empty?

      raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ROLE_NOT_FOUND"))
    end

    def organization_roles(config)
      (config[:roles] || organization_default_roles(config)).transform_keys(&:to_s)
    end

    def require_org_permission!(ctx, config, session, organization_id, permissions, message)
      member = require_member!(ctx, session[:user]["id"], organization_id)
      return member if organization_permission?(ctx, config, member["role"], permissions, organization_id)

      raise APIError.new("FORBIDDEN", message: message)
    end

    def stringify_permission(value)
      normalize_hash(value || {}).each_with_object({}) do |(resource, actions), result|
        result[resource.to_s] = Array(actions).map(&:to_s)
      end
    end
  end
end
