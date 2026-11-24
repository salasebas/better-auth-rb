# frozen_string_literal: true

require "json"
require "time"

module BetterAuth
  module APIKey
    module Utils
      module_function

      def encode_json(value)
        return nil if value.nil?

        JSON.generate(value)
      end

      def decode_json(value)
        return nil if value.nil?
        return value if value.is_a?(Hash)

        parsed = JSON.parse(value.to_s)
        parsed.is_a?(String) ? decode_json(parsed) : parsed
      rescue JSON::ParserError
        nil
      end

      def normalize_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil?

        Time.parse(value.to_s)
      rescue ArgumentError
        nil
      end

      def public_record(record, reveal_key: nil, include_key_field: false)
        data = record.transform_keys(&:to_sym)
        output = data.except(:key)
        output[:configId] ||= BetterAuth::APIKey::Types.record_config_id(record)
        output[:referenceId] ||= BetterAuth::APIKey::Types.record_reference_id(record)
        output[:key] = reveal_key if include_key_field && reveal_key
        output[:metadata] = decode_json(data[:metadata])
        output[:permissions] = decode_json(data[:permissions])
        output
      end

      def sort_records(records, sort_by, direction)
        return records unless sort_by

        key = BetterAuth::Schema.storage_key(sort_by)
        sorted = records.sort_by { |record| record[key] || record[key.to_sym] || "" }
        if direction.to_s.downcase == "desc"
          sorted.reverse
        else
          sorted
        end
      end

      def validate_list_query!(query)
        %i[limit offset].each do |key|
          next unless query.key?(key)

          value = query[key]
          raise BetterAuth::APIError.new("BAD_REQUEST", message: "Invalid #{key}") unless value.to_s.match?(/\A\d+\z/)
        end

        direction = query[:sort_direction]
        return if direction.nil? || %w[asc desc].include?(direction.to_s.downcase)

        raise BetterAuth::APIError.new("BAD_REQUEST", message: "Invalid sortDirection")
      end

      def error_code(error)
        BetterAuth::Plugins::API_KEY_ERROR_CODES.key(error.message) || error.code.to_s
      end

      def error_payload(error)
        payload = error.to_h
        return payload if payload.is_a?(Hash) && payload.key?(:details)

        {message: error.message, code: error_code(error)}
      end

      def background_tasks?(ctx)
        ctx.context.options.advanced.dig(:background_tasks, :handler).respond_to?(:call)
      end

      def run_background_task(ctx, label, task)
        wrapped = lambda do
          task.call
        rescue => error
          logger = ctx.context.logger if ctx.context.respond_to?(:logger)
          logger.error("[API KEY PLUGIN] #{label} failed: #{error.message}") if logger.respond_to?(:error)
        end
        ctx.context.run_in_background(wrapped)
      end

      def auth_required?(ctx)
        !!(ctx.request || (ctx.headers && !ctx.headers.empty?))
      end
    end
  end
end
