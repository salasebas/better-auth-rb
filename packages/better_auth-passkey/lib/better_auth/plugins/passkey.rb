# frozen_string_literal: true

module BetterAuth
  module Plugins
    singleton_class.remove_method(:passkey) if singleton_class.method_defined?(:passkey)
    remove_method(:passkey) if method_defined?(:passkey) || private_method_defined?(:passkey)

    module_function

    PASSKEY_ERROR_CODES = BetterAuth::Passkey::ErrorCodes::PASSKEY_ERROR_CODES
    PASSKEY_CHALLENGE_MAX_AGE = BetterAuth::Passkey::Challenges::CHALLENGE_MAX_AGE

    def passkey(options = {})
      config = {
        origin: nil,
        advanced: {
          web_authn_challenge_cookie: "better-auth-passkey"
        }
      }.merge(BetterAuth::Passkey::Utils.normalize_hash(options))
      config[:advanced] = {
        web_authn_challenge_cookie: "better-auth-passkey"
      }.merge(config[:advanced] || {})

      Plugin.new(
        id: "passkey",
        schema: passkey_schema(config[:schema]),
        endpoints: {
          generate_passkey_registration_options: generate_passkey_registration_options_endpoint(config),
          generate_passkey_authentication_options: generate_passkey_authentication_options_endpoint(config),
          verify_passkey_registration: verify_passkey_registration_endpoint(config),
          verify_passkey_authentication: verify_passkey_authentication_endpoint(config),
          list_passkeys: list_passkeys_endpoint,
          delete_passkey: delete_passkey_endpoint,
          update_passkey: update_passkey_endpoint
        },
        error_codes: PASSKEY_ERROR_CODES,
        options: config
      )
    end

    PASSKEY_PLUGIN_IMPLEMENTATION = true

    def generate_passkey_registration_options_endpoint(config)
      BetterAuth::Passkey::Routes::Registration.generate_passkey_registration_options_endpoint(config)
    end

    def verify_passkey_registration_endpoint(config)
      BetterAuth::Passkey::Routes::Registration.verify_passkey_registration_endpoint(config)
    end

    def generate_passkey_authentication_options_endpoint(config)
      BetterAuth::Passkey::Routes::Authentication.generate_passkey_authentication_options_endpoint(config)
    end

    def verify_passkey_authentication_endpoint(config)
      BetterAuth::Passkey::Routes::Authentication.verify_passkey_authentication_endpoint(config)
    end

    def list_passkeys_endpoint
      BetterAuth::Passkey::Routes::Management.list_passkeys_endpoint
    end

    def delete_passkey_endpoint
      BetterAuth::Passkey::Routes::Management.delete_passkey_endpoint
    end

    def update_passkey_endpoint
      BetterAuth::Passkey::Routes::Management.update_passkey_endpoint
    end

    def passkey_schema(custom_schema = nil)
      BetterAuth::Passkey::Schema.passkey_schema(custom_schema)
    end

    def passkey_store_challenge(ctx, config, challenge, user_id)
      BetterAuth::Passkey::Challenges.store_challenge(ctx, config, challenge, user_id)
    end

    def passkey_find_challenge(ctx, verification_token)
      BetterAuth::Passkey::Challenges.find_challenge(ctx, verification_token)
    end

    def passkey_challenge_token(ctx, config)
      BetterAuth::Passkey::Challenges.challenge_token(ctx, config)
    end

    def passkey_challenge_cookie(ctx, config)
      BetterAuth::Passkey::Challenges.challenge_cookie(ctx, config)
    end

    def passkey_relying_party(config, ctx, origin: nil)
      BetterAuth::Passkey::Utils.relying_party(config, ctx, origin: origin)
    end

    def passkey_origin(config, ctx)
      BetterAuth::Passkey::Utils.origin(config, ctx)
    end

    def passkey_allowed_origins(config, ctx, origin: nil)
      BetterAuth::Passkey::Utils.allowed_origins(config, ctx, origin: origin)
    end

    def passkey_rp_id(config, ctx)
      BetterAuth::Passkey::Utils.rp_id(config, ctx)
    end

    def passkey_authenticator_selection(config, query)
      BetterAuth::Passkey::Utils.authenticator_selection(config, query)
    end

    def passkey_validate_authenticator_attachment!(value)
      BetterAuth::Passkey::Utils.validate_authenticator_attachment!(value)
    end

    def passkey_require_key!(body, key)
      BetterAuth::Passkey::Utils.require_key!(body, key)
    end

    def passkey_require_string!(body, key)
      BetterAuth::Passkey::Utils.require_string!(body, key)
    end

    def passkey_resolve_registration_user(config, ctx, query)
      BetterAuth::Passkey::Utils.resolve_registration_user(config, ctx, query)
    end

    def passkey_registration_user_data(id:, name:, display_name: nil, email: nil)
      BetterAuth::Passkey::Utils.registration_user_data(id: id, name: name, display_name: display_name, email: email)
    end

    def passkey_resolve_extensions(extensions, ctx)
      BetterAuth::Passkey::Utils.resolve_extensions(extensions, ctx)
    end

    def passkey_after_registration_verification_user_id(config, ctx, credential, challenge, response, session)
      BetterAuth::Passkey::Utils.after_registration_verification_user_id(config, ctx, credential, challenge, response, session)
    end

    def passkey_call_callback(callback, data)
      BetterAuth::Passkey::Utils.call_callback(callback, data)
    end

    def passkey_webauthn_response(value)
      BetterAuth::Passkey::Credentials.webauthn_response(value)
    end

    def passkey_attestation_response(credential)
      BetterAuth::Passkey::Credentials.attestation_response(credential)
    end

    def passkey_authenticator_data(credential)
      BetterAuth::Passkey::Credentials.authenticator_data(credential)
    end

    def passkey_wire(record)
      BetterAuth::Passkey::Credentials.wire(record)
    end

    def passkey_credential_id(record)
      BetterAuth::Passkey::Credentials.credential_id(record)
    end

    def passkey_credential_descriptor(record, kind: :allow)
      BetterAuth::Passkey::Credentials.credential_descriptor(record, kind: kind)
    end

    def passkey_deep_merge_hashes(base, override)
      BetterAuth::Passkey::Schema.deep_merge_hashes(base, override)
    end
  end
end
