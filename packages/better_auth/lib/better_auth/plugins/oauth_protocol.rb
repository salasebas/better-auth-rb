# frozen_string_literal: true

require "uri"

module BetterAuth
  module Plugins
    module OAuthProtocol
      DEVICE_CODE_GRANT = "urn:ietf:params:oauth:grant-type:device_code"

      module_function

      def endpoint_base(ctx)
        ctx.context.canonical_base_url
      end

      def redirect_uri_with_params(uri, params)
        parsed = URI.parse(uri.to_s)
        existing = URI.decode_www_form(parsed.query.to_s)
        params.each { |key, value| existing << [key.to_s, value.to_s] unless value.nil? }
        parsed.query = URI.encode_www_form(existing)
        parsed.to_s
      end

      def stringify_keys(value)
        return value.each_with_object({}) { |(key, object_value), result| result[key.to_s] = stringify_keys(object_value) } if value.is_a?(Hash)
        return value.map { |entry| stringify_keys(entry) } if value.is_a?(Array)

        value
      end
    end
  end
end
