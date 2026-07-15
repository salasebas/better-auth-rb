# frozen_string_literal: true

require "uri"
require "time"

module BetterAuth
  module Plugins
    module_function

    SIWE_WALLET_PATTERN = /\A0[xX][a-fA-F0-9]{40}\z/
    SIWE_EMAIL_PATTERN = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    SIWE_HEADER_PATTERN = /\A(?:([a-zA-Z][a-zA-Z0-9+.-]*):\/\/)?(\S+) wants you to sign in with your Ethereum account:\z/
    SIWE_FIELD_PATTERN = /\A([A-Za-z ]+): (.*)\z/

    def siwe(options = {})
      config = normalize_hash(options)

      Plugin.new(
        id: "siwe",
        schema: siwe_schema(config[:schema]),
        endpoints: {
          get_siwe_nonce: get_siwe_nonce_endpoint(config, path: "/siwe/nonce", operation_id: "getSiweNonce"),
          get_nonce: get_siwe_nonce_endpoint(config, path: "/siwe/get-nonce", operation_id: "getNonce"),
          verify_siwe_message: verify_siwe_message_endpoint(config)
        },
        options: config
      )
    end

    def get_siwe_nonce_endpoint(config, path:, operation_id:)
      Endpoint.new(
        path: path,
        method: "POST",
        body_schema: ->(body) { siwe_nonce_body(body) },
        metadata: {
          openapi: {
            operationId: operation_id,
            description: "Generate a nonce for Sign-In with Ethereum",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  address: {type: "string"},
                  walletAddress: {type: "string"},
                  chainId: {type: ["number", "string", "null"]}
                }
              )
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "SIWE nonce",
                OpenAPI.object_schema(
                  {
                    nonce: {type: "string"}
                  },
                  required: ["nonce"]
                )
              )
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        wallet_address = siwe_normalize_wallet!(body[:wallet_address] || body[:address])
        chain_id = siwe_chain_id(body[:chain_id])
        nonce_callback = config[:get_nonce]
        raise APIError.new("INTERNAL_SERVER_ERROR", message: "SIWE nonce callback is required") unless nonce_callback.respond_to?(:call)

        nonce = nonce_callback.call.to_s
        ctx.context.internal_adapter.create_verification_value(
          identifier: siwe_identifier(wallet_address, chain_id),
          value: nonce,
          expiresAt: Time.now + (15 * 60)
        )
        ctx.json({nonce: nonce})
      end
    end

    def verify_siwe_message_endpoint(config)
      Endpoint.new(
        path: "/siwe/verify",
        method: "POST",
        body_schema: ->(body) { siwe_verify_body(body, config) },
        metadata: {
          openapi: {
            operationId: "verifySiweMessage",
            description: "Verify a Sign-In with Ethereum message",
            requestBody: OpenAPI.json_request_body(
              OpenAPI.object_schema(
                {
                  walletAddress: {type: "string"},
                  chainId: {type: ["number", "string", "null"]},
                  message: {type: "string"},
                  signature: {type: "string"},
                  email: {type: ["string", "null"]}
                },
                required: ["walletAddress", "message", "signature"]
              )
            ),
            responses: {
              "200" => OpenAPI.json_response(
                "SIWE message verified",
                OpenAPI.object_schema(
                  {
                    token: {type: "string"},
                    success: {type: "boolean"},
                    user: {type: "object"}
                  },
                  required: ["token", "success", "user"]
                )
              )
            }
          }
        }
      ) do |ctx|
        body = normalize_hash(ctx.body)
        wallet_address = siwe_normalize_wallet!(body[:wallet_address])
        chain_id = siwe_chain_id(body[:chain_id])
        email = body[:email].to_s.downcase
        anonymous = config.key?(:anonymous) ? config[:anonymous] : true
        raise APIError.new("BAD_REQUEST", message: "Email is required when anonymous is disabled.") if anonymous == false && email.empty?
        raise APIError.new("BAD_REQUEST", message: "Invalid email address") if !email.empty? && !SIWE_EMAIL_PATTERN.match?(email)

        verification = ctx.context.internal_adapter.consume_verification_value(siwe_identifier(wallet_address, chain_id))
        unless verification
          raise APIError.new("UNAUTHORIZED_INVALID_OR_EXPIRED_NONCE", message: "Unauthorized: Invalid or expired nonce")
        end

        siwe_validate_message!(body[:message], config[:domain], wallet_address, chain_id, verification["value"])

        verified = siwe_verify_message(config, body, wallet_address, chain_id, verification["value"], ctx)
        raise APIError.new("UNAUTHORIZED", message: "Unauthorized: Invalid SIWE signature") unless verified

        user = siwe_find_user(ctx, wallet_address, chain_id)
        user ||= siwe_create_user(ctx, config, wallet_address, chain_id, email, anonymous)
        siwe_ensure_wallet_and_account(ctx, user, wallet_address, chain_id)
        session = ctx.context.internal_adapter.create_session(user["id"])
        session_data = {session: session, user: user}
        Cookies.set_session_cookie(ctx, session_data)

        ctx.json({
          token: session["token"],
          success: true,
          user: {
            id: user["id"],
            walletAddress: wallet_address,
            chainId: chain_id
          }
        })
      rescue APIError
        raise
      rescue
        raise APIError.new("UNAUTHORIZED", message: "Something went wrong. Please try again later.")
      end
    end

    def siwe_schema(custom_schema = nil)
      base = {
        "walletAddress" => {
          fields: {
            userId: {type: "string", references: {model: "user", field: "id"}, required: true, index: true},
            address: {type: "string", required: true},
            chainId: {type: "number", required: true},
            isPrimary: {type: "boolean", default_value: false},
            createdAt: {type: "date", required: true}
          }
        }
      }
      return base unless custom_schema.is_a?(Hash)

      normalize_hash(custom_schema).each_with_object(base) do |(raw_model, table), result|
        model = Schema.storage_key(raw_model)
        current = result[model] || {}
        custom_table = normalize_hash(table)
        fields = siwe_merge_schema_fields(current[:fields] || current["fields"] || {}, custom_table.delete(:fields) || {})
        result[model] = current.merge(custom_table).merge(fields: fields)
      end
    end

    def siwe_merge_schema_fields(base_fields, custom_fields)
      fields = base_fields.each_with_object({}) do |(raw_field, attributes), result|
        result[Schema.storage_key(raw_field)] = normalize_hash(attributes)
      end

      normalize_hash(custom_fields).each do |raw_field, value|
        field = Schema.storage_key(raw_field)
        custom_attributes = (value.is_a?(String) || value.is_a?(Symbol)) ? {field_name: value.to_s} : normalize_hash(value)
        fields[field] = (fields[field] || {}).merge(custom_attributes)
      end

      fields
    end

    def siwe_nonce_body(body)
      data = normalize_hash(body)
      wallet_address = data[:wallet_address] || data[:address]
      if wallet_address.to_s.empty?
        raise APIError.new("BAD_REQUEST", message: "walletAddress or address is required")
      end

      siwe_normalize_wallet!(wallet_address)
      data[:chain_id] = siwe_chain_id(data[:chain_id])
      data
    end

    def siwe_verify_body(body, config)
      data = normalize_hash(body)
      raise APIError.new("BAD_REQUEST", message: "message is required") if data[:message].to_s.empty?
      raise APIError.new("BAD_REQUEST", message: "signature is required") if data[:signature].to_s.empty?

      siwe_normalize_wallet!(data[:wallet_address])
      data[:chain_id] = siwe_chain_id(data[:chain_id])
      anonymous = config.key?(:anonymous) ? config[:anonymous] : true
      email = data[:email].to_s.downcase
      raise APIError.new("BAD_REQUEST", message: "Email is required when anonymous is disabled.") if anonymous == false && email.empty?
      raise APIError.new("BAD_REQUEST", message: "Invalid email address") if !email.empty? && !SIWE_EMAIL_PATTERN.match?(email)

      data[:email] = email unless email.empty?
      data
    end

    def siwe_normalize_wallet!(value)
      wallet = value.to_s
      raise APIError.new("BAD_REQUEST", message: "Invalid walletAddress") unless SIWE_WALLET_PATTERN.match?(wallet)

      Crypto.to_checksum_address(wallet)
    end

    def siwe_chain_id(value)
      chain_id = (value.nil? || value.to_s.empty?) ? 1 : value.to_i
      raise APIError.new("BAD_REQUEST", message: "Invalid chainId") unless chain_id.positive? && chain_id <= 2_147_483_647

      chain_id
    end

    def siwe_identifier(wallet_address, chain_id)
      "siwe:#{wallet_address}:#{chain_id}"
    end

    def siwe_parse_message(message)
      result = {}
      lines = message.to_s.split(/\r?\n/)

      if (header = SIWE_HEADER_PATTERN.match(lines[0].to_s))
        result[:scheme] = header[1] if header[1]
        result[:domain] = header[2]
      end

      address = lines[1].to_s.strip
      result[:address] = address if SIWE_WALLET_PATTERN.match?(address)

      lines.each do |line|
        field = SIWE_FIELD_PATTERN.match(line)
        next unless field

        key = field[1]
        value = field[2]
        case key
        when "URI"
          result[:uri] = value
        when "Version"
          result[:version] = value
        when "Chain ID"
          parsed_chain_id = siwe_parse_message_chain_id(value)
          result[:chain_id] = parsed_chain_id unless parsed_chain_id.nil?
        when "Nonce"
          result[:nonce] = value
        when "Issued At"
          result[:issued_at] = value
        when "Expiration Time"
          result[:expiration_time] = value
        when "Not Before"
          result[:not_before] = value
        when "Request ID"
          result[:request_id] = value
        end
      end

      result
    rescue
      {}
    end

    def siwe_parse_message_chain_id(value)
      number = Float(value)
      number.to_i if number.finite? && number == number.to_i
    rescue ArgumentError, TypeError, RangeError
      nil
    end

    def siwe_normalize_domain(domain)
      normalized = domain.to_s.strip.downcase.sub(/\A[a-z][a-z0-9+.-]*:\/\//, "")
      path_start = normalized.index("/")
      path_start ? normalized[0...path_start] : normalized
    rescue
      ""
    end

    def siwe_validate_message!(message, domain, wallet_address, chain_id, nonce)
      parsed = siwe_parse_message(message)
      matches = parsed[:nonce] == nonce &&
        parsed[:address]&.downcase == wallet_address.downcase &&
        parsed[:chain_id] == chain_id &&
        parsed[:domain] && siwe_normalize_domain(parsed[:domain]) == siwe_normalize_domain(domain)

      unless matches
        raise siwe_unauthorized_error(
          "UNAUTHORIZED_SIWE_MESSAGE_MISMATCH",
          "Unauthorized: SIWE message does not match the expected nonce, domain, address, or chain ID"
        )
      end

      now = Time.now
      expiration_time = siwe_parse_message_time(parsed[:expiration_time]) if parsed[:expiration_time]
      if expiration_time && now >= expiration_time
        raise siwe_unauthorized_error("UNAUTHORIZED_SIWE_MESSAGE_EXPIRED", "Unauthorized: SIWE message has expired")
      end

      not_before = siwe_parse_message_time(parsed[:not_before]) if parsed[:not_before]
      if not_before && now < not_before
        raise siwe_unauthorized_error("UNAUTHORIZED_SIWE_MESSAGE_NOT_YET_VALID", "Unauthorized: SIWE message is not yet valid")
      end
    end

    def siwe_parse_message_time(value)
      Time.parse(value.to_s)
    rescue ArgumentError, TypeError, RangeError
      nil
    end

    def siwe_unauthorized_error(status, message)
      APIError.new("UNAUTHORIZED", code: status, message: message)
    end

    def siwe_verify_message(config, body, wallet_address, chain_id, nonce, ctx)
      verifier = config[:verify_message]
      raise APIError.new("INTERNAL_SERVER_ERROR", message: "SIWE verify_message callback is required") unless verifier.respond_to?(:call)

      verifier.call(
        message: body[:message].to_s,
        signature: body[:signature].to_s,
        address: wallet_address,
        chain_id: chain_id,
        cacao: {
          h: {t: "caip122"},
          p: {
            domain: config[:domain],
            aud: config[:domain],
            nonce: nonce,
            iss: config[:domain],
            version: "1"
          },
          s: {t: "eip191", s: body[:signature].to_s}
        }
      )
    end

    def siwe_find_user(ctx, wallet_address, chain_id)
      existing = ctx.context.adapter.find_one(
        model: "walletAddress",
        where: [
          {field: "address", value: wallet_address},
          {field: "chainId", value: chain_id}
        ]
      )
      existing ||= ctx.context.adapter.find_one(model: "walletAddress", where: [{field: "address", value: wallet_address}])
      existing && ctx.context.internal_adapter.find_user_by_id(existing["userId"])
    end

    def siwe_create_user(ctx, config, wallet_address, _chain_id, email, anonymous)
      domain = config[:email_domain_name] || URI.parse(ctx.context.canonical_base_url).host || ctx.context.canonical_base_url
      lookup = config[:ens_lookup]
      ens = lookup.respond_to?(:call) ? normalize_hash(lookup.call(wallet_address: wallet_address) || {}) : {}
      normalized_email = email.to_s.downcase
      user_email = "#{wallet_address}@#{domain}".downcase
      if anonymous == false && !normalized_email.empty? && !ctx.context.internal_adapter.find_user_by_email(normalized_email)
        user_email = normalized_email
      end
      ctx.context.internal_adapter.create_user(
        name: ens[:name] || wallet_address,
        email: user_email,
        image: ens[:avatar] || "",
        context: ctx
      )
    end

    def siwe_ensure_wallet_and_account(ctx, user, wallet_address, chain_id)
      exact = ctx.context.adapter.find_one(
        model: "walletAddress",
        where: [
          {field: "address", value: wallet_address},
          {field: "chainId", value: chain_id}
        ]
      )
      return if exact

      any_wallet = ctx.context.adapter.find_one(model: "walletAddress", where: [{field: "address", value: wallet_address}])
      ctx.context.adapter.create(
        model: "walletAddress",
        data: {
          userId: user["id"],
          address: wallet_address,
          chainId: chain_id,
          isPrimary: any_wallet.nil?,
          createdAt: Time.now
        }
      )
      ctx.context.internal_adapter.create_account(
        userId: user["id"],
        providerId: "siwe",
        accountId: "#{wallet_address}:#{chain_id}"
      )
    end

    def siwe_expired_time?(value)
      value && value < Time.now
    end
  end
end
