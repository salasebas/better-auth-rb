# frozen_string_literal: true

module BetterAuth
  module Plugins
    module OAuthProvider
      module Client
        ID = "oauth-provider-client"

        module_function

        def parse_signed_query(search)
          query = search.to_s.sub(/\A\?/, "")
          return nil if query.empty?

          pairs = URI.decode_www_form(query)
          return nil unless pairs.count { |key, _value| key == "sig" } == 1

          signed_names = pairs.each_with_object([]) { |pair, names| names << pair.last if pair.first == "ba_param" }
          return nil if signed_names.empty?

          signed_pairs = pairs.select do |key, _value|
            key == "sig" || key == "ba_param" || signed_names.include?(key)
          end
          URI.encode_www_form(signed_pairs)
        rescue ArgumentError
          nil
        end
      end
    end
  end
end
