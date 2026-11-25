# frozen_string_literal: true

require "cgi"
require "json"
require "rack/request"
require "uri"

module BetterAuth
  class Router
    attr_reader :context, :endpoints, :rate_limiter

    def initialize(context, endpoints, rate_limiter: RateLimiter.new)
      @context = context
      @endpoints = endpoints
      @dispatcher = EndpointDispatcher.new(context)
      @rate_limiter = rate_limiter
      @origin_check = Middleware::OriginCheck.new
    end

    def self.check_endpoint_conflicts(options, logger)
      registry = Hash.new { |hash, key| hash[key] = [] }
      options.plugins.each do |plugin|
        plugin.fetch(:endpoints, {}).each do |key, endpoint|
          next unless endpoint.respond_to?(:path) && endpoint.path

          registry[endpoint.path] << {
            plugin_id: plugin[:id].to_s,
            endpoint_key: key.to_s,
            methods: endpoint.methods
          }
        end
      end

      conflicts = registry.filter_map do |path, entries|
        conflict_methods = conflicting_methods(entries)
        next if conflict_methods.empty?

        {
          path: path,
          plugins: entries.map { |entry| entry[:plugin_id] }.uniq,
          methods: conflict_methods
        }
      end

      return if conflicts.empty?

      message = "Endpoint path conflicts detected! Multiple plugins are trying to use the same endpoint paths with conflicting HTTP methods:\n"
      message += conflicts.map do |conflict|
        "  - \"#{conflict[:path]}\" [#{conflict[:methods].join(", ")}] used by plugins: #{conflict[:plugins].join(", ")}"
      end.join("\n")
      message += <<~GUIDANCE


        To resolve this, you can:
        \t1. Use only one of the conflicting plugins
        \t2. Configure the plugins to use different paths (if supported)
        \t3. Ensure plugins use different HTTP methods for the same path
      GUIDANCE
      log(logger, :error, message)
    end

    def call(env)
      DatabaseHooks.with_adapter_scope do
        RequestState.with_current { dispatch(env) }
      end
    ensure
      context.clear_runtime! if context.respond_to?(:clear_runtime!)
    end

    private

    def dispatch(env)
      request = Rack::Request.new(env)
      context.prepare_for_request!(request) if context.respond_to?(:prepare_for_request!)

      original_path = normalize_path(request.path_info)
      request_path = path_under_base(original_path) || original_path
      return [404, {"content-type" => "text/plain;charset=UTF-8"}, ["Not Found"]] if disabled_path?(request_path)

      response = rate_limiter.call(request, context, request_path)
      return response if response

      request = run_on_request_chain(request)
      return request if rack_response?(request)

      run_on_response_chain(process_request(request))
    end

    def process_request(request)
      route_path = route_path_for(request.path_info)
      return not_found unless route_path
      query = parse_query(request)
      key, endpoint, params, allowed_methods = find_endpoint(route_path, request.request_method)
      return not_found unless endpoint
      return method_not_allowed(allowed_methods) unless endpoint.matches_method?(request.request_method)
      validate_media_type!(request, endpoint) unless endpoint.disable_body

      raw_body = read_raw_body(request)
      body = parse_body(request, raw_body: raw_body, disable_body: endpoint.disable_body)
      endpoint_context = build_endpoint_context(request, route_path, query, body, params, raw_body)
      return forbidden if server_only?(endpoint)

      @origin_check.call(endpoint_context)

      response = run_plugin_middlewares(endpoint_context)
      return response if response

      @dispatcher.call(endpoint, endpoint_context, key: key).to_rack_response
    rescue => error
      handle_processing_error(error, request)
    end

    def handle_processing_error(error, request)
      errors = request.env["rack.errors"] || $stderr
      begin
        if !error.is_a?(APIError) || error.status != "FOUND"
          options = context.options.on_api_error
          raise error if options[:throw]

          callback = options[:on_error]
          if callback.respond_to?(:call)
            callback.call(error, context)
          else
            log_processing_error(error, errors)
          end
        end
      rescue APIError => callback_error
        return error_response(callback_error)
      end

      return error_response(error) if error.is_a?(APIError)

      errors.puts("# SERVER_ERROR: #{error.full_message(highlight: false)}")
      [500, {}, []]
    end

    def log_processing_error(error, errors)
      if /column|relation|table|does not exist/.match?(error.message)
        context.log_error(error.message, fallback: errors)
      elsif error.is_a?(APIError)
        if error.status == "INTERNAL_SERVER_ERROR"
          context.log_error("#{error.status}: #{error.full_message(highlight: false)}", fallback: errors)
        end
        context.log_error(error.message) if log_api_error_message?
      else
        context.log_error("#{error.class}: #{error.full_message(highlight: false)}", fallback: errors)
      end
    end

    def log_api_error_message?
      logger = context.logger
      return false unless logger.respond_to?(:level)

      level = logger.level
      if defined?(::Logger::SEV_LABEL) && level.is_a?(Integer)
        level = ::Logger::SEV_LABEL.fetch(level, "")
      end
      %w[debug warn error].include?(level.to_s.downcase)
    end

    def self.conflicting_methods(entries)
      method_map = Hash.new { |hash, key| hash[key] = [] }
      entries.each do |entry|
        entry[:methods].each do |method|
          method_map[method] << entry[:plugin_id]
        end
      end

      method_map.keys.select do |method|
        method_map[method].length > 1 ||
          (method == "*" && entries.length > 1) ||
          (method != "*" && method_map.key?("*"))
      end
    end

    def self.log(logger, level, message)
      if logger.respond_to?(:call)
        logger.call(level, message)
      elsif logger.respond_to?(level)
        logger.public_send(level, message)
      end
    end

    private_class_method :conflicting_methods, :log

    def path_under_base(path)
      base_path = context.options.base_path
      return "/" if path == base_path

      path.delete_prefix(base_path) if path.start_with?("#{base_path}/")
    end

    def route_path_for(path_info)
      path_under_base(normalize_path(path_info, trim: context.options.advanced[:skip_trailing_slashes]))
    end

    def normalize_path(path, trim: true)
      decoded = path.to_s
      2.times do
        next_decoded = CGI.unescape(decoded)
        break if next_decoded == decoded

        decoded = next_decoded
      end
      decoded = decoded.gsub(/[[:cntrl:]]/, "")
      decoded = decoded.squeeze("/")
      decoded = trim_trailing_slashes(decoded) if trim
      decoded.empty? ? "/" : decoded
    rescue ArgumentError
      path.to_s
    end

    def trim_trailing_slashes(path)
      path = path.sub(%r{/+\z}, "")
      path.empty? ? "/" : path
    end

    def read_raw_body(request)
      return "" unless request.body

      request.body.rewind
      raw = request.body.read.to_s
      request.body.rewind
      raw
    end

    def parse_body(request, raw_body:, disable_body: false)
      return {} if disable_body || raw_body.empty?

      if json_media_type?(request.media_type)
        JSON.parse(raw_body)
      else
        request.POST
      end
    rescue JSON::ParserError
      raise APIError.new("BAD_REQUEST", message: "Invalid JSON in request body")
    end

    def json_media_type?(media_type)
      media_type == "application/json" || media_type.to_s.end_with?("+json")
    end

    def validate_media_type!(request, endpoint)
      return unless request_body_method?(request.request_method)
      return if request.media_type.nil? || request.media_type.empty?
      return if request.body.nil? || request.content_length.to_i.zero?

      types = allowed_media_types(endpoint)
      return if types.include?(request.media_type)

      raise APIError.new("UNSUPPORTED_MEDIA_TYPE", message: "Content-Type \"#{request.content_type}\" is not allowed. Allowed types: #{types.join(", ")}")
    end

    def request_body_method?(method)
      %w[POST PUT PATCH DELETE].include?(method.to_s.upcase)
    end

    def allowed_media_types(endpoint)
      endpoint.metadata[:allowed_media_types] ||
        endpoint.metadata["allowedMediaTypes"] ||
        endpoint.metadata[:allowedMediaTypes] ||
        ["application/json"]
    end

    def parse_query(request)
      query = request.GET
      # Rack's nested parser drops plain duplicates. URI.decode_www_form requires ASCII input.
      encoded_query = URLHelpers::URI_PARSER.escape(request.query_string.b, /[\x80-\xff]/n)
      URI.decode_www_form(encoded_query).group_by(&:first).each_with_object(query.dup) do |(key, pairs), result|
        result[key] = pairs.map(&:last) if pairs.length > 1 && query.key?(key)
      end
    end

    def build_endpoint_context(request, path, query, body, params, raw_body)
      Endpoint::Context.new(
        path: path,
        method: request.request_method,
        query: query,
        body: body,
        params: params,
        headers: headers_from(request.env),
        context: context,
        request: request,
        raw_body: raw_body
      )
    end

    def headers_from(env)
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

    def find_endpoint(route_path, method)
      path_matches = endpoints.filter_map do |key, endpoint|
        params = match_path(endpoint.path, route_path)
        [key, endpoint, params] if params
      end

      return if path_matches.empty?

      match = path_matches.reverse.find { |_, candidate, _| candidate.matches_method?(method) } || path_matches.first
      allowed_methods = path_matches.flat_map { |_, candidate, _| candidate.methods }.uniq
      [*match, allowed_methods]
    end

    def match_path(pattern, path)
      return {} if pattern == path
      return nil unless pattern

      pattern_parts = pattern.split("/", -1)
      path_parts = path.split("/", -1)
      return nil unless pattern_parts.length == path_parts.length

      params = {}
      pattern_parts.zip(path_parts).each do |pattern_part, path_part|
        if pattern_part.start_with?(":")
          params[pattern_part.delete_prefix(":").to_sym] = path_part
        elsif pattern_part != path_part
          return nil
        end
      end
      params
    end

    def run_plugin_middlewares(endpoint_context)
      plugin_middlewares.each do |middleware|
        params = PathMatcher.middleware_pattern_match(middleware[:path], endpoint_context.path)
        next unless params

        middleware_context = endpoint_context.dup
        middleware_context.params = params
        attributes = {
          "better_auth.hook.type" => "middleware",
          "better_auth.context" => "plugin:#{middleware[:plugin_id]}",
          "http.route" => middleware[:path]
        }
        result = Instrumentation.with_span("middleware #{middleware[:path]} #{middleware[:plugin_id]}", attributes: attributes, options: context.options) do
          middleware[:middleware].call(middleware_context)
        end
        return Endpoint::Result.from_value(result, middleware_context).to_rack_response if result
      end
      nil
    end

    def plugin_middlewares
      context.options.plugins.flat_map do |plugin|
        Array(plugin[:middlewares]).map do |middleware|
          {
            path: middleware[:path],
            middleware: middleware[:middleware],
            plugin_id: plugin.id
          }
        end
      end
    end

    def disabled_path?(route_path)
      context.options.disabled_paths.any? do |disabled|
        normalize_path(disabled) == normalize_path(route_path)
      end
    end

    def run_on_request_chain(request)
      current_request = request
      context.options.plugins.each do |plugin|
        handler = plugin[:on_request]
        next unless handler

        result = with_plugin_hook_span("onRequest", plugin.id) { handler.call(current_request, context) }
        next unless result

        return result[:response] if result[:response]
        current_request = result[:request] if result[:request]
      end
      current_request
    end

    def run_on_response_chain(response)
      context.options.plugins.each do |plugin|
        handler = plugin[:on_response]
        next unless handler

        result = with_plugin_hook_span("onResponse", plugin.id, "http.response.status_code" => response.first) do
          handler.call(response, context)
        end
        next unless result

        replacement = result[:response] if result.is_a?(Hash)
        return rack_response?(replacement) ? replacement : response
      end
      response
    end

    def with_plugin_hook_span(hook_type, plugin_id, extra = {})
      attributes = {"better_auth.hook.type" => hook_type, "better_auth.context" => "plugin:#{plugin_id}"}.merge(extra)
      Instrumentation.with_span("#{hook_type} #{plugin_id}", attributes: attributes, options: context.options) { yield }
    end

    def not_found
      [404, {"content-type" => "application/json"}, [JSON.generate({error: "Not Found"})]]
    end

    def method_not_allowed(methods)
      [405, {"content-type" => "application/json", "allow" => methods.reject { |method| method == "*" }.join(", ")}, [JSON.generate({error: "Method Not Allowed"})]]
    end

    def forbidden
      [403, {"content-type" => "application/json"}, [JSON.generate({error: "Forbidden"})]]
    end

    def server_only?(endpoint)
      endpoint.metadata[:server_only] ||
        endpoint.metadata[:SERVER_ONLY] ||
        endpoint.metadata["SERVER_ONLY"]
    end

    def error_response(error)
      Endpoint::Result.new(response: error).to_rack_response
    end

    def rack_response?(value)
      Endpoint::Result.rack_response?(value)
    end
  end
end
