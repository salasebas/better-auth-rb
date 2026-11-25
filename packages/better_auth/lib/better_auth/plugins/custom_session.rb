# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def custom_session(resolver, options = nil, plugin_options = nil, **keywords)
      config = normalize_hash(plugin_options || {})
      config = config.merge(normalize_hash(options)) if options && !options.key?(:plugins)
      config = config.merge(normalize_hash(keywords))

      Plugin.new(
        id: "custom-session",
        endpoints: {
          get_session: Endpoint.new(
            path: "/get-session",
            method: "GET",
            query_schema: ->(query) { query || {} },
            metadata: {
              CUSTOM_SESSION: true,
              openapi: {
                description: "Get custom session data",
                responses: {
                  "200" => {
                    description: "Success",
                    content: {
                      "application/json" => {
                        schema: {
                          type: "object",
                          nullable: true
                        }
                      }
                    }
                  }
                }
              }
            }
          ) do |ctx|
            session = Routes.get_session_data(ctx)
            next ctx.json(nil) unless session

            ctx.json(resolver.call(Routes.parsed_session_response(ctx, session), ctx))
          end
        },
        hooks: {
          after: [
            {
              matcher: ->(ctx) { ctx.path == "/multi-session/list-device-sessions" && config[:should_mutate_list_device_sessions_endpoint] },
              handler: lambda do |ctx|
                list = Array(ctx.returned)
                ctx.json(list.map { |entry| resolver.call(symbolize_session(entry), ctx) })
              end
            }
          ]
        },
        options: config
      )
    end

    def symbolize_session(entry)
      data = stringify_keys(entry)
      {
        session: data["session"],
        user: data["user"]
      }
    end

    def stringify_keys(value)
      return value.each_with_object({}) { |(key, object_value), result| result[key.to_s] = stringify_keys(object_value) } if value.is_a?(Hash)
      return value.map { |entry| stringify_keys(entry) } if value.is_a?(Array)

      value
    end
  end
end
