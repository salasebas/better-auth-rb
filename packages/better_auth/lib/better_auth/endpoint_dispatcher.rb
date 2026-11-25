# frozen_string_literal: true

module BetterAuth
  class EndpointDispatcher
    def initialize(context)
      @context = context
    end

    def call(endpoint, endpoint_context, key: nil)
      route = endpoint.path || "/:virtual"
      operation_id = endpoint.operation_id || key&.to_s || route
      attributes = {"http.route" => route, "better_auth.operation_id" => operation_id}
      RequestState.with_current do
        endpoint_context.with_current do
          Instrumentation.with_span("#{endpoint_context.method} #{route}", attributes: attributes, options: @context.options) do
            result = run_endpoint_with_hooks(endpoint, endpoint_context, attributes)
            block_given? ? yield(result) : result
          end
        end
      end
    end

    private

    def run_endpoint_with_hooks(endpoint, endpoint_context, attributes)
      before = run_before_hooks(endpoint_context, attributes)
      return Endpoint::Result.from_value(before, endpoint_context) if before

      result = begin
        Instrumentation.with_span("handler #{attributes.fetch("http.route")}", attributes: attributes, options: @context.options) do
          endpoint.call(endpoint_context)
        end
      rescue APIError => error
        Endpoint::Result.from_value(error, endpoint_context)
      end

      return result if result.raw_response?

      endpoint_context.returned = result.response
      endpoint_context.response_headers = result.headers.dup

      run_after_hooks(result, endpoint_context, attributes)
    end

    def run_before_hooks(endpoint_context, attributes)
      hooks(:before).each do |hook|
        next unless before_hook_matches?(hook, endpoint_context)

        result = run_hook(:before, hook, endpoint_context, attributes)
        next if !result || result == true || result.is_a?(String) || result.is_a?(Numeric) || result.is_a?(Symbol)

        context_data = fetch_key(result, :context)
        if context_data.is_a?(Hash)
          endpoint_context.merge_context!(context_data)
          next
        end

        return result
      end

      nil
    end

    def run_after_hooks(result, endpoint_context, attributes)
      hooks(:after).each do |hook|
        next unless hook[:matcher].call(endpoint_context)

        hook_result = begin
          returned = run_hook(:after, hook, endpoint_context, attributes)
          returned unless returned.is_a?(APIError) && returned.equal?(result.response)
        rescue APIError => error
          error
        end

        result.headers = endpoint_context.response_headers.dup

        next unless hook_result

        result = Endpoint::Result.from_value(hook_result, endpoint_context)
        endpoint_context.returned = result.response
        endpoint_context.response_headers = result.headers
      end

      result
    end

    def run_hook(type, hook, endpoint_context, attributes)
      source = hook.fetch(:source)
      route = attributes.fetch("http.route")
      hook_attributes = attributes.merge("better_auth.hook.type" => type.to_s, "better_auth.context" => source)
      Instrumentation.with_span("hook #{type} #{route} #{source}", attributes: hook_attributes, options: @context.options) do
        hook[:handler].call(endpoint_context)
      end
    end

    def hooks(type)
      hooks = []
      user_hook = @context.options.hooks&.fetch(type, nil)
      hooks << {matcher: ->(_ctx) { true }, handler: user_hook, source: "user"} if user_hook
      hooks.concat(plugin_hooks(type))
    end

    def plugin_hooks(type)
      @context.options.plugins.flat_map do |plugin|
        hooks = plugin.dig(:hooks, type)
        Array(hooks).map do |hook|
          {
            matcher: hook[:matcher] || ->(_ctx) { true },
            handler: hook[:handler],
            source: "plugin:#{plugin.id}"
          }
        end
      end
    end

    def before_hook_matches?(hook, endpoint_context)
      hook[:matcher].call(endpoint_context)
    rescue => error
      request = endpoint_context.request
      errors = request.env["rack.errors"] if request.respond_to?(:env)
      @context.log_error("An error occurred during #{hook[:source]} hook matcher execution: #{error.full_message(highlight: false)}", fallback: errors || $stderr)
      raise APIError.new("INTERNAL_SERVER_ERROR", message: "An error occurred during hook matcher execution. Check the logs for more details.")
    end

    def fetch_key(hash, key)
      return unless hash.is_a?(Hash)

      hash[key] || hash[key.to_s]
    end
  end
end
