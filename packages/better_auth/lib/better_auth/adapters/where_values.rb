# frozen_string_literal: true

module BetterAuth
  module Adapters
    module WhereValues
      private

      def require_where_array!(value)
        raise Error, "Value must be an array" unless value.is_a?(Array)
      end

      def normalize_where_value(value, attributes)
        case attributes[:type]
        when "boolean"
          value.is_a?(String) ? value == "true" : value
        when "number"
          if value.is_a?(Array)
            numbers = value.map { |entry| parse_where_number(entry) }
            numbers.include?(nil) ? value : numbers
          else
            parse_where_number(value) || value
          end
        else
          value
        end
      end

      def parse_where_number(value)
        return unless value.is_a?(String)

        string = value.encode(Encoding::UTF_8)
        return unless string.valid_encoding?

        string = string.gsub(/\A[\p{Zs}\t\n\v\f\r\u2028\u2029\uFEFF]+|[\p{Zs}\t\n\v\f\r\u2028\u2029\uFEFF]+\z/, "")
        number = case string
        when "Infinity", "+Infinity" then Float::INFINITY
        when "-Infinity" then -Float::INFINITY
        when /\A0(?:[xX][\da-fA-F]+|[bB][01]+|[oO][0-7]+)\z/ then Integer(string, 0).to_f
        when /\A[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?\z/
          string.sub(/\.(?=[eE]|\z)/, ".0").to_f
        end
        return number.to_i if number&.finite? && number == number.to_i

        number
      rescue EncodingError
        nil
      end
    end
  end
end
