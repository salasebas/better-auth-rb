# frozen_string_literal: true

module BetterAuth
  module SSO
    module SAMLState
      module_function

      def generate_relay_state(ctx, link = nil, additional_data = {})
        callback_url = BetterAuth::Plugins.sso_fetch(ctx.body, :callback_url)
        raise BetterAuth::APIError.new("BAD_REQUEST", message: "callbackURL is required") if callback_url.to_s.empty?

        payload = (additional_data || {}).transform_keys(&:to_s)
        optional = {
          "errorURL" => BetterAuth::Plugins.sso_fetch(ctx.body, :error_callback_url),
          "newUserURL" => BetterAuth::Plugins.sso_fetch(ctx.body, :new_user_callback_url),
          "requestSignUp" => BetterAuth::Plugins.sso_fetch(ctx.body, :request_sign_up),
          "link" => link
        }
        payload = payload.except(*optional.keys).merge(optional.compact)
        payload["callbackURL"] = callback_url
        payload["codeVerifier"] = BetterAuth::Crypto.random_string(128)
        payload["expiresAt"] = (Time.now.to_r * 1000).floor + 600_000
        BetterAuth::OAuthState.generate(ctx, payload, "relay_state")
      end

      def parse_relay_state(ctx)
        state = BetterAuth::Plugins.sso_fetch(ctx.body, :relay_state)
        data = begin
          BetterAuth::OAuthState.parse_generic(ctx, state, cookie_name: "relay_state", skip_state_cookie_check: true)
        rescue
          raise BetterAuth::APIError.new("BAD_REQUEST", message: "State error: failed to validate relay state")
        end
        if data["errorURL"].to_s.empty?
          data["errorURL"] = ctx.context.options.on_api_error[:error_url] || "#{ctx.context.base_url}/error"
        end
        data
      end
    end
  end
end
