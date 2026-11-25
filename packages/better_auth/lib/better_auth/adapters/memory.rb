# frozen_string_literal: true

require "securerandom"
require "time"
require "monitor"

module BetterAuth
  module Adapters
    class Memory < Base
      include JoinSupport
      include WhereValues

      LOCK_REGISTRY_GUARD = Mutex.new
      LOCKS_BY_DATABASE = {}

      class << self
        def lock_for(database)
          LOCK_REGISTRY_GUARD.synchronize do
            LOCKS_BY_DATABASE[database.object_id] ||= Monitor.new
          end
        end
      end

      attr_reader :db

      def initialize(options, db = nil)
        super(options)
        @db = db || build_db
        @lock = self.class.lock_for(@db)
      end

      def create(model:, data:, force_allow_id: false)
        @lock.synchronize do
          model = model.to_s
          table_for(model) << transform_input(model, data, "create", force_allow_id)
          table_for(model).last.dup
        end
      end

      def create_if_absent(model:, data:, conflict_field: "id", force_allow_id: true)
        @lock.synchronize do
          model = model.to_s
          fields = Schema.auth_tables(options).fetch(model).fetch(:fields)
          field = atomic_schema_field(fields, conflict_field)
          input = transform_input(model, data, "create", force_allow_id)
          raise APIError.new("BAD_REQUEST", message: "Missing conflict field #{conflict_field}") unless input.key?(field)
          next false if table_for(model).any? { |record| record[field] == input[field] }

          table_for(model) << input
          true
        end
      end

      def find_one(model:, where: [], select: nil, join: nil)
        find_many(model: model, where: where, select: select, join: join, limit: 1).first
      end

      def find_many(model:, where: [], sort_by: nil, limit: nil, offset: nil, select: nil, join: nil)
        @lock.synchronize do
          model = model.to_s
          limit = find_many_limit(limit)
          records = table_for(model).select(&where_predicate(model, where)).map(&:dup)
          join = normalized_join(model, join)
          records = records.map { |record| apply_join(record, join) } unless join.empty?
          records = sort_records(model, records, sort_by) if sort_by
          records = records.drop(offset.to_i) if offset
          records = records.first(limit.to_i) if limit
          fields = projected_join_fields(select, join)
          records = records.map { |record| record.slice(*fields, *join.keys) } unless fields.empty?
          records
        end
      end

      def update(model:, where:, update:)
        @lock.synchronize do
          model = model.to_s
          next nil if Array(where).empty?

          ensure_update_input_has_fields!(model, update)
          records = table_for(model).select(&where_predicate(model, where))
          data = transform_input(model, update, "update", true)
          ensure_update_data!(data)
          records.each { |record| record.merge!(data) }
          records.first&.dup
        end
      end

      def update_many(model:, where:, update:)
        @lock.synchronize do
          model = model.to_s
          ensure_update_input_has_fields!(model, update)
          records = table_for(model).select(&where_predicate(model, where))
          data = transform_input(model, update, "update", true)
          ensure_update_data!(data)
          records.each { |record| record.merge!(data) }
          records.length
        end
      end

      def delete(model:, where:)
        return nil if where.nil? || where.empty?

        delete_many(model: model, where: where)
        nil
      end

      def delete_many(model:, where:)
        @lock.synchronize do
          table = table_for(model)
          matches = table.select(&where_predicate(model, where))
          @db[model.to_s] = table.reject { |record| matches.include?(record) }
          matches.length
        end
      end

      def count(model:, where: nil)
        @lock.synchronize do
          table_for(model).count(&where_predicate(model, where))
        end
      end

      def consume_one(model:, where:)
        @lock.synchronize do
          table = table_for(model)
          index = table.index(&where_predicate(model, where))
          index ? table.delete_at(index) : nil
        end
      end

      def increment_one(model:, where:, increment:, set: nil, allow_server_managed: false)
        @lock.synchronize do
          model = model.to_s
          increments = normalized_increments(model, increment, allow_server_managed)
          assignments = normalized_increment_set(model, set)
          raise APIError.new("BAD_REQUEST", message: "increment_one requires a non-empty increment or set") if increments.empty? && assignments.empty?

          target = table_for(model).find(&where_predicate(model, where))
          next nil unless target

          increments.each do |field, delta|
            current = target[field]
            target[field] = (current.is_a?(Numeric) ? current : 0) + delta
          end
          target.merge!(assignments)
          target
        end
      end

      def transaction
        base = @lock.synchronize { transaction_snapshot(db) }
        transaction_adapter = clone(freeze: false)
        transaction_adapter.db = transaction_snapshot(base)
        result = with_transaction_context(transaction_adapter) { yield transaction_adapter }
        @lock.synchronize { merge_transaction(base, transaction_adapter.db) }
        result
      end

      def serialized_transaction(&block)
        @lock.synchronize { transaction(&block) }
      end

      protected attr_writer :db

      private

      def merge_transaction(base, working)
        merged = db.dup
        (base.keys | working.keys).each do |model|
          if working.key?(model)
            merged[model] = merge_transaction_rows(base.fetch(model, []), working.fetch(model), db.fetch(model, []))
          else
            merged.delete(model)
          end
        end
        db.replace(merged)
      end

      def merge_transaction_rows(base_rows, working_rows, live_rows)
        base_by_id = base_rows.to_h { |row| [row["id"], row] }
        working_by_id = working_rows.to_h { |row| [row["id"], row] }
        live_ids = live_rows.map { |row| row["id"] }.to_set

        merged = live_rows.filter_map do |row|
          id = row["id"]
          next if base_by_id.key?(id) && !working_by_id.key?(id)

          working_row = working_by_id[id]
          (working_row && !transaction_values_equal?(base_by_id[id], working_row)) ? working_row : row
        end
        merged.concat(working_rows.reject { |row| base_by_id.key?(row["id"]) || live_ids.include?(row["id"]) })
      end

      def transaction_values_equal?(before, after, seen = {})
        return true if before.equal?(after)
        return false if before.frozen? != after.frozen?
        return before == after unless before.is_a?(Hash) || before.is_a?(Array) || before.is_a?(Struct)

        pair = [before.object_id, after.object_id]
        return true if seen[pair]

        seen[pair] = true
        case before
        when Hash
          after.is_a?(Hash) && before.size == after.size && before.default_proc.equal?(after.default_proc) &&
            transaction_values_equal?(before.default, after.default, seen) &&
            before.all? { |key, value| after.key?(key) && transaction_values_equal?(value, after[key], seen) }
        when Array
          after.is_a?(Array) && before.size == after.size &&
            before.each_with_index.all? { |value, index| transaction_values_equal?(value, after[index], seen) }
        when Struct
          after.instance_of?(before.class) &&
            before.each_pair.all? { |member, value| transaction_values_equal?(value, after[member], seen) }
        end
      end

      def transaction_snapshot(value, copies = {})
        object_id = value.object_id
        return copies.fetch(object_id) if copies.key?(object_id)

        copy = case value
        when Hash
          value.dup.tap do |hash|
            hash.clear
            copies[object_id] = hash
            if value.default_proc
              hash.default_proc = value.default_proc
            else
              hash.default = transaction_snapshot(value.default, copies)
            end
            value.each do |key, child|
              hash[transaction_snapshot(key, copies)] = transaction_snapshot(child, copies)
            end
          end
        when Array
          value.dup.tap do |array|
            array.clear
            copies[object_id] = array
            value.each { |child| array << transaction_snapshot(child, copies) }
          end
        when Struct
          value.dup.tap do |struct|
            copies[object_id] = struct
            value.each_pair do |member, child|
              struct[member] = transaction_snapshot(child, copies)
            end
          end
        when String, Time
          value.dup.tap { |object| copies[object_id] = object }
        when Proc, Method, UnboundMethod, NilClass, TrueClass, FalseClass, Symbol, Numeric
          return value
        else
          raise TypeError, "Unsupported Memory transaction snapshot value: #{value.class}"
        end
        copy.freeze if value.frozen?
        copy
      end

      def build_db
        Schema.auth_tables(options).keys.to_h { |model| [model, []] }
      end

      def table_for(model)
        db[model.to_s] ||= []
      end

      def transform_input(model, data, action, force_allow_id)
        fields = Schema.auth_tables(options).fetch(model).fetch(:fields)
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

          output[field] = coerce_value(value, field, attributes) if value_provided
        end

        output["id"] = generated_id(model) if action == "create" && fields.key?("id") && (!output.key?("id") || output["id"].nil?)
        output
      end

      def ensure_update_data!(data)
        raise APIError.new("BAD_REQUEST", message: "No fields to update") if data.empty?
      end

      def ensure_update_input_has_fields!(model, update)
        raise APIError.new("BAD_REQUEST", message: "No fields to update") unless update.is_a?(Hash)

        fields = Schema.auth_tables(options).fetch(model).fetch(:fields)
        input = stringify_keys(update)
        has_updatable_field = input.any? do |field, _value|
          next false if field == "id" || field == "_id"

          fields.key?(field) || fields.any? { |logical_field, attributes| Schema.storage_key(attributes[:field_name] || logical_field) == field }
        end
        raise APIError.new("BAD_REQUEST", message: "No fields to update") unless has_updatable_field
      end

      def normalized_increments(model, increment, allow_server_managed)
        raise APIError.new("BAD_REQUEST", message: "increment must be a Hash") unless increment.is_a?(Hash)

        fields = Schema.auth_tables(options).fetch(model).fetch(:fields)
        increment.each_with_object({}) do |(field, delta), result|
          logical_field = atomic_schema_field(fields, field)
          attributes = fields[logical_field]
          valid_field = attributes && logical_field != "id" && attributes[:type] == "number"
          valid_field = false if attributes && attributes[:input] == false && allow_server_managed != true
          unless valid_field
            raise APIError.new("BAD_REQUEST", message: "Invalid increment field #{field}; expected a mutable numeric field")
          end
          if !delta.is_a?(Numeric) || (delta.respond_to?(:finite?) && !delta.finite?)
            raise APIError.new("BAD_REQUEST", message: "Increment delta for #{field} must be numeric")
          end

          result[logical_field] = delta
        end
      end

      def normalized_increment_set(model, set)
        return {} if set.nil? || set.empty?

        ensure_update_input_has_fields!(model, set)
        transform_input(model, set, "update", true)
      end

      def atomic_schema_field(fields, field)
        candidate = Schema.storage_key(field)
        return candidate if fields.key?(candidate)

        fields.find { |logical, attributes| Schema.storage_key(attributes[:field_name] || logical) == candidate }&.first
      end

      def generated_id(model)
        generator = options.advanced.dig(:database, :generate_id)
        return generator.call.to_s if generator.respond_to?(:call)
        return table_for(model).length + 1 if generator == "serial"
        return SecureRandom.uuid if generator == "uuid"

        SecureRandom.hex(16)
      end

      def resolve_default(default)
        default.respond_to?(:call) ? default.call : default
      end

      def coerce_value(value, field, attributes)
        return value if value.nil?
        return coerce_number(value) if serial_id_field?(field, attributes)
        return Time.parse(value) if attributes[:type] == "date" && value.is_a?(String)

        value
      end

      def where_predicate(model, where)
        return ->(_record) { true } if Array(where).empty?

        fields = schema_for(model).fetch(:fields)
        and_clauses, or_clauses = grouped_where_clauses(where).map do |clauses|
          clauses.map do |clause|
            field = Schema.storage_key(fetch_key(clause, :field))
            operator = (fetch_key(clause, :operator) || "eq").to_s
            value = fetch_key(clause, :value)
            require_where_array!(value) if operator == "in"
            mode = fetch_key(clause, :mode).to_s
            [field, operator, mode, coerce_where_value(value, field, fields.fetch(field, {}), operator)]
          end
        end
        lambda do |record|
          and_clauses.all? { |clause| evaluate_clause(record, *clause) } &&
            (or_clauses.empty? || or_clauses.any? { |clause| evaluate_clause(record, *clause) })
        end
      end

      def evaluate_clause(record, field, operator, mode, comparable)
        current = record[field]
        current, comparable = insensitive_values(current, comparable) if insensitive_comparison?(mode, current, comparable)

        case operator
        when "in"
          comparable.include?(current)
        when "not_in"
          require_where_array!(comparable)
          !comparable.include?(current)
        when "contains"
          current.to_s.include?(comparable.to_s)
        when "starts_with"
          current.to_s.start_with?(comparable.to_s)
        when "ends_with"
          current.to_s.end_with?(comparable.to_s)
        when "ne"
          current != comparable
        when "gt"
          !current.nil? && !comparable.nil? && current > comparable
        when "gte"
          !current.nil? && !comparable.nil? && current >= comparable
        when "lt"
          !current.nil? && !comparable.nil? && current < comparable
        when "lte"
          !current.nil? && !comparable.nil? && current <= comparable
        else
          current == comparable
        end
      end

      def coerce_where_value(value, field, attributes, operator)
        type = attributes[:type]
        return normalize_where_value(value, attributes) if %w[boolean number].include?(type)
        if value.is_a?(Array) && %w[in not_in].include?(operator)
          return value.map { |entry| coerce_scalar_where_value(entry, field, attributes) }
        end

        coerce_scalar_where_value(value, field, attributes)
      end

      def coerce_scalar_where_value(value, field, attributes)
        return value if value.nil?
        return coerce_number(value) if serial_id_field?(field, attributes)

        case attributes[:type]
        when "date"
          return Time.parse(value) if value.is_a?(String)
        when "number[]"
          return Array(value).map { |entry| coerce_number(entry) }
        when "string[]"
          return Array(value).map(&:to_s)
        end

        value
      end

      def serial_id_field?(field, attributes)
        return false unless options.advanced.dig(:database, :generate_id) == "serial"
        return true if field.to_s == "id"

        reference = attributes[:references]
        return false unless reference

        (reference[:field] || reference["field"]).to_s == "id"
      end

      def insensitive_comparison?(mode, current, comparable)
        return false unless mode == "insensitive"

        current.is_a?(String) && (comparable.is_a?(String) || comparable.is_a?(Array))
      end

      def insensitive_values(current, comparable)
        normalized_current = current.downcase
        normalized_comparable = if comparable.is_a?(Array)
          comparable.map { |entry| entry.is_a?(String) ? entry.downcase : entry }
        else
          comparable.downcase
        end
        [normalized_current, normalized_comparable]
      end

      def coerce_number(value)
        return value unless value.is_a?(String)
        return value.to_i if /\A-?\d+\z/.match?(value)
        return value.to_f if /\A-?\d+\.\d+\z/.match?(value)

        value
      end

      def sort_records(model, records, sort_by)
        field = Schema.storage_key(fetch_key(sort_by, :field))
        direction = fetch_key(sort_by, :direction).to_s
        records.sort_by { |record| sortable_value(record[field]) }.then do |sorted|
          if direction == "desc"
            sorted.reverse
          else
            sorted
          end
        end
      end

      def sortable_value(value)
        value.nil? ? "" : value
      end

      def apply_join(record, join)
        joined = record.dup
        join.each do |join_model, config|
          matches = table_for(join_model).select do |join_record|
            join_record[config.fetch(:to)] == record[config.fetch(:from)]
          end.map(&:dup)

          joined[join_model] = if one_to_one_join?(config)
            matches.first
          else
            matches.first(join_limit(config))
          end
        end
        joined
      end

      def schema_for(model)
        Schema.auth_tables(options).fetch(model.to_s)
      end

      def storage_key(field)
        Schema.storage_key(field)
      end

      def stringify_keys(data)
        data.each_with_object({}) do |(key, value), result|
          result[Schema.storage_key(key)] = value
        end
      end

      def fetch_key(hash, key)
        [key, key.to_s, Schema.storage_key(key), Schema.storage_key(key).to_sym].each do |candidate|
          return hash[candidate] if hash.key?(candidate)
        end
        nil
      end
    end
  end
end
