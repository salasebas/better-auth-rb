# frozen_string_literal: true

module BetterAuth
  module Routes
    def self.sign_out
      Endpoint.new(
        path: "/sign-out",
        method: "POST",
        metadata: {
          openapi: {
            operationId: "signOut",
            description: "Sign out the current session",
            responses: {
              "200" => OpenAPI.json_response("Successfully signed out", OpenAPI.success_response_schema)
            }
          }
        }
      ) do |ctx|
        token_cookie = ctx.context.auth_cookies[:session_token]
        token = ctx.get_signed_cookie(token_cookie.name, ctx.context.secret)
        if token
          begin
            ctx.context.internal_adapter.delete_session(token)
          rescue => error
            logger = ctx.context.logger
            message = "Failed to delete session from database"
            if logger.respond_to?(:call)
              logger.call(:error, message, error)
            elsif logger.respond_to?(:error)
              logger.error(message, error)
            end
          end
        end
        Cookies.delete_session_cookie(ctx)
        ctx.json({success: true})
      end
    end
  end
end
