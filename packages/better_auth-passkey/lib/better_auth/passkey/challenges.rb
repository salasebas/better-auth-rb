# frozen_string_literal: true

require "json"

module BetterAuth
  module Passkey
    module Challenges
      CHALLENGE_MAX_AGE = 60 * 5

      module_function

      def challenge_context(ctx)
        body = ctx.respond_to?(:body) ? BetterAuth::Passkey::Utils.normalize_hash(ctx.body) : {}
        query = ctx.respond_to?(:query) ? BetterAuth::Passkey::Utils.normalize_hash(ctx.query) : {}
        body.merge(query)[:context]
      end

      def store_challenge(ctx, config, challenge, user_id)
        user_data = user_id.is_a?(Hash) ? user_id : {id: user_id}
        verification_token = Crypto.random_string(32)
        cookie = challenge_cookie(ctx, config)
        ctx.set_signed_cookie(cookie.name, verification_token, ctx.context.secret, cookie.attributes.merge(max_age: CHALLENGE_MAX_AGE))
        ctx.context.internal_adapter.create_verification_value(
          identifier: verification_token,
          value: JSON.generate({
            expectedChallenge: challenge,
            userData: user_data,
            context: challenge_context(ctx)
          }),
          expiresAt: Time.now + CHALLENGE_MAX_AGE
        )
      end

      def find_challenge(ctx, verification_token)
        verification = ctx.context.internal_adapter.find_verification_value(verification_token)
        return nil if verification.nil? || BetterAuth::Routes.expired_time?(verification["expiresAt"] || verification[:expiresAt])

        JSON.parse(verification.fetch("value") { verification.fetch(:value) })
      rescue JSON::ParserError
        nil
      end

      def challenge_token(ctx, config)
        ctx.get_signed_cookie(challenge_cookie(ctx, config).name, ctx.context.secret)
      end

      def challenge_cookie(ctx, config)
        ctx.context.create_auth_cookie(config.dig(:advanced, :web_authn_challenge_cookie), max_age: CHALLENGE_MAX_AGE)
      end
    end
  end
end
