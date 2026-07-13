# frozen_string_literal: true

require "cgi"
require "json"
require "rack/request"

module BetterAuth
  class Router
    attr_reader :context, :endpoints, :rate_limiter

    def initialize(context, endpoints, rate_limiter: RateLimiter.new)
      @context = context
      @endpoints = endpoints
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
      log(logger, :error, message)
    end

    def call(env)
      request = Rack::Request.new(env)
      context.prepare_for_request!(request) if context.respond_to?(:prepare_for_request!)

      route_path = route_path_for(request.path_info)
      return not_found unless route_path

      query = parse_query(request)
      endpoint, params, allowed_methods = find_endpoint(route_path, request.request_method)
      return run_on_response_chain(not_found) unless endpoint
      return run_on_response_chain(method_not_allowed(allowed_methods)) unless endpoint.matches_method?(request.request_method)
      return run_on_response_chain(unsupported_media_type) unless allowed_media_type?(request, endpoint)

      raw_body = read_raw_body(request)
      body = parse_body(request, raw_body: raw_body, disable_body: endpoint.disable_body)
      endpoint_context = build_endpoint_context(request, route_path, query, body, params, raw_body)
      return run_on_response_chain(forbidden) if server_only?(endpoint)

      response = @origin_check.call(endpoint_context)
      return run_on_response_chain(response) if response

      response = run_plugin_middlewares(endpoint_context)
      return run_on_response_chain(response) if response

      return run_on_response_chain(not_found) if disabled_path?(route_path)

      response = rate_limiter.call(request, context, route_path)
      return run_on_response_chain(response) if response

      request = run_on_request_chain(request)
      return run_on_response_chain(request) if rack_response?(request)

      endpoint_context = rebuild_endpoint_context(endpoint_context, request, route_path, params, endpoint)
      result = API.new(context, endpoints).execute(endpoint, endpoint_context)
      response = result.response.is_a?(APIError) ? error_response(result.response, headers: result.headers) : result.to_rack_response
      run_on_response_chain(response)
    rescue APIError => error
      error_response(error)
    rescue JSON::ParserError
      error_response(APIError.new("BAD_REQUEST", message: "Invalid JSON body"))
    ensure
      context.clear_runtime! if context.respond_to?(:clear_runtime!)
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

    private

    def route_path_for(path_info)
      base_path = context.options.base_path
      decoded = normalize_path(path_info, trim: false)

      path = if base_path.empty?
        decoded
      elsif decoded == base_path
        "/"
      elsif decoded.start_with?("#{base_path}/")
        decoded.delete_prefix(base_path)
      else
        return nil
      end

      if context.options.advanced[:skip_trailing_slashes]
        trim_trailing_slashes(path)
      else
        path
      end
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
      return {} if disable_body

      raw = raw_body.to_s
      return {} if raw.empty?

      if json_media_type?(request.media_type)
        JSON.parse(raw)
      else
        request.POST
      end
    end

    def json_media_type?(media_type)
      media_type == "application/json" || media_type.to_s.end_with?("+json")
    end

    def allowed_media_type?(request, endpoint)
      return true unless request_body_method?(request.request_method)
      return true if request.media_type.nil? || request.media_type.empty?
      return true if request.body.nil? || request.content_length.to_i.zero?

      allowed_media_types(endpoint).include?(request.media_type)
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
      request.GET
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

    def rebuild_endpoint_context(previous_context, request, route_path, params, endpoint)
      raw_body = read_raw_body(request)
      fresh_context = build_endpoint_context(request, route_path, parse_query(request), parse_body(request, raw_body: raw_body, disable_body: endpoint.disable_body), params, raw_body)
      fresh_context.headers = merge_hashes(previous_context.headers, fresh_context.headers)
      fresh_context.query = merge_hashes(previous_context.query, fresh_context.query)
      fresh_context.body = merge_hashes(previous_context.body, fresh_context.body)
      fresh_context
    end

    def merge_hashes(base, override)
      return override unless base.is_a?(Hash) && override.is_a?(Hash)

      base.merge(override) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          merge_hashes(old_value, new_value)
        else
          new_value
        end
      end
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
      path_matches = endpoints.values.filter_map do |endpoint|
        params = match_path(endpoint.path, route_path)
        [endpoint, params] if params
      end

      return [nil, {}, []] if path_matches.empty?

      endpoint, params = path_matches.reverse.find { |candidate, _candidate_params| candidate.matches_method?(method) } || path_matches.first
      allowed_methods = path_matches.flat_map { |candidate, _candidate_params| candidate.methods }.uniq
      [endpoint, params, allowed_methods]
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
        next unless path_matches?(middleware[:path], endpoint_context.path)

        result = middleware[:middleware].call(endpoint_context)
        return Endpoint::Result.from_value(result, endpoint_context).to_rack_response if result
      end
      nil
    end

    def plugin_middlewares
      context.options.plugins.flat_map do |plugin|
        Array(plugin[:middlewares]).map do |middleware|
          {
            path: middleware[:path],
            middleware: middleware[:middleware]
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

        result = handler.call(current_request, context)
        next unless result

        return result[:response] if result[:response]
        current_request = result[:request] if result[:request]
      end
      current_request
    end

    def run_on_response_chain(response)
      current_response = response
      context.options.plugins.each do |plugin|
        handler = plugin[:on_response]
        next unless handler

        result = handler.call(current_response, context)
        current_response = result[:response] if result && result[:response]
      end
      current_response
    end

    def path_matches?(pattern, path)
      return true if pattern == "/**"
      return path == pattern unless pattern&.end_with?("/**")

      path.start_with?(pattern.delete_suffix("/**"))
    end

    def not_found
      [404, {"content-type" => "application/json"}, [JSON.generate({error: "Not Found"})]]
    end

    def method_not_allowed(methods)
      [405, {"content-type" => "application/json", "allow" => methods.reject { |method| method == "*" }.join(", ")}, [JSON.generate({error: "Method Not Allowed"})]]
    end

    def unsupported_media_type
      [415, {"content-type" => "application/json"}, [JSON.generate({error: "Unsupported Media Type"})]]
    end

    def forbidden
      [403, {"content-type" => "application/json"}, [JSON.generate({error: "Forbidden"})]]
    end

    def server_only?(endpoint)
      endpoint.metadata[:server_only] ||
        endpoint.metadata[:SERVER_ONLY] ||
        endpoint.metadata["SERVER_ONLY"] ||
        endpoint.metadata[:scope].to_s == "server" ||
        endpoint.metadata["scope"].to_s == "server"
    end

    def error_response(error, headers: {})
      Endpoint::Result.new(
        response: error.to_h,
        status: error.status_code,
        headers: Endpoint::Result.merge_headers(headers, error.headers)
      ).to_rack_response
    end

    def rack_response?(value)
      Endpoint::Result.rack_response?(value)
    end
  end
end
