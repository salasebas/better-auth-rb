# frozen_string_literal: true

module BetterAuth
  module APIKey
    module RequestContract
      CREATE_BODY_FIELDS = {
        "configId" => {type: :string},
        "name" => {type: :string},
        "expiresIn" => {type: :number, minimum: 1, nullable: true},
        "prefix" => {type: :prefix},
        "remaining" => {type: :number, minimum: 0, nullable: true},
        "metadata" => {type: :any},
        "refillAmount" => {type: :number, minimum: 1},
        "refillInterval" => {type: :number},
        "rateLimitTimeWindow" => {type: :number},
        "rateLimitMax" => {type: :number},
        "rateLimitEnabled" => {type: :boolean},
        "permissions" => {type: :permissions},
        "userId" => {type: :string, coerce: true},
        "organizationId" => {type: :string, coerce: true}
      }.freeze

      VERIFY_BODY_FIELDS = {
        "configId" => {type: :string},
        "key" => {type: :string, required: true},
        "permissions" => {type: :permissions}
      }.freeze

      GET_QUERY_FIELDS = {
        "configId" => {type: :string},
        "id" => {type: :string, required: true}
      }.freeze

      LIST_QUERY_FIELDS = {
        "configId" => {type: :string},
        "organizationId" => {type: :string},
        "limit" => {type: :number, coerce: true, integer: true, minimum: 0},
        "offset" => {type: :number, coerce: true, integer: true, minimum: 0},
        "sortBy" => {type: :string},
        "sortDirection" => {type: :enum, values: %w[asc desc]}
      }.freeze

      UPDATE_BODY_FIELDS = {
        "configId" => {type: :string},
        "keyId" => {type: :string, required: true},
        "userId" => {type: :string, coerce: true},
        "name" => {type: :string},
        "enabled" => {type: :boolean},
        "remaining" => {type: :number, minimum: 1},
        "refillAmount" => {type: :number},
        "refillInterval" => {type: :number},
        "metadata" => {type: :any},
        "expiresIn" => {type: :number, minimum: 1, nullable: true},
        "rateLimitEnabled" => {type: :boolean},
        "rateLimitTimeWindow" => {type: :number},
        "rateLimitMax" => {type: :number},
        "permissions" => {type: :permissions, nullable: true}
      }.freeze

      DELETE_BODY_FIELDS = {
        "configId" => {type: :string},
        "keyId" => {type: :string, required: true}
      }.freeze

      INVALID_PREFIX_MESSAGE = "Invalid prefix format, must be alphanumeric and contain only underscores and hyphens."
      MISSING = Object.new.freeze
      INVALID_NUMBER = Object.new.freeze

      module_function

      def create_body_schema
        method(:parse_create_body)
      end

      def verify_body_schema
        method(:parse_verify_body)
      end

      def get_query_schema
        method(:parse_get_query)
      end

      def list_query_schema
        method(:parse_list_query)
      end

      def update_body_schema
        method(:parse_update_body)
      end

      def delete_body_schema
        method(:parse_delete_body)
      end

      def parse_create_body(value)
        parse_object(value, "body", CREATE_BODY_FIELDS)
      end

      def parse_verify_body(value)
        parse_object(value, "body", VERIFY_BODY_FIELDS)
      end

      def parse_get_query(value)
        parse_object(value, "query", GET_QUERY_FIELDS)
      end

      def parse_list_query(value)
        parse_object(value, "query", LIST_QUERY_FIELDS)
      end

      def parse_update_body(value)
        parse_object(value, "body", UPDATE_BODY_FIELDS)
      end

      def parse_delete_body(value)
        parse_object(value, "body", DELETE_BODY_FIELDS)
      end

      def parse_object(value, label, fields)
        unless value.is_a?(Hash)
          raise_validation("[#{label}] Invalid input: expected object, received #{input_type(value)}")
        end

        parsed = {}
        issues = []
        fields.each do |name, rules|
          input = field_value(value, name)
          if input.equal?(MISSING)
            issues << "[#{label}.#{name}] Invalid input: expected #{expected_type(rules)}, received undefined" if rules[:required]
            next
          end

          parsed_value, field_issues = parse_field(input, rules, "#{label}.#{name}")
          parsed[name] = parsed_value if field_issues.empty?
          issues.concat(field_issues)
        end

        raise_validation(issues.join("; ")) if issues.any?

        parsed
      end

      def parse_field(value, rules, path)
        return [nil, []] if value.nil? && (rules[:nullable] || rules[:type] == :any)

        case rules[:type]
        when :any
          [value, []]
        when :string
          parse_string(value, rules, path)
        when :number
          parse_number(value, rules, path)
        when :boolean
          parse_boolean(value, path)
        when :prefix
          parse_prefix(value, path)
        when :permissions
          parse_permissions(value, path)
        when :enum
          parse_enum(value, rules.fetch(:values), path)
        else
          [value, []]
        end
      end

      def parse_string(value, rules, path)
        return [coerce_string(value), []] if rules[:coerce]
        return [value, []] if value.is_a?(String)

        [nil, ["[#{path}] Invalid input: expected string, received #{input_type(value)}"]]
      end

      def parse_number(value, rules, path)
        number = rules[:coerce] ? coerce_number(value) : value
        if number.equal?(INVALID_NUMBER)
          return [nil, ["[#{path}] Invalid input: expected number, received NaN"]]
        end
        unless number.is_a?(Numeric) && finite_number?(number)
          return [nil, ["[#{path}] Invalid input: expected number, received #{input_type(number)}"]]
        end
        if rules[:integer] && number.to_i != number
          return [nil, ["[#{path}] Invalid input: expected int, received number"]]
        end
        if rules.key?(:minimum) && number < rules[:minimum]
          return [nil, ["[#{path}] Too small: expected number to be >=#{rules[:minimum]}"]]
        end

        [rules[:integer] ? number.to_i : number, []]
      end

      def parse_boolean(value, path)
        return [value, []] if value == true || value == false

        [nil, ["[#{path}] Invalid input: expected boolean, received #{input_type(value)}"]]
      end

      def parse_prefix(value, path)
        return [nil, ["[#{path}] Invalid input: expected string, received #{input_type(value)}"]] unless value.is_a?(String)
        return [value, []] if value.match?(/\A[a-zA-Z0-9_-]+\z/)

        [nil, ["[#{path}] #{INVALID_PREFIX_MESSAGE}"]]
      end

      def parse_permissions(value, path)
        unless value.is_a?(Hash)
          return [nil, ["[#{path}] Invalid input: expected record, received #{input_type(value)}"]]
        end

        parsed = {}
        issues = []
        value.each do |key, permissions|
          permission_path = "#{path}.#{key}"
          unless permissions.is_a?(Array)
            issues << "[#{permission_path}] Invalid input: expected array, received #{input_type(permissions)}"
            next
          end

          permission_issues = permissions.each_with_index.filter_map do |permission, index|
            next if permission.is_a?(String)

            "[#{permission_path}.#{index}] Invalid input: expected string, received #{input_type(permission)}"
          end
          issues.concat(permission_issues)
          parsed[key.to_s] = permissions if permission_issues.empty?
        end
        [parsed, issues]
      end

      def parse_enum(value, allowed, path)
        return [value, []] if allowed.include?(value)

        options = allowed.map(&:inspect).join("|")
        [nil, ["[#{path}] Invalid option: expected one of #{options}"]]
      end

      def field_value(value, name)
        return value[name] if value.key?(name)

        symbol = name.to_sym
        value.key?(symbol) ? value[symbol] : MISSING
      end

      def expected_type(rules)
        case rules[:type]
        when :permissions then "record"
        when :enum then rules.fetch(:values).map(&:inspect).join("|")
        else rules[:type]
        end
      end

      def input_type(value)
        return "null" if value.nil?
        return "array" if value.is_a?(Array)
        return "string" if value.is_a?(String)
        return "boolean" if value == true || value == false
        return "NaN" if value.is_a?(Float) && value.nan?
        return "number" if value.is_a?(Numeric)
        return "object" if value.is_a?(Hash)

        "object"
      end

      def finite_number?(value)
        !value.respond_to?(:finite?) || value.finite?
      end

      def coerce_number(value)
        return value if value.is_a?(Numeric)
        return 0 if value.nil? || value == false || value == "" || value == []
        return 1 if value == true
        return coerce_number(value.first.to_s) if value.is_a?(Array) && value.length == 1
        return INVALID_NUMBER unless value.is_a?(String)

        stripped = value.strip
        return 0 if stripped.empty?

        Float(stripped)
      rescue ArgumentError, TypeError
        INVALID_NUMBER
      end

      def coerce_string(value)
        case value
        when nil then "null"
        when true then "true"
        when false then "false"
        when Array then value.map { |entry| coerce_string(entry) }.join(",")
        when Hash then "[object Object]"
        when Float
          (value.to_i == value) ? value.to_i.to_s : value.to_s
        else value.to_s
        end
      end

      def raise_validation(message)
        raise BetterAuth::APIError.new("BAD_REQUEST", code: "VALIDATION_ERROR", message: message)
      end
    end
  end
end
