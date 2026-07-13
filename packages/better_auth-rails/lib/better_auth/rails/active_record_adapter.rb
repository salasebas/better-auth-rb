# frozen_string_literal: true

require "securerandom"
require "json"
require "time"

module BetterAuth
  module Rails
    class ActiveRecordAdapter < BetterAuth::Adapters::Base
      include BetterAuth::Adapters::JoinSupport

      begin
        require "active_record" unless defined?(::ActiveRecord)
      rescue LoadError
        # ActiveRecord is required only when the adapter is instantiated in a Rails app.
      end

      if defined?(::ActiveRecord::Base)
        class ApplicationRecord < ::ActiveRecord::Base
          self.abstract_class = true
        end
      else
        class ApplicationRecord
        end
      end

      attr_reader :connection

      def initialize(options = nil, connection: nil)
        super(options)
        @connection = connection || (options ? ::ActiveRecord::Base : nil)
        @models = {}
      end

      def call(options)
        self.class.new(options, connection: connection)
      end

      def create(model:, data:, force_allow_id: false)
        model = model.to_s
        input = transform_input(model, data, "create", force_allow_id)
        record = model_class(model).create!(physical_attributes(model, input))
        normalize_record(model, record)
      end

      def create_if_absent(model:, data:, conflict_field: "id", force_allow_id: true)
        model = model.to_s
        field = atomic_schema_field(schema_for(model).fetch(:fields), conflict_field)
        input = transform_input(model, data, "create", force_allow_id)
        raise BetterAuth::APIError.new("BAD_REQUEST", message: "Missing conflict field #{conflict_field}") unless input.key?(field)

        begin
          connection.connection.transaction(requires_new: true) do
            model_class(model).create!(physical_attributes(model, input))
          end
          true
        rescue ::ActiveRecord::RecordNotUnique => error
          existing = find_one(model: model, where: [{field: field, value: input.fetch(field)}])
          return false if existing

          raise error
        end
      end

      def find_one(model:, where: [], select: nil, join: nil)
        find_many(model: model, where: where, select: select, join: join, limit: 1).first
      end

      def find_many(model:, where: [], sort_by: nil, limit: nil, offset: nil, select: nil, join: nil)
        model = model.to_s
        relation = relation_for(model, where: where, sort_by: sort_by, limit: limit, offset: offset, select: select, join: join)
        records = relation.map { |record| normalize_record(model, record, join: join) }
        collection_join?(model, join) ? aggregate_collection_joins(model, records, join) : records
      end

      def update(model:, where:, update:)
        model = model.to_s
        return nil if Array(where).empty?

        ensure_update_input_has_fields!(model, update)
        existing = find_one(model: model, where: where)
        return nil unless existing

        updated_count = update_many(model: model, where: where, update: update)
        return nil unless updated_count.to_i.positive?

        lookup = record_lookup(model, existing)
        lookup ? find_one(model: model, where: [lookup]) : find_one(model: model, where: where)
      end

      def update_many(model:, where:, update:, returning: false)
        model = model.to_s
        ensure_update_input_has_fields!(model, update)
        data = transform_input(model, update, "update", true)
        ensure_update_data!(data)
        attributes = physical_attributes(model, data)
        relation = relation_for(model, where: where)
        if returning
          relation.map do |record|
            record.update!(attributes)
            normalize_record(model, record)
          end
        else
          relation.update_all(attributes)
        end
      end

      def delete(model:, where:)
        delete_many(model: model, where: where)
        nil
      end

      def delete_many(model:, where:)
        relation_for(model.to_s, where: where).delete_all
      end

      def count(model:, where: nil)
        relation_for(model.to_s, where: where || []).count
      end

      def consume_one(model:, where:)
        model = model.to_s
        transaction do
          record = relation_for(model, where: where || []).limit(1).lock(true).first
          if record
            target = normalize_record(model, record)
            lookup = record_lookup(model, target)
            raise BetterAuth::Error, "ActiveRecord cannot atomically identify a #{model} row" unless lookup

            deleted = relation_for(model, where: Array(where) + [lookup.merge(connector: "AND")]).limit(1).delete_all
            ensure_numeric_affected_rows!(deleted, "delete_all")
            deleted.positive? ? target : nil
          end
        end
      end

      def increment_one(model:, where:, increment:, set: nil, allow_server_managed: false)
        model = model.to_s
        increments, assignments = normalize_atomic_update(model, increment, set, allow_server_managed)
        transaction do
          record = relation_for(model, where: where || []).limit(1).lock(true).first
          if record
            target = normalize_record(model, record)
            lookup = record_lookup(model, target)
            raise BetterAuth::Error, "ActiveRecord cannot atomically identify a #{model} row" unless lookup

            updates = atomic_update_attributes(model, increments, assignments)
            updated = relation_for(model, where: Array(where) + [lookup.merge(connector: "AND")]).limit(1).update_all(updates)
            ensure_numeric_affected_rows!(updated, "update_all")
            updated.positive? ? apply_atomic_result(target, increments, assignments) : nil
          end
        end
      end

      def transaction
        return yield active_transaction_adapter if active_transaction_adapter

        connection.connection.transaction { with_transaction_context(self) { yield self } }
      end

      private

      def model_class(model)
        model = model.to_s
        return @models[model] if @models.key?(model)

        klass = Class.new(ApplicationRecord)
        model_namespace.const_set(class_name_for(model), klass)
        klass.table_name = table_for(model) if klass.respond_to?(:table_name=)
        klass.primary_key = storage_field(model, "id") if klass.respond_to?(:primary_key=) && schema_for(model).fetch(:fields).key?("id")
        @models[model] = klass
        define_join_associations(model, klass)
        klass
      end

      def relation_for(model, where:, sort_by: nil, limit: nil, offset: nil, select: nil, join: nil)
        relation = model_class(model).all
        relation = apply_where(model, relation, where || [])
        relation = apply_select(model, relation, select) if select
        relation = apply_join_includes(model, relation, join) if join
        relation = apply_order(model, relation, sort_by) if sort_by
        relation = relation.limit(Integer(limit)) if limit
        relation = relation.offset(Integer(offset)) if offset
        relation
      end

      def apply_where(model, relation, where)
        clauses = Array(where)
        return relation if clauses.empty?

        if model_class(model).respond_to?(:arel_table)
          and_clauses, or_clauses = grouped_where_clauses(clauses)
          and_expression = combine_where_expressions(model, and_clauses, :and)
          or_expression = combine_where_expressions(model, or_clauses, :or)
          expression = if and_expression && or_expression
            and_expression.and(or_expression)
          else
            and_expression || or_expression
          end
          relation.where(expression)
        else
          apply_where_with_relation_or(model, relation, clauses)
        end
      end

      def combine_where_expressions(model, clauses, connector)
        clauses.map { |clause| where_expression(model, clause) }.reduce do |combined, current|
          combined.public_send(connector, current)
        end
      end

      def apply_operator(scope, column, operator, value)
        case operator
        when "in" then scope.where(column => Array(value))
        when "not_in" then scope.where.not(column => Array(value))
        when "ne" then scope.where.not(column => value)
        when "gt" then scope.where("#{column} > ?", value)
        when "gte" then scope.where("#{column} >= ?", value)
        when "lt" then scope.where("#{column} < ?", value)
        when "lte" then scope.where("#{column} <= ?", value)
        when "contains" then scope.where("#{column} LIKE ? ESCAPE ?", "%#{escape_like(value)}%", "\\")
        when "starts_with" then scope.where("#{column} LIKE ? ESCAPE ?", "#{escape_like(value)}%", "\\")
        when "ends_with" then scope.where("#{column} LIKE ? ESCAPE ?", "%#{escape_like(value)}", "\\")
        else scope.where(column => value)
        end
      end

      def apply_where_with_relation_or(model, relation, clauses)
        and_clauses, or_clauses = grouped_where_clauses(clauses)
        and_relation = and_clauses.reduce(relation) do |combined, clause|
          field = storage_key(fetch_key(clause, :field))
          column = storage_field(model, field)
          operator = (fetch_key(clause, :operator) || "eq").to_s
          value = fetch_key(clause, :value)
          apply_operator(combined, column, operator, value)
        end
        or_relation = or_clauses.map do |clause|
          field = storage_key(fetch_key(clause, :field))
          apply_operator(relation, storage_field(model, field), (fetch_key(clause, :operator) || "eq").to_s, fetch_key(clause, :value))
        end.reduce { |combined, current| combined.or(current) }
        return and_relation unless or_relation
        return or_relation if and_clauses.empty?

        and_relation.and(or_relation)
      end

      def where_expression(model, clause)
        field = storage_key(fetch_key(clause, :field))
        attributes = schema_for(model).fetch(:fields).fetch(field)
        column = model_class(model).arel_table[storage_field(model, field)]
        operator = (fetch_key(clause, :operator) || "eq").to_s
        value = fetch_key(clause, :value)
        mode = (fetch_key(clause, :mode) || "sensitive").to_s
        insensitive = mode == "insensitive" && attributes[:type] == "string" && !value.nil?
        predicate_column = insensitive ? lower(column) : column
        predicate_value = insensitive ? lower_value(value) : value

        case operator
        when "in" then predicate_column.in(Array(predicate_value))
        when "not_in" then predicate_column.not_in(Array(predicate_value))
        when "ne" then predicate_column.not_eq(predicate_value)
        when "gt" then column.gt(value)
        when "gte" then column.gteq(value)
        when "lt" then column.lt(value)
        when "lte" then column.lteq(value)
        when "contains" then predicate_column.matches("%#{escape_like(predicate_value)}%", "\\")
        when "starts_with" then predicate_column.matches("#{escape_like(predicate_value)}%", "\\")
        when "ends_with" then predicate_column.matches("%#{escape_like(predicate_value)}", "\\")
        else predicate_column.eq(predicate_value)
        end
      end

      def apply_select(model, relation, select)
        columns = Array(select).map { |field| storage_field(model, storage_key(field)) }
        relation.select(*columns)
      end

      def apply_order(model, relation, sort_by)
        field = storage_key(fetch_key(sort_by, :field))
        direction = (fetch_key(sort_by, :direction).to_s.downcase == "desc") ? :desc : :asc
        relation.order(storage_field(model, field) => direction)
      end

      def transform_input(model, data, action, force_allow_id)
        fields = schema_for(model).fetch(:fields)
        input = stringify_keys(data)
        output = {}
        fields.each do |field, attributes|
          next if field == "id" && input.key?(field) && !force_allow_id

          value_provided = input.key?(field)
          value = input[field]
          if value_provided && attributes[:input] == false && value && !force_allow_id
            raise APIError.new("BAD_REQUEST", message: "#{field} is not allowed to be set")
          end

          if !value_provided && action == "create" && attributes.key?(:default_value)
            value = resolve_default(attributes[:default_value])
            value_provided = true
          elsif !value_provided && action == "update" && attributes[:on_update]
            value = resolve_default(attributes[:on_update])
            value_provided = true
          end
          if !value_provided && action == "create" && attributes[:required]
            raise APIError.new("BAD_REQUEST", message: "#{field} is required") unless field == "id"
          end
          output[field] = coerce_value(value, attributes) if value_provided
        end
        output["id"] = generated_id if action == "create" && !output.key?("id") && fields.key?("id")
        output
      end

      def ensure_update_data!(data)
        raise APIError.new("BAD_REQUEST", message: "No fields to update") if data.empty?
      end

      def ensure_update_input_has_fields!(model, update)
        raise APIError.new("BAD_REQUEST", message: "No fields to update") unless update.is_a?(Hash)

        fields = schema_for(model).fetch(:fields)
        input = stringify_keys(update)
        has_updatable_field = input.any? do |field, _value|
          next false if field == "id" || field == "_id"

          fields.key?(field) || fields.any? { |logical_field, attributes| storage_key(attributes[:field_name] || logical_field) == field }
        end
        raise APIError.new("BAD_REQUEST", message: "No fields to update") unless has_updatable_field
      end

      def normalize_atomic_update(model, increment, set, allow_server_managed)
        raise BetterAuth::APIError.new("BAD_REQUEST", message: "increment must be a Hash") unless increment.is_a?(Hash)

        fields = schema_for(model).fetch(:fields)
        increments = increment.each_with_object({}) do |(field, delta), result|
          logical_field = atomic_schema_field(fields, field)
          attributes = fields[logical_field]
          valid_field = attributes && logical_field != "id" && attributes[:type] == "number"
          valid_field = false if attributes && attributes[:input] == false && allow_server_managed != true
          unless valid_field
            raise BetterAuth::APIError.new("BAD_REQUEST", message: "Invalid increment field #{field}; expected a mutable numeric field")
          end
          if !delta.is_a?(Numeric) || (delta.respond_to?(:finite?) && !delta.finite?)
            raise BetterAuth::APIError.new("BAD_REQUEST", message: "Increment delta for #{field} must be numeric")
          end

          result[logical_field] = delta
        end
        assignments = if set.nil? || set.empty?
          {}
        else
          ensure_update_input_has_fields!(model, set)
          transform_input(model, set, "update", true)
        end
        increments.reject! { |field, _delta| assignments.key?(field) }
        if increments.empty? && assignments.empty?
          raise BetterAuth::APIError.new("BAD_REQUEST", message: "increment_one requires a non-empty increment or set")
        end

        [increments, assignments]
      end

      def atomic_update_attributes(model, increments, assignments)
        table = Arel::Table.new(table_for(model))
        updates = increments.each_with_object({}) do |(field, delta), result|
          column = storage_field(model, field)
          current = Arel::Nodes::NamedFunction.new("COALESCE", [table[column], Arel::Nodes.build_quoted(0)])
          result[column] = current + delta
        end
        updates.merge(physical_attributes(model, assignments))
      end

      def atomic_schema_field(fields, field)
        candidate = storage_key(field)
        return candidate if fields.key?(candidate)

        fields.find { |logical, attributes| storage_key(attributes[:field_name] || logical) == candidate }&.first
      end

      def apply_atomic_result(target, increments, assignments)
        result = target.dup
        increments.each do |field, delta|
          result[field] = (result[field].is_a?(Numeric) ? result[field] : 0) + delta
        end
        result.merge(assignments)
      end

      def ensure_numeric_affected_rows!(value, operation)
        return if value.is_a?(Numeric)

        raise BetterAuth::Error, "ActiveRecord returned a non-numeric affected-row result from #{operation}"
      end

      def record_lookup(model, record)
        fields = schema_for(model).fetch(:fields)
        return {field: "id", value: record.fetch("id")} if fields.key?("id") && record.key?("id")

        unique_field = fields.find { |field, attributes| attributes[:unique] && record.key?(field) }
        return {field: unique_field.first, value: record.fetch(unique_field.first)} if unique_field

        nil
      end

      def physical_attributes(model, logical)
        logical.each_with_object({}) do |(field, value), attributes|
          attributes[storage_field(model, field)] = value
        end
      end

      def normalize_record(model, record, join: nil)
        return nil unless record

        attributes = record.respond_to?(:attributes) ? record.attributes : record
        normalized = schema_for(model).fetch(:fields).each_with_object({}) do |(field, config), output|
          column = config[:field_name] || physical_name(field)
          output[field] = coerce_output_value(attributes[column], config) if attributes.key?(column)
        end
        attach_joins(model, normalized, record, join)
      end

      def attach_joins(model, normalized, record, join)
        return normalized unless join

        join.each_key do |join_model|
          join_model = join_model.to_s
          definition = join_definition(model, join_model)
          next unless definition

          association = definition.fetch(:association)
          next unless record.respond_to?(association)

          joined = record.public_send(association)
          normalized[join_model] = if definition[:collection]
            Array(joined).map { |joined_record| normalize_record(join_model, joined_record) }
          else
            normalize_record(join_model, joined)
          end
        end
        normalized
      end

      def apply_join_includes(model, relation, join)
        associations = join.filter_map do |join_model, _enabled|
          join_definition(model, join_model.to_s)&.fetch(:association)
        end
        return relation if associations.empty? || !relation.respond_to?(:includes)

        relation.includes(*associations)
      end

      def define_join_associations(model, klass)
        schema_models.each_key do |join_model|
          next if join_model == model

          definition = safe_join_definition(model, join_model)
          next unless definition

          association = definition.fetch(:association)
          next if association_defined?(klass, association)

          if definition[:owner] == :base && definition[:collection]
            next unless klass.respond_to?(:has_many)

            klass.has_many(
              association,
              class_name: model_class(join_model).name,
              foreign_key: storage_field(join_model, definition.fetch(:to)),
              primary_key: storage_field(model, definition.fetch(:from))
            )
          elsif definition[:owner] == :base
            next unless klass.respond_to?(:has_one)

            klass.has_one(
              association,
              class_name: model_class(join_model).name,
              foreign_key: storage_field(join_model, definition.fetch(:to)),
              primary_key: storage_field(model, definition.fetch(:from))
            )
          else
            next unless klass.respond_to?(:belongs_to)

            klass.belongs_to(
              association,
              class_name: model_class(join_model).name,
              foreign_key: storage_field(model, definition.fetch(:from)),
              primary_key: storage_field(join_model, definition.fetch(:to)),
              optional: true
            )
          end
        end
      end

      def join_definition(model, join_model)
        inferred_join_config(model.to_s, join_model.to_s).merge(association: join_model.to_sym)
      end

      def safe_join_definition(model, join_model)
        join_definition(model, join_model)
      rescue BetterAuth::Error
        nil
      end

      def inferred_join_config(model, join_model)
        foreign_keys = schema_for(join_model).fetch(:fields).select do |_field, attributes|
          reference_model_matches?(attributes, model)
        end

        unless foreign_keys.empty?
          raise BetterAuth::Error, "Multiple foreign keys found for model #{join_model} and base model #{model} while performing join operation. Only one foreign key is supported." if foreign_keys.length > 1

          foreign_key, attributes = foreign_keys.first
          reference = attributes.fetch(:references)
          unique = attributes[:unique] == true
          return {
            from: reference.fetch(:field).to_s,
            to: foreign_key,
            collection: !unique,
            owner: :base,
            relation: unique ? "one-to-one" : "one-to-many",
            unique: unique
          }
        end

        foreign_keys = schema_for(model).fetch(:fields).select do |_field, attributes|
          reference_model_matches?(attributes, join_model)
        end

        raise BetterAuth::Error, "No foreign key found for model #{join_model} and base model #{model} while performing join operation." if foreign_keys.empty?
        raise BetterAuth::Error, "Multiple foreign keys found for model #{join_model} and base model #{model} while performing join operation. Only one foreign key is supported." if foreign_keys.length > 1

        foreign_key, attributes = foreign_keys.first
        reference = attributes.fetch(:references)
        {
          from: foreign_key,
          to: reference.fetch(:field).to_s,
          collection: false,
          owner: :join,
          relation: "one-to-one",
          unique: true
        }
      end

      def association_defined?(klass, association)
        klass.respond_to?(:reflect_on_association) && klass.reflect_on_association(association)
      end

      def schema_models
        BetterAuth::Schema.auth_tables(options)
      end

      def model_namespace
        @model_namespace ||= BetterAuth::Rails.const_set("ActiveRecordAdapterModels#{object_id}", Module.new)
      end

      def class_name_for(model)
        physical_name(model).split("_").map(&:capitalize).join
      end

      def aggregate_collection_joins(_model, records, _join)
        records
      end

      def table_for(model)
        schema_for(model).fetch(:model_name)
      end

      def schema_for(model)
        BetterAuth::Schema.auth_tables(options).fetch(model.to_s)
      end

      def storage_field(model, field)
        schema_for(model).fetch(:fields).fetch(field.to_s).fetch(:field_name, physical_name(field))
      end

      def stringify_keys(value)
        return {} unless value.respond_to?(:each)

        value.each_with_object({}) { |(key, object), result| result[storage_key(key)] = object }
      end

      def fetch_key(hash, key)
        [key, key.to_s, storage_key(key), storage_key(key).to_sym].each do |candidate|
          return hash[candidate] if hash.key?(candidate)
        end
        nil
      end

      def storage_key(value)
        BetterAuth::Schema.send(:storage_key, value)
      end

      def physical_name(value)
        BetterAuth::Schema.send(:physical_name, value)
      end

      def resolve_default(value)
        value.respond_to?(:call) ? value.call : value
      end

      def coerce_value(value, attributes)
        return value if value.nil?
        return Time.parse(value) if attributes[:type] == "date" && value.is_a?(String)

        value
      end

      def coerce_output_value(value, attributes)
        return value if value.nil?
        return coerce_boolean(value) if attributes[:type] == "boolean"
        return Time.parse(value) if attributes[:type] == "date" && value.is_a?(String)
        return parse_json_value(value) if json_like?(attributes) && value.is_a?(String)

        value
      end

      def coerce_boolean(value)
        return value if value == true || value == false
        return false if value == 0 || value.to_s == "0" || value.to_s.downcase == "f" || value.to_s.downcase == "false"
        return true if value == 1 || value.to_s == "1" || value.to_s.downcase == "t" || value.to_s.downcase == "true"

        value
      end

      def json_like?(attributes)
        %w[json string[] number[]].include?(attributes[:type])
      end

      def parse_json_value(value)
        JSON.parse(value)
      rescue JSON::ParserError
        value
      end

      def lower(node)
        Arel::Nodes::NamedFunction.new("LOWER", [node])
      end

      def lower_value(value)
        return value.map { |entry| entry.nil? ? entry : entry.to_s.downcase } if value.is_a?(Array)

        value.to_s.downcase
      end

      def generated_id
        generator = options.advanced.dig(:database, :generate_id) || options.advanced.dig(:database, :generateId)
        return generator.call.to_s if generator.respond_to?(:call)
        return SecureRandom.uuid if generator.to_s == "uuid"

        SecureRandom.hex(16)
      end

      def escape_like(value)
        value.to_s.gsub(/[\\%_]/) { |match| "\\#{match}" }
      end
    end
  end
end
