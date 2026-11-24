# frozen_string_literal: true

module BetterAuth
  module APIKey
    module OrgAuthorization
      PERMISSIONS = {
        apiKey: %w[create read update delete]
      }.freeze

      module_function

      def check_permission!(ctx, user_id, organization_id, action)
        org_plugin = ctx.context.options.plugins.find { |plugin| plugin.id == "organization" }
        unless org_plugin
          raise BetterAuth::APIError.new(
            "INTERNAL_SERVER_ERROR",
            message: BetterAuth::Plugins::API_KEY_ERROR_CODES["ORGANIZATION_PLUGIN_REQUIRED"],
            code: "ORGANIZATION_PLUGIN_REQUIRED"
          )
        end

        member = ctx.context.adapter.find_one(model: "member", where: [{field: "userId", value: user_id}, {field: "organizationId", value: organization_id}])
        unless member
          raise BetterAuth::APIError.new(
            "FORBIDDEN",
            message: BetterAuth::Plugins::API_KEY_ERROR_CODES["USER_NOT_MEMBER_OF_ORGANIZATION"],
            code: "USER_NOT_MEMBER_OF_ORGANIZATION"
          )
        end

        return member if member["role"].to_s == (org_plugin.options[:creator_role] || "owner").to_s

        permissions = {"apiKey" => [action]}
        return member if BetterAuth::Plugins.organization_permission?(ctx, org_plugin.options, member["role"], permissions, organization_id)

        raise BetterAuth::APIError.new(
          "FORBIDDEN",
          message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INSUFFICIENT_API_KEY_PERMISSIONS"],
          code: "INSUFFICIENT_API_KEY_PERMISSIONS"
        )
      end

      def authorize_reference!(ctx, config, user_id, reference_id, action)
        if config[:references].to_s == "organization"
          check_permission!(ctx, user_id, reference_id, action)
        elsif reference_id != user_id
          raise BetterAuth::APIError.new("NOT_FOUND", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["KEY_NOT_FOUND"])
        end
      end

      def create_reference_id!(ctx, body, session, config)
        if config[:references].to_s == "organization"
          organization_id = body[:organization_id]
          if organization_id.to_s.empty?
            raise BetterAuth::APIError.new(
              "BAD_REQUEST",
              message: BetterAuth::Plugins::API_KEY_ERROR_CODES["ORGANIZATION_ID_REQUIRED"],
              code: "ORGANIZATION_ID_REQUIRED"
            )
          end

          user_id = session&.dig(:user, "id") || body[:user_id]
          raise BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["UNAUTHORIZED_SESSION"]) if user_id.to_s.empty?

          check_permission!(ctx, user_id, organization_id, "create")
          organization_id
        elsif session && body[:user_id] && body[:user_id] != session[:user]["id"]
          raise BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["UNAUTHORIZED_SESSION"])
        elsif session
          session[:user]["id"]
        else
          user_id = body[:user_id]
          raise BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["UNAUTHORIZED_SESSION"]) if user_id.to_s.empty?

          user_id
        end
      end
    end
  end
end
