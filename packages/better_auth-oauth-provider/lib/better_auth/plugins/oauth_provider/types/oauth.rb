# frozen_string_literal: true

module BetterAuth
  module Plugins
    module OAuthProvider
      module Types
        module OAuth
          AUTHORIZATION_CODE_GRANT = ::BetterAuth::Plugins::OAuthProtocol::AUTH_CODE_GRANT
          REFRESH_TOKEN_GRANT = ::BetterAuth::Plugins::OAuthProtocol::REFRESH_GRANT
          CLIENT_CREDENTIALS_GRANT = ::BetterAuth::Plugins::OAuthProtocol::CLIENT_CREDENTIALS_GRANT

          GRANT_TYPES = [
            AUTHORIZATION_CODE_GRANT,
            REFRESH_TOKEN_GRANT,
            CLIENT_CREDENTIALS_GRANT
          ].freeze

          RESPONSE_TYPES = ["code"].freeze
          TOKEN_ENDPOINT_AUTH_METHODS = ["client_secret_basic", "client_secret_post", "none"].freeze
          CLIENT_TYPES = ["web", "native", "user-agent-based"].freeze
          SUBJECT_TYPES = ["public", "pairwise"].freeze
          PROMPTS = ["login", "consent", "create", "select_account", "none"].freeze
          OIDC_SCOPES = ["openid", "profile", "email", "phone", "address"].freeze
        end
      end
    end
  end
end
