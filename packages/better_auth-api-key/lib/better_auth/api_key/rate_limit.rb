# frozen_string_literal: true

module BetterAuth
  module APIKey
    module RateLimit
      module_function

      # Pure decision function used by the verifier before applying a guarded
      # counter mutation. Keeping the decision separate from the write avoids
      # persisting a stale snapshot when another verifier wins the race.
      def evaluate(record, config, now = Time.now)
        return {type: :skip, last_request: now} if config[:rate_limit][:enabled] == false
        return {type: :skip, last_request: now} if record["rateLimitEnabled"] == false

        window = record["rateLimitTimeWindow"]
        max = record["rateLimitMax"]
        return {type: :skip, last_request: nil} if window.nil? || max.nil?

        last = Utils.normalize_time(record["lastRequest"])
        return {type: :start, now: now} unless last

        elapsed_ms = (now - last) * 1000
        if elapsed_ms > window.to_i
          return {type: :reset, now: now, window_start: now - (window.to_i / 1000.0)}
        end

        if record["requestCount"].to_i >= max.to_i
          return {
            type: :deny,
            try_again_in: [(window.to_i - elapsed_ms).ceil, 0].max,
            message: BetterAuth::Plugins::API_KEY_ERROR_CODES["RATE_LIMIT_EXCEEDED"]
          }
        end

        {type: :increment, now: now, max: max.to_i, window_start: now - (window.to_i / 1000.0)}
      end

      def try_again_in(record, config, now)
        return nil if config[:rate_limit][:enabled] == false || record["rateLimitEnabled"] == false

        window = record["rateLimitTimeWindow"]
        max = record["rateLimitMax"]
        return nil if window.nil? || max.nil?

        last = Utils.normalize_time(record["lastRequest"])
        return nil unless last

        elapsed_ms = (now - last) * 1000
        return nil if elapsed_ms > window.to_i
        return nil if record["requestCount"].to_i < max.to_i

        (window.to_i - elapsed_ms).ceil
      end

      def counts_requests?(record, config)
        return false if config[:rate_limit][:enabled] == false || record["rateLimitEnabled"] == false

        !record["rateLimitTimeWindow"].nil? && !record["rateLimitMax"].nil?
      end

      def next_request_count(record, now)
        last = Utils.normalize_time(record["lastRequest"])
        window = record["rateLimitTimeWindow"].to_i
        return 1 unless last && window.positive?

        elapsed_ms = (now - last) * 1000
        (elapsed_ms <= window) ? record["requestCount"].to_i + 1 : 1
      end
    end
  end
end
