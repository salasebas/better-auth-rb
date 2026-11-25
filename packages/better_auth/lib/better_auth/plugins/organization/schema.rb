# frozen_string_literal: true

module BetterAuth
  module Plugins
    module OrganizationSchema
      module_function

      def build(config)
        schema = {
          organization: {
            model_name: "organizations",
            fields: {
              id: {type: "string", required: true},
              name: {type: "string", required: true, sortable: true},
              slug: {type: "string", required: true, unique: true, sortable: true, index: true},
              logo: {type: "string", required: false},
              metadata: {type: "string", required: false},
              createdAt: {type: "date", required: true, default_value: -> { Time.now }},
              updatedAt: {type: "date", required: false, on_update: -> { Time.now }}
            }
          },
          member: {
            model_name: "members",
            fields: {
              id: {type: "string", required: true},
              organizationId: {type: "string", required: true, references: {model: "organization", field: "id"}, index: true},
              userId: {type: "string", required: true, references: {model: "user", field: "id"}, index: true},
              role: {type: "string", required: true, default_value: "member", sortable: true},
              createdAt: {type: "date", required: true, default_value: -> { Time.now }}
            }
          },
          invitation: {
            model_name: "invitations",
            fields: {
              id: {type: "string", required: true},
              organizationId: {type: "string", required: true, references: {model: "organization", field: "id"}, index: true},
              email: {type: "string", required: true, sortable: true, index: true},
              role: {type: "string", required: true, sortable: true},
              status: {type: "string", required: true, sortable: true, default_value: "pending"},
              expiresAt: {type: "date", required: true},
              createdAt: {type: "date", required: true, default_value: -> { Time.now }},
              inviterId: {type: "string", required: true, references: {model: "user", field: "id"}}
            }
          },
          session: {
            fields: {
              activeOrganizationId: {type: "string", required: false, input: false}
            }
          }
        }

        if truthy?(config.dig(:teams, :enabled))
          schema[:team] = {
            model_name: "teams",
            fields: {
              id: {type: "string", required: true},
              name: {type: "string", required: true},
              organizationId: {type: "string", required: true, references: {model: "organization", field: "id"}, index: true},
              createdAt: {type: "date", required: true, default_value: -> { Time.now }},
              updatedAt: {type: "date", required: false, on_update: -> { Time.now }}
            }
          }
          schema[:teamMember] = {
            model_name: "team_members",
            fields: {
              id: {type: "string", required: true},
              teamId: {type: "string", required: true, references: {model: "team", field: "id"}, index: true},
              userId: {type: "string", required: true, references: {model: "user", field: "id"}, index: true},
              createdAt: {type: "date", required: false, default_value: -> { Time.now }}
            }
          }
          schema[:invitation][:fields][:teamId] = {type: "string", required: false, sortable: true}
          schema[:session][:fields][:activeTeamId] = {type: "string", required: false, input: false}
        end

        if truthy?(config.dig(:dynamic_access_control, :enabled))
          schema[:organizationRole] = {
            model_name: "organization_roles",
            fields: {
              id: {type: "string", required: true},
              organizationId: {type: "string", required: true, references: {model: "organization", field: "id"}, index: true},
              role: {type: "string", required: true, index: true},
              permission: {type: "string", required: true},
              createdAt: {type: "date", required: true, default_value: -> { Time.now }},
              updatedAt: {type: "date", required: false, on_update: -> { Time.now }}
            }
          }
        end

        Plugins.merge_schema(schema, config[:schema])
      end

      def create_body(config, model, *base, nested: false)
        fields = input_fields(config, model)
        ->(value) {
          body = Plugins.normalize_hash(value)
          additional = body.fetch(:additional_fields, {})
          validate_object!(additional, "body.additionalFields")
          input = nested ? additional : body.merge(additional.except(*base))
          parsed = if nested && !body.key?(:additional_fields)
            {}
          else
            parse_fields(input, fields, path: nested ? "body.additionalFields" : "body")
          end
          body.slice(*base).merge(parsed.slice(*base)).merge(additional_fields: parsed.except(*base))
        }
      end

      def update_body(config, model, *base, outer:, additional_fields_override_base: false)
        fields = input_fields(config, model)
        fields = fields.except(*base) unless additional_fields_override_base
        ->(value) {
          body = Plugins.normalize_hash(value)
          data = body.fetch(:data, body)
          validate_object!(data, "body.data")
          additional = data.fetch(:additional_fields, {})
          validate_object!(additional, "body.data.additionalFields")
          input = data.merge(additional.except(*base))
          parsed = parse_fields(input, fields, path: "body.data", partial: true, nullable: model == :organization_role)
          body.slice(*outer).merge(data: data.slice(*base).merge(parsed))
        }
      end

      def input_fields(config, model)
        fields = config.dig(:schema, model, :additional_fields) || {}
        Plugins.storage_fields(fields)
          .transform_keys { |key| Plugins.normalize_key(key) }
          .reject { |_key, attributes| attributes[:input] == false }
      end

      def parse_fields(input, fields, path:, partial: false, nullable: false)
        errors = []
        parsed = fields.each_with_object({}) do |(key, attributes), result|
          optional = attributes[:required] == false || nullable
          next if !input.key?(key) && (optional || partial)

          value = input[key]
          if input.key?(key) && (value.nil? && optional || matches_type?(value, attributes[:type]))
            result[key] = value
          else
            field_path = "#{path}.#{Schema.storage_key(key)}"
            errors.concat(type_errors(value, attributes[:type], field_path, present: input.key?(key)))
          end
        end
        raise_validation_error(errors.join("; ")) unless errors.empty?

        parsed
      end

      def validate_object!(value, path)
        return if value.is_a?(Hash)

        raise_validation_error("[#{path}] Invalid input: expected object, received #{value_type(value)}")
      end

      def raise_validation_error(message)
        raise APIError.new("BAD_REQUEST", code: "VALIDATION_ERROR", message: message)
      end

      def matches_type?(value, type)
        case type
        when "string" then value.is_a?(String)
        when "number" then value_type(value) == "number" && value.finite?
        when "boolean" then value == true || value == false
        when "date" then value.is_a?(Time) || value.is_a?(Date)
        when "string[]", "number[]"
          value.is_a?(Array) && value.all? { |item| matches_type?(item, type.delete_suffix("[]")) }
        when "json"
          case value
          when Array then value.all? { |item| matches_type?(item, "json") }
          when Hash then value.values.all? { |item| matches_type?(item, "json") }
          else value.nil? || %w[string number boolean].any? { |primitive| matches_type?(value, primitive) }
          end
        when Array then true
        else false
        end
      end

      def type_errors(value, type, path, present:)
        if %w[string[] number[]].include?(type)
          if value.is_a?(Array)
            element_type = type.delete_suffix("[]")
            return value.each_with_index.filter_map do |item, index|
              type_error("#{path}.#{index}", element_type, value_type(item)) unless matches_type?(item, element_type)
            end
          end
          type = "array"
        end
        [type_error(path, type, present ? value_type(value) : "undefined")]
      end

      def type_error(path, expected, actual)
        "[#{path}] Invalid input: expected #{expected}, received #{actual}"
      end

      def value_type(value)
        case value
        when nil then "null"
        when String then "string"
        when Integer, Float then "number"
        when true, false then "boolean"
        when Array then "array"
        when Hash then "object"
        when Time, Date then "date"
        else value.class.to_s
        end
      end

      def truthy?(value)
        value == true || value.to_s == "true"
      end
    end
  end
end
