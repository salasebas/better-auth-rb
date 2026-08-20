# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Session
      module_function

      def find_key_and_config(ctx, config)
        config.fetch(:configurations, [config]).each do |entry|
          next unless entry[:enable_session_for_api_keys]

          key = BetterAuth::APIKey::Keys.from_headers(ctx, entry)
          return {key: key, config: entry} if BetterAuth::APIKey::Keys.truthy?(key)
        end
        nil
      end

      def header_config(ctx, config)
        find_key_and_config(ctx, config)&.fetch(:config)
      end

      def hook(ctx, config)
        result = find_key_and_config(ctx, config)
        config = result.fetch(:config)
        key = result.fetch(:key)
        unless key.is_a?(String)
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_API_KEY_GETTER_RETURN_TYPE"])
        end
        raise BetterAuth::APIError.new("FORBIDDEN", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_API_KEY"]) if key.length < config[:default_key_length].to_i

        if config[:custom_api_key_validator].respond_to?(:call) && !config[:custom_api_key_validator].call({ctx: ctx, key: key})
          raise BetterAuth::APIError.new("FORBIDDEN", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_API_KEY"])
        end

        record = BetterAuth::Plugins.api_key_validate!(ctx, key, config)
        BetterAuth::APIKey::Routes.schedule_cleanup(ctx, config)
        if config[:references].to_s != "user"
          raise BetterAuth::APIError.new(
            "UNAUTHORIZED",
            message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_REFERENCE_ID_FROM_API_KEY"],
            code: "INVALID_REFERENCE_ID_FROM_API_KEY"
          )
        end
        reference_id = BetterAuth::APIKey::Types.record_reference_id(record)
        user = ctx.context.internal_adapter.find_user_by_id(reference_id)
        unless user
          raise BetterAuth::APIError.new(
            "UNAUTHORIZED",
            message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_REFERENCE_ID_FROM_API_KEY"],
            code: "INVALID_REFERENCE_ID_FROM_API_KEY"
          )
        end

        session = {
          user: user,
          session: {
            "id" => record["id"],
            "token" => key,
            "userId" => reference_id,
            "userAgent" => ctx.request ? BetterAuth::RequestIP.header_value(ctx.request, "user-agent") : nil,
            "ipAddress" => ctx.request ? BetterAuth::RequestIP.client_ip(ctx.request, ctx.context.options) : nil,
            "createdAt" => Time.now,
            "updatedAt" => Time.now,
            "expiresAt" => record["expiresAt"] || (Time.now + ctx.context.options.session[:expires_in].to_i)
          }
        }
        ctx.context.set_current_session(session)
        session if ctx.path == "/get-session"
      end
    end
  end
end
