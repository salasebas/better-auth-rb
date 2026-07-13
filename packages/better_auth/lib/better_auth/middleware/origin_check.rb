# frozen_string_literal: true

module BetterAuth
  module Middleware
    class OriginCheck
      DEPRECATION_WARNING = "[Deprecation] disableOriginCheck: true currently also disables CSRF checks. In a future version, disableOriginCheck will ONLY disable URL validation. To keep CSRF disabled, add disableCSRFCheck: true to your config."

      def initialize
        @warned_backward_compat = false
      end

      def call(endpoint_context)
        return if %w[GET OPTIONS HEAD].include?(endpoint_context.method)

        validate_origin(endpoint_context)
        validate_fetch_metadata(endpoint_context)
        return if skip_origin_check?(endpoint_context) || skip_origin_path?(endpoint_context)

        validate_callback_urls(endpoint_context)
        nil
      rescue APIError => error
        Endpoint::Result.new(response: error.to_h, status: error.status_code, headers: error.headers).to_rack_response
      end

      private

      def validate_origin(endpoint_context, force: false)
        return if skip_csrf_check?(endpoint_context)
        return if skip_csrf_for_backward_compat?(endpoint_context)
        return if skip_origin_path?(endpoint_context)

        headers = endpoint_context.headers
        should_validate = force || headers.key?("cookie")
        return unless should_validate

        origin = headers["origin"] || headers["referer"] || ""
        if origin.empty? || origin == "null"
          raise APIError.new("FORBIDDEN", message: BASE_ERROR_CODES["MISSING_OR_NULL_ORIGIN"])
        end

        unless endpoint_context.context.trusted_origin?(origin)
          log(endpoint_context.context, :error, "Invalid origin: #{origin}")
          raise APIError.new("FORBIDDEN", message: "Invalid origin")
        end
      end

      def validate_fetch_metadata(endpoint_context)
        return if skip_csrf_check?(endpoint_context)
        return if skip_csrf_for_backward_compat?(endpoint_context)

        headers = endpoint_context.headers
        return if headers.key?("cookie")

        site = headers["sec-fetch-site"]
        mode = headers["sec-fetch-mode"]
        dest = headers["sec-fetch-dest"]
        has_metadata = [site, mode, dest].any? { |value| value && !value.to_s.strip.empty? }
        unless has_metadata
          origin = headers["origin"] || headers["referer"]
          validate_origin(endpoint_context, force: true) if login_or_signup_path?(endpoint_context.path) && origin && !origin.to_s.empty?
          return
        end

        if site == "cross-site" && mode == "navigate"
          log(endpoint_context.context, :error, "Blocked cross-site navigation login attempt (CSRF protection)")
          raise APIError.new("FORBIDDEN", message: BASE_ERROR_CODES["CROSS_SITE_NAVIGATION_LOGIN_BLOCKED"])
        end

        validate_origin(endpoint_context, force: true)
      end

      def validate_callback_urls(endpoint_context)
        {
          "callbackURL" => "callbackURL",
          "redirectTo" => "redirectURL",
          "errorCallbackURL" => "errorCallbackURL",
          "newUserCallbackURL" => "newUserCallbackURL"
        }.each do |key, label|
          value = fetch_data(endpoint_context.body, key) || fetch_data(endpoint_context.query, key)
          next if value.nil? || value == ""

          unless endpoint_context.context.trusted_origin?(value, allow_relative_paths: label != "origin")
            log(endpoint_context.context, :error, "Invalid #{label}: #{value}")
            raise APIError.new("FORBIDDEN", message: "Invalid #{label}")
          end
        end
      end

      def skip_csrf_check?(endpoint_context)
        endpoint_context.context.options.advanced[:disable_csrf_check] == true
      end

      def skip_origin_check?(endpoint_context)
        endpoint_context.context.options.advanced[:disable_origin_check] == true
      end

      def skip_csrf_for_backward_compat?(endpoint_context)
        advanced = endpoint_context.context.options.advanced
        return false unless advanced[:disable_origin_check] == true
        return false if advanced.key?(:disable_csrf_check)

        unless @warned_backward_compat
          log(endpoint_context.context, :warn, DEPRECATION_WARNING)
          @warned_backward_compat = true
        end
        true
      end

      def skip_origin_path?(endpoint_context)
        skip = endpoint_context.context.options.advanced[:disable_origin_check]
        return false unless skip.is_a?(Array)

        skip.any? { |path| endpoint_context.path.start_with?(path.to_s) }
      end

      def login_or_signup_path?(path)
        path.to_s.match?(%r{/(?:sign-in|sign-up)(?:/|$)})
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
