# frozen_string_literal: true

module BetterAuth
  class API
    attr_reader :context, :endpoints

    def initialize(context, endpoints)
      @context = context
      @endpoints = endpoints
      @dispatcher = EndpointDispatcher.new(context)
      define_endpoint_methods
    end

    def call_endpoint(key, input = {})
      RequestState.with_current do
        context.reset_runtime! if context.respond_to?(:reset_runtime!)
        endpoint = endpoints.fetch(key.to_sym)
        input = symbolize_keys(input || {})
        request = input[:request]
        headers = request_headers(request).merge(normalize_headers_hash(input[:headers] || {}))
        begin
          prepare_context_for_call!(request, headers)
        rescue APIError => error
          result = Endpoint::Result.new(response: error)
          return format_result(result, input)
        rescue Error => error
          api_error = APIError.new("INTERNAL_SERVER_ERROR", message: error.message)
          result = Endpoint::Result.new(response: api_error)
          return format_result(result, input)
        end
        input[:as_response] = true if request_like?(request) && !input.key?(:as_response)
        endpoint_context = Endpoint::Context.new(
          path: endpoint.path,
          method: input[:method] || request_method(request) || Array(endpoint.methods).first,
          query: input[:query] || {},
          body: input[:body] || {},
          params: input[:params] || {},
          headers: headers,
          context: context,
          request: request_like?(request) ? request : nil
        )

        @dispatcher.call(endpoint, endpoint_context, key: key) { |result| format_result(result, input) }
      ensure
        context.clear_runtime! if context.respond_to?(:clear_runtime!)
      end
    end

    def execute(endpoint, endpoint_context)
      @dispatcher.call(endpoint, endpoint_context)
    rescue APIError => error
      Endpoint::Result.new(response: error)
    end

    private

    def define_endpoint_methods
      endpoints.each_key do |key|
        method_name = normalize_method_name(key)
        define_singleton_method(method_name) do |input = {}|
          call_endpoint(key, input || {})
        end
      end
    end

    def normalize_method_name(key)
      key.to_s
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .tr("-", "_")
        .downcase
        .to_sym
    end

    def prepare_context_for_call!(request, headers)
      return unless context.respond_to?(:prepare_for_api_call!)

      context.prepare_for_api_call!(direct_call_source(request, headers))
    end

    def direct_call_source(request, headers)
      return request if request_like?(request)
      return headers if headers.key?("host") || headers.key?("x-forwarded-host")

      nil
    end

    def format_result(result, input)
      return result.to_response if result.raw_response?
      as_response = input[:as_response] || request_like?(input[:request])
      return result.to_response if as_response
      raise error_with_headers(result.response, result.headers) if result.response.is_a?(APIError)

      if input[:return_headers]
        output = {
          headers: result.headers,
          response: result.response
        }
        output[:status] = result.status if input[:return_status]
        return output
      end

      return {response: result.response, status: result.status} if input[:return_status]

      result.response
    end

    def error_with_headers(error, headers)
      APIError.new(
        error.status,
        message: error.message,
        headers: headers,
        code: error.code,
        body: error.body
      )
    end

    def request_like?(value)
      return false unless value

      value.respond_to?(:request_method) || request_method(value) || !request_headers(value).empty?
    end

    def request_method(request)
      return unless request
      return request.request_method if request.respond_to?(:request_method)

      request.public_send(:method)
    rescue ArgumentError, NoMethodError
      nil
    end

    def request_headers(request)
      return {} unless request

      if request.respond_to?(:env)
        return headers_from_env(request.env)
      end

      return normalize_headers_hash(request.headers) if request.respond_to?(:headers)

      {}
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

          header = key.delete_prefix("HTTP_").downcase.tr("_", "-")
          headers[header] = value
        end
      end
    end

    def normalize_headers_hash(headers)
      headers.each_with_object({}) do |(key, value), result|
        result[key.to_s.downcase.tr("_", "-")] = value
      end
    end

    def symbolize_keys(value)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, object_value), result|
        normalized_key = normalize_key(key)
        result[normalized_key] = object_value
      end
    end

    def normalize_key(key)
      key.to_s
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .tr("-", "_")
        .downcase
        .to_sym
    end
  end
end
