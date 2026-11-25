# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def organization_permission?(ctx, config, role_string, permissions, organization_id)
      roles = organization_roles(config)
      if org_truthy?(config.dig(:dynamic_access_control, :enabled))
        ctx.context.adapter.find_many(model: "organizationRole", where: [{field: "organizationId", value: organization_id}]).each do |entry|
          permission = parse_permission(entry["permission"])
          if roles.key?(entry["role"])
            permission = merge_permissions(roles[entry["role"]].statements, permission)
          end
          roles[entry["role"]] = (config[:ac] || create_access_control(ORGANIZATION_DEFAULT_STATEMENTS)).new_role(permission)
        end
      end
      role_string.to_s.split(",").any? do |role|
        roles[role]&.authorize(permissions || {})&.fetch(:success, false)
      end
    end

    def merge_permissions(base, extra)
      stringify_permission(base).merge(stringify_permission(extra)) do |_resource, base_actions, extra_actions|
        (Array(base_actions) + Array(extra_actions)).map(&:to_s).uniq
      end
    end

    def parse_permission(value)
      return value if value.is_a?(Hash)
      return {} if value.nil? || value.to_s.empty?

      JSON.parse(value)
    rescue JSON::ParserError
      {}
    end
  end
end
