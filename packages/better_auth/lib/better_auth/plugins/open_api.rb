# frozen_string_literal: true

module BetterAuth
  module OpenAPI
    # Better Auth action endpoints advertise upstream camelCase JSON field names in
    # OpenAPI and generated inventories. Runtime may still accept Ruby snake_case
    # aliases via normalize_hash and route validation.

    module_function

    def object_schema(properties, required: [])
      {
        type: "object",
        properties: properties,
        required: required
      }
    end

    def json_request_body(schema, required: true)
      request = {
        content: {
          "application/json" => {
            schema: schema
          }
        }
      }
      request[:required] = true if required
      request
    end

    def json_response(description, schema)
      {
        description: description,
        content: {
          "application/json" => {
            schema: schema
          }
        }
      }
    end

    def session_response_schema(description:, nullable_url: false)
      object_schema(
        {
          redirect: {type: "boolean", enum: [false]},
          token: {type: "string", description: "Session token"},
          url: nullable_url ? {type: "string", nullable: true} : {type: "string"},
          user: {type: "object", "$ref": "#/components/schemas/User"}
        },
        required: ["redirect", "token", "user"]
      ).merge(description: description)
    end

    def user_response_schema
      object_schema(
        {
          id: {type: "string", description: "The unique identifier of the user"},
          email: {type: "string", format: "email", description: "The email address of the user"},
          name: {type: "string", description: "The name of the user"},
          image: {type: "string", format: "uri", nullable: true, description: "The profile image URL of the user"},
          emailVerified: {type: "boolean", description: "Whether the email has been verified"},
          createdAt: {type: "string", format: "date-time", description: "When the user was created"},
          updatedAt: {type: "string", format: "date-time", description: "When the user was last updated"}
        },
        required: ["id", "email", "name", "emailVerified", "createdAt", "updatedAt"]
      )
    end

    def session_response_schema_pair
      object_schema(
        {
          session: {type: "object", "$ref": "#/components/schemas/Session"},
          user: {type: "object", "$ref": "#/components/schemas/User"}
        },
        required: ["session", "user"]
      )
    end

    def status_response_schema(extra_properties = {}, required: ["status"])
      object_schema(
        {
          status: {type: "boolean"}
        }.merge(extra_properties),
        required: required
      )
    end

    def success_response_schema
      object_schema(
        {
          success: {type: "boolean"}
        },
        required: ["success"]
      )
    end

    def ref_schema(name, type: "object")
      {type: type, "$ref": "#/components/schemas/#{name}"}
    end

    def array_schema(items)
      {type: "array", items: items}
    end

    def nullable(type)
      types = Array(type)
      (types.include?("null") ? types : types + ["null"])
    end

    def query_parameter(name, required: false, schema: {type: "string"}, description: nil)
      parameter = {name: name, in: "query", required: required, schema: schema}
      parameter[:description] = description if description
      parameter
    end

    def path_parameter(name, schema: {type: "string"}, description: nil)
      parameter = {name: name, in: "path", required: true, schema: schema}
      parameter[:description] = description if description
      parameter
    end

    def empty_request_body
      {
        content: {
          "application/json" => {
            schema: {
              type: "object",
              properties: {}
            }
          }
        }
      }
    end

    def default_request_body
      {
        required: true,
        content: {
          "application/json" => {
            schema: {
              type: "object",
              properties: {},
              additionalProperties: true
            }
          }
        }
      }
    end

    def responses(responses = nil)
      {"200" => success_response}.merge(default_error_responses).merge(responses || {})
    end

    def success_response
      json_response(
        "Success",
        {
          type: "object",
          properties: {}
        }
      )
    end

    def default_success_response
      json_response(
        "Success",
        {
          type: "object",
          properties: {},
          additionalProperties: true
        }
      )
    end

    def default_error_responses
      {
        "400" => error_response("Bad Request. Usually due to missing parameters, or invalid parameters.", required: true),
        "401" => error_response("Unauthorized. Due to missing or invalid authentication.", required: true),
        "403" => error_response("Forbidden. You do not have permission to access this resource or to perform this action."),
        "404" => error_response("Not Found. The requested resource was not found."),
        "429" => error_response("Too Many Requests. You have exceeded the rate limit. Try again later."),
        "500" => error_response("Internal Server Error. This is a problem with the server that you cannot fix.")
      }
    end

    def error_response(description, required: false)
      schema = {
        type: "object",
        properties: {
          message: {
            type: "string"
          }
        }
      }
      schema[:required] = ["message"] if required
      json_response(description, schema)
    end

    def default_metadata(path, methods)
      method = Array(methods).reject { |value| value.to_s == "*" }.first.to_s.upcase
      metadata = {
        operationId: operation_id(path, method),
        description: "Execute the #{operation_id(path, method)} endpoint.",
        parameters: default_path_parameters(path),
        responses: {
          "200" => default_success_response
        }
      }
      metadata[:requestBody] = default_request_body if %w[POST PUT PATCH].include?(method)
      metadata
    end

    def operation_id(path, method)
      parts = path.to_s.split("/").reject(&:empty?).map do |part|
        part.delete_prefix(":").gsub(/[^a-zA-Z0-9]+/, " ").split.map(&:capitalize).join
      end
      base = parts.join
      return method.downcase if base.empty?

      "#{method.to_s.downcase}#{base}"
    end

    def default_path_parameters(path)
      path.to_s.split("/").filter_map do |part|
        next unless part.start_with?(":")

        path_parameter(part.delete_prefix(":"))
      end
    end
  end

  module Plugins
    module_function

    def open_api(options = {})
      config = {path: "/reference", theme: "default"}.merge(normalize_hash(options))

      Plugin.new(
        id: "open-api",
        endpoints: {
          generate_open_api_schema: Endpoint.new(path: "/open-api/generate-schema", method: "GET") do |ctx|
            ctx.json(open_api_schema(ctx.context))
          end,
          open_api_reference: Endpoint.new(path: config[:path], method: "GET", metadata: {hide: true}) do |ctx|
            raise APIError.new("NOT_FOUND") if config[:disable_default_reference]

            [200, {"content-type" => "text/html"}, [open_api_html(open_api_schema(ctx.context), config)]]
          end
        },
        options: config
      )
    end

    def open_api_schema(context)
      {
        openapi: "3.1.1",
        info: {
          title: "Better Auth",
          description: "API Reference for your Better Auth Instance",
          version: "1.1.0"
        },
        components: {
          schemas: open_api_components(context.options),
          securitySchemes: open_api_security_schemes
        },
        security: [
          {
            apiKeyCookie: [],
            bearerAuth: []
          }
        ],
        servers: [
          {
            url: context.base_url
          }
        ],
        tags: [
          {
            name: "Default",
            description: "Default endpoints that are included with Better Auth by default. These endpoints are not part of any plugin."
          }
        ],
        paths: open_api_paths(open_api_endpoints(context.options), context.options)
      }
    end

    def open_api_endpoints(options)
      Core.base_endpoints.map { |key, endpoint| [key, endpoint, "Default"] } +
        options.plugins.flat_map do |plugin|
          next [] if plugin.id == "open-api"

          tag = plugin.id.to_s.split("-").map(&:capitalize).join("-")
          plugin.endpoints.map { |key, endpoint| [key, endpoint, tag] }
        end
    end

    def open_api_security_schemes
      {
        apiKeyCookie: {
          type: "apiKey",
          in: "cookie",
          name: "apiKeyCookie",
          description: "API Key authentication via cookie"
        },
        bearerAuth: {
          type: "http",
          scheme: "bearer",
          description: "Bearer token authentication"
        }
      }
    end

    def open_api_paths(endpoints, options)
      disabled_paths = Array(options.disabled_paths).map(&:to_s)
      endpoints.each_with_object({}) do |(key, endpoint, tag), paths|
        next unless endpoint.path
        next if endpoint.metadata[:exclude_from_openapi] || endpoint.metadata[:SERVER_ONLY] || endpoint.metadata[:server_only]
        next if endpoint.metadata[:hide] && !open_api_documented_hidden_endpoint?(key, endpoint, tag)
        next if disabled_paths.include?(endpoint.path)
        next if key == :set_password

        path = open_api_path(endpoint.path)
        paths[path] ||= {}
        endpoint.methods.reject { |method| method == "*" }.each do |method|
          paths[path][method.downcase.to_sym] = open_api_operation(endpoint, method, tag)
        end
      end
    end

    def open_api_path(path)
      path.split("/").map { |part| part.start_with?(":") ? "{#{part.delete_prefix(":")}}" : part }.join("/")
    end

    def open_api_documented_hidden_endpoint?(key, endpoint, tag)
      tag == "Default" && [:ok, :error].include?(key) && endpoint.metadata[:openapi]
    end

    def open_api_operation(endpoint, method, tag)
      metadata = endpoint.metadata[:openapi] || {}
      operation = {
        tags: Array(metadata[:tags] || [tag]),
        description: metadata[:description],
        operationId: metadata[:operationId],
        security: [
          {
            bearerAuth: []
          }
        ],
        parameters: metadata[:parameters] || [],
        responses: OpenAPI.responses(metadata[:responses])
      }

      if %w[POST PATCH PUT].include?(method)
        operation[:requestBody] = metadata[:requestBody] || OpenAPI.empty_request_body
      end

      operation
    end

    def open_api_components(options)
      Schema.auth_tables(options).each_with_object({}) do |(model, table), schemas|
        name = model.to_s.split(/[_-]/).map(&:capitalize).join
        schemas[name.to_sym] = schema_for_table(table)
      end
    end

    def schema_for_table(table)
      required = []
      properties = table[:fields].each_with_object({}) do |(field, attributes), result|
        result[field.to_sym] = field_schema(attributes)
        required << field if attributes[:required] && attributes[:input] != false && field != "id"
      end
      {type: "object", properties: properties, required: required}
    end

    def field_schema(attributes)
      type = case attributes[:type].to_s
      when "date" then "string"
      when "number" then "number"
      when "boolean" then "boolean"
      else "string"
      end
      schema = {type: type}
      schema[:format] = "date-time" if attributes[:type].to_s == "date"
      schema[:default] = attributes[:default_value].respond_to?(:call) ? "Generated at runtime" : attributes[:default_value] if attributes.key?(:default_value)
      schema[:readOnly] = true if attributes[:input] == false
      schema
    end

    def open_api_html(schema, config)
      nonce = config[:nonce] ? " nonce=\"#{config[:nonce]}\"" : ""
      nonce_attr = config[:nonce] ? "nonce=\"#{config[:nonce]}\"" : ""
      encoded_logo = open_api_encode_uri_component(open_api_logo)
      <<~HTML
        <!doctype html>
        <html>
          <head>
            <title>Scalar API Reference</title>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
          </head>
          <body>
            <script
              id="api-reference"
              type="application/json">
            #{JSON.generate(schema)}
            </script>
            <script #{nonce_attr}>
              var configuration = {
                favicon: "data:image/svg+xml;utf8,#{encoded_logo}",
                theme: "#{config[:theme] || "default"}",
                metaData: {
                  title: "Better Auth API",
                  description: "API Reference for your Better Auth Instance",
                }
              }

              document.getElementById('api-reference').dataset.configuration =
                JSON.stringify(configuration)
            </script>
            <script src="https://cdn.jsdelivr.net/npm/@scalar/api-reference"#{nonce}></script>
          </body>
        </html>
      HTML
    end

    def open_api_logo
      <<~SVG
        <svg width="75" height="75" viewBox="0 0 75 75" fill="none" xmlns="http://www.w3.org/2000/svg">
          <rect width="75" height="75" rx="14" fill="#050505"/>
          <path d="M19 50V25h15.5c5.5 0 9 2.6 9 6.6 0 2.7-1.6 4.7-4.1 5.7 3.2.9 5.2 3 5.2 6.1 0 4.2-3.7 6.6-9.6 6.6H19Zm7.1-14.8h7.2c2.1 0 3.2-.9 3.2-2.4s-1.1-2.4-3.2-2.4h-7.2v4.8Zm0 9.5h7.9c2.2 0 3.5-.9 3.5-2.5s-1.3-2.6-3.5-2.6h-7.9v5.1Z" fill="white"/>
          <path d="M47 50V25h7.1v25H47Z" fill="white"/>
        </svg>
      SVG
    end

    def open_api_encode_uri_component(value)
      value.to_s.bytes.map do |byte|
        char = byte.chr
        char.match?(/[A-Za-z0-9\-_.!~*'()]/) ? char : "%%%02X" % byte
      end.join
    end
  end
end
