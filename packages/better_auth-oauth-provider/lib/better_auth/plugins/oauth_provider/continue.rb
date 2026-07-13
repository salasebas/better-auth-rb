# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def oauth_continue_endpoint(config)
      Endpoint.new(path: "/oauth2/continue", method: "POST", metadata: oauth_openapi_for(:continue)) do |ctx|
        Routes.current_session(ctx)
        body = OAuthProtocol.stringify_keys(ctx.body)
        action = if body["selected"] == true
          "select_account"
        elsif body["created"] == true
          "create"
        elsif body["postLogin"] == true || body["post_login"] == true
          "post_login"
        end
        raise APIError.new("BAD_REQUEST", message: "Missing parameters") unless action

        query = oauth_verified_query!(ctx, body["oauth_query"])
        oauth_delete_prompt!(query, action) unless action == "post_login"
        oauth_consume_post_login_marker!(ctx, query, Routes.current_session(ctx, allow_nil: true)) if action == "post_login"
        result = oauth_dispatch_authorize(ctx, config, query)
        location = result.headers["location"]
        location ? ctx.json({redirect: true, url: location}) : result
      end
    end
  end
end
