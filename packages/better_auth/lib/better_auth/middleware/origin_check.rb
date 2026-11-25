# frozen_string_literal: true

module BetterAuth
  module Middleware
    class OriginCheck
      DEPRECATION_WARNING = "[Deprecation] disableOriginCheck: true currently also disables CSRF checks. In a future version, disableOriginCheck will ONLY disable URL validation. To keep CSRF disabled, add disableCSRFCheck: true to your config."
      CALLBACK_FIELDS = {
        "callbackURL" => ["callbackURL", "INVALID_CALLBACK_URL"],
        "redirectTo" => ["redirectURL", "INVALID_REDIRECT_URL"],
        "errorCallbackURL" => ["errorCallbackURL", "INVALID_ERROR_CALLBACK_URL"],
        "newUserCallbackURL" => ["newUserCallbackURL", "INVALID_NEW_USER_CALLBACK_URL"]
      }.freeze

      def self.form_csrf
        new(warn_backward_compat: false).method(:call_form_csrf)
      end

      def self.callback(&get_value)
        new(warn_backward_compat: false).callback_check(&get_value)
      end

      def callback_check
        ->(ctx) {
          next unless ctx.request
          next if skip_origin_check?(ctx)

          value = yield(ctx)
          callbacks = value.is_a?(Array) ? value : [value]
          callbacks.each { |url| validate_url(ctx, url, "callbackURL", "INVALID_CALLBACK_URL") }
          nil
        }
      end

      def initialize(warn_backward_compat: true)
        @warned_backward_compat = false
        @warn_backward_compat = warn_backward_compat
      end

      def call(endpoint_context)
        return unless endpoint_context.request
        return if %w[GET OPTIONS HEAD].include?(endpoint_context.method)

        validate_origin(endpoint_context)
        return if skip_origin_check?(endpoint_context)

        validate_callback_urls(endpoint_context)
        nil
      rescue APIError => error
        Endpoint::Result.new(response: error.to_h, status: error.status_code, headers: error.headers).to_rack_response
      end

      def call_form_csrf(endpoint_context)
        return unless endpoint_context.request

        validate_fetch_metadata(endpoint_context)
        nil
      end

      private

      def validate_origin(endpoint_context, force: false)
        return if skip_csrf_check?(endpoint_context)
        return if skip_csrf_for_backward_compat?(endpoint_context)
        return if skip_origin_check?(endpoint_context)

        headers = endpoint_context.headers
        should_validate = force || headers.key?("cookie")
        return unless should_validate

        origin = origin_header(headers)
        reject!("MISSING_OR_NULL_ORIGIN") if origin.nil? || origin == "null"
        validate_url(endpoint_context, origin, "origin", "INVALID_ORIGIN")
      end

      def validate_fetch_metadata(endpoint_context)
        return if skip_csrf_check?(endpoint_context)
        return if skip_csrf_for_backward_compat?(endpoint_context)

        headers = endpoint_context.headers
        return validate_origin(endpoint_context) if headers.key?("cookie")

        site = headers["sec-fetch-site"]
        mode = headers["sec-fetch-mode"]
        dest = headers["sec-fetch-dest"]
        has_metadata = [site, mode, dest].any? { |value| value && !value.to_s.strip.empty? }
        if site == "cross-site" && mode == "navigate"
          log(endpoint_context.context, :error, "Blocked cross-site navigation login attempt (CSRF protection)")
          reject!("CROSS_SITE_NAVIGATION_LOGIN_BLOCKED")
        end

        validate_origin(endpoint_context, force: true) if has_metadata || origin_header(headers)
      end

      def validate_callback_urls(endpoint_context)
        body = endpoint_context.body
        normalized_body = Routes.request_validation_hash(body)

        CALLBACK_FIELDS.each do |key, (label, code)|
          value = fetch_data(body, key)
          value = fetch_data(endpoint_context.query, key) if key == "callbackURL" && blank_value?(value)
          validate_url(endpoint_context, value, label, code)

          normalized_value = normalized_body[Schema.storage_key(key)]
          validate_url(endpoint_context, normalized_value, label, code) unless normalized_value == value
        end
      end

      def validate_url(endpoint_context, value, label, code)
        return if blank_value?(value)
        unless value.is_a?(String)
          raise APIError.new("BAD_REQUEST", message: "Invalid #{label}: expected a string")
        end
        return if endpoint_context.context.trusted_origin?(value, allow_relative_paths: label != "origin")

        log(endpoint_context.context, :error, "Invalid #{label}: #{value}")
        reject!(code)
      end

      def reject!(code)
        raise APIError.new("FORBIDDEN", code: code, message: BASE_ERROR_CODES.fetch(code))
      end

      def blank_value?(value)
        value.nil? || value == false || value == "" || (value.is_a?(Numeric) && value.zero?)
      end

      def origin_header(headers)
        [headers["origin"], headers["referer"]].find { |value| !value.to_s.empty? }
      end

      def skip_csrf_check?(endpoint_context)
        endpoint_context.context.options.advanced[:disable_csrf_check] == true
      end

      def skip_csrf_for_backward_compat?(endpoint_context)
        advanced = endpoint_context.context.options.advanced
        return false unless endpoint_context.context.skip_origin_check == true
        return false if advanced.key?(:disable_csrf_check)

        if @warn_backward_compat && !@warned_backward_compat && advanced[:disable_origin_check] == true
          log(endpoint_context.context, :warn, DEPRECATION_WARNING)
          @warned_backward_compat = true
        end
        true
      end

      def skip_origin_check?(endpoint_context)
        skip = endpoint_context.context.skip_origin_check
        return true if skip == true
        return false unless skip.is_a?(Array) && endpoint_context.request

        request_url = URLHelpers.source_url(endpoint_context.request)
        return false unless request_url

        path = URI.parse(request_url).path.to_s
        base_path = URI.parse(endpoint_context.context.base_url).path.to_s.sub(%r{/+\z}, "")
        path = path.delete_prefix(base_path) if path == base_path || path.start_with?("#{base_path}/")
        skip.any? { |prefix| PathMatcher.literal_subtree_matches?(prefix, path) }
      rescue URI::InvalidURIError
        false
      end

      def fetch_data(data, key)
        return unless data.is_a?(Hash)

        data[key] || data[key.to_sym]
      end

      def log(context, level, message)
        logger = context.logger
        if logger.respond_to?(:call)
          logger.call(level, message)
        elsif logger.respond_to?(level)
          logger.public_send(level, message)
        end
      end
    end
  end
end
