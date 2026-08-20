# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Routes
      module DeleteAPIKey
        UPSTREAM_SOURCE = "reference/upstream-src/1.7.1/repository/packages/api-key/src/routes/delete-api-key.ts"

        module_function

        def endpoint(config)
          BetterAuth::Endpoint.new(
            path: "/api-key/delete",
            method: "POST",
            body_schema: BetterAuth::APIKey::RequestContract.delete_body_schema,
            metadata: Routes.openapi_for(:delete_api_key)
          ) do |ctx|
            session = BetterAuth::Routes.current_session(ctx)
            raise BetterAuth::APIKey.error("UNAUTHORIZED", "USER_BANNED") if session[:user]["banned"] == true

            body = BetterAuth::Plugins.normalize_hash(ctx.body)
            resolved_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, body[:config_id])
            key_id = body[:key_id]
            record = BetterAuth::Plugins.api_key_find_by_id(ctx, key_id, resolved_config)
            unless record && BetterAuth::Plugins.api_key_config_id_matches?(BetterAuth::Plugins.api_key_record_config_id(record), resolved_config[:config_id])
              raise BetterAuth::APIKey.error("NOT_FOUND", "KEY_NOT_FOUND")
            end

            record_config = BetterAuth::Plugins.api_key_resolve_config(ctx.context, config, BetterAuth::Plugins.api_key_record_config_id(record))
            BetterAuth::Plugins.api_key_authorize_reference!(ctx, record_config, session[:user]["id"], BetterAuth::Plugins.api_key_record_reference_id(record), "delete")

            BetterAuth::Plugins.api_key_delete_record(ctx, record, record_config)
            BetterAuth::Plugins.api_key_delete_expired(ctx.context, record_config)
            ctx.json({success: true})
          end
        end
      end
    end
  end
end
