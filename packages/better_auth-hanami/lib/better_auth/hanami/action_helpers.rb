# frozen_string_literal: true

module BetterAuth
  module Hanami
    module ActionHelpers
      def current_session(request)
        data = better_auth_session_data(request)
        data&.fetch(:session, nil) || data&.fetch("session", nil)
      end

      def current_user(request)
        data = better_auth_session_data(request)
        data&.fetch(:user, nil) || data&.fetch("user", nil)
      end

      def authenticated?(request)
        !current_user(request).nil?
      end

      def require_authentication(request, response)
        return true if authenticated?(request)

        apply_better_auth_session_headers(request, response)
        response.status = 401 if response.respond_to?(:status=)
        false
      end

      private

      def better_auth_session_data(request)
        env = request_env(request)
        return env["better_auth.session"] if env.key?("better_auth.session")

        env["better_auth.session"] = resolve_better_auth_session(request)
      end

      def resolve_better_auth_session(request)
        auth = BetterAuth::Hanami.auth
        auth.context.prepare_for_request!(request) if auth.context.respond_to?(:prepare_for_request!)
        endpoint = auth.api.endpoints.fetch(:get_session)
        endpoint_context = BetterAuth::Endpoint::Context.new(
          path: endpoint.path,
          method: "GET",
          query: {"disableRefresh" => "true"},
          body: {},
          params: {},
          headers: request_headers(request),
          context: auth.context,
          request: request
        )
        result = auth.api.execute(endpoint, endpoint_context)
        request_env(request)["better_auth.session_headers"] = result.headers || {}
        session = result.response
        return nil unless session
        return nil if session.is_a?(BetterAuth::APIError)

        {session: session["session"] || session[:session], user: session["user"] || session[:user]}
      rescue BetterAuth::APIError
        nil
      ensure
        auth.context.clear_runtime! if defined?(auth) && auth.context.respond_to?(:clear_runtime!)
      end

      def request_env(request)
        request.respond_to?(:env) ? request.env : {}
      end

      def request_path(request)
        request.respond_to?(:path) ? request.path : "/"
      end

      def request_method(request)
        request.respond_to?(:request_method) ? request.request_method : "GET"
      end

      def request_params(request)
        request.respond_to?(:params) ? request.params : {}
      end

      def request_cookie(request)
        return request.get_header("HTTP_COOKIE") if request.respond_to?(:get_header)

        headers = request.respond_to?(:headers) ? request.headers : {}
        headers["cookie"] || headers["Cookie"]
      end

      def request_authorization(request)
        return request.get_header("HTTP_AUTHORIZATION") if request.respond_to?(:get_header)

        headers = request.respond_to?(:headers) ? request.headers : {}
        headers["authorization"] || headers["Authorization"]
      end

      def request_headers(request)
        headers = headers_from_env(request_env(request))
        cookie = request_cookie(request)
        authorization = request_authorization(request)
        headers["cookie"] = cookie if cookie
        headers["authorization"] = authorization if authorization
        if request.respond_to?(:headers)
          request.headers.each { |key, value| headers[key.to_s] ||= value }
        end
        headers
      end

      def headers_from_env(env)
        env.each_with_object({}) do |(key, value), headers|
          case key
          when "CONTENT_TYPE"
            headers["content-type"] = value if value
          when "CONTENT_LENGTH"
            headers["content-length"] = value if value
          else
            next unless key.start_with?("HTTP_")

            headers[key.delete_prefix("HTTP_").downcase.tr("_", "-")] = value
          end
        end
      end

      def apply_better_auth_session_headers(request, response)
        headers = request_env(request)["better_auth.session_headers"]
        return unless headers && headers["set-cookie"]

        if response.respond_to?(:headers) && response.headers.respond_to?(:[]=)
          existing = response.headers["set-cookie"]
          response.headers["set-cookie"] = [existing, headers["set-cookie"]].compact.join("\n")
        elsif response.respond_to?(:[]=)
          response["set-cookie"] = headers["set-cookie"]
        end
      end
    end
  end
end
