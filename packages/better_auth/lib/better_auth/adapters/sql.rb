# frozen_string_literal: true

require "securerandom"
require "json"
require "monitor"
require "time"

module BetterAuth
  module Adapters
    class SQL < Base
      include JoinSupport

      attr_reader :connection, :dialect

      def initialize(options, connection:, dialect:)
        super(options)
        @connection = connection
        @dialect = dialect.to_sym
        @connection_lock = Monitor.new
      end

      def create(model:, data:, force_allow_id: false)
        model = model.to_s
        input = transform_input(model, data, "create", force_allow_id)
        table = table_for(model)
        columns = input.keys.map { |field| storage_field(model, field) }
        params = input.keys.map { |field| input[field] }
        placeholders = params.each_index.map { |index| placeholder(index + 1) }
        returning = (dialect == :postgres) ? " RETURNING *" : ""
        sql = "INSERT INTO #{quote(table)} (#{columns.map { |column| quote(column) }.join(", ")}) VALUES (#{placeholders.join(", ")})#{returning}"
        rows = execute(sql, params)
        row = rows.first
        return normalize_record(model, row) if row

        lookup = create_lookup(model, input)
        lookup ? find_one(model: model, where: [lookup]) : input
      end

      def create_if_absent(model:, data:, conflict_field: "id", force_allow_id: true)
        model = model.to_s
        field = atomic_schema_field(schema_for(model).fetch(:fields), conflict_field)
        input = transform_input(model, data, "create", force_allow_id)
        raise APIError.new("BAD_REQUEST", message: "Missing conflict field #{conflict_field}") unless input.key?(field)

        columns = input.keys.map { |key| storage_field(model, key) }
        params = input.values
        values = params.each_index.map { |index| placeholder(index + 1) }.join(", ")
        table = quote(table_for(model))
        conflict_column = quote(storage_field(model, field))
        quoted_columns = columns.map { |column| quote(column) }.join(", ")

        case dialect
        when :postgres, :sqlite
          sql = "INSERT INTO #{table} (#{quoted_columns}) VALUES (#{values}) ON CONFLICT (#{conflict_column}) DO NOTHING RETURNING #{conflict_column}"
          !execute(sql, params).empty?
        when :mysql
          transaction { create_if_absent_mysql(model, field, input, table, quoted_columns, values, params) }
        when :mssql
          sql = "INSERT INTO #{table} (#{quoted_columns}) OUTPUT inserted.#{conflict_column} " \
            "SELECT #{values} WHERE NOT EXISTS (SELECT 1 FROM #{table} WITH (UPDLOCK, HOLDLOCK) WHERE #{conflict_column} = #{placeholder(params.length + 1)})"
          !execute(sql, params + [input.fetch(field)]).empty?
        else
          raise NotImplementedError, "create_if_absent is unsupported for #{dialect}"
        end
      end

      def find_one(model:, where: [], select: nil, join: nil)
        if collection_join?(model.to_s, join)
          find_many(model: model, where: where, select: select, join: join).first
        else
          find_many(model: model, where: where, select: select, join: join, limit: 1).first
        end
      end

      def find_many(model:, where: [], sort_by: nil, limit: nil, offset: nil, select: nil, join: nil)
        model = model.to_s
        params = []
        sql = +"SELECT "
        sql << "TOP (#{Integer(limit)}) " if dialect == :mssql && limit && !offset
        sql << select_sql(model, select, join)
        sql << " FROM "
        sql << quote(table_for(model))
        sql << join_sql(model, join)
        where_sql = build_where(model, where || [], params)
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        sql << order_sql(model, sort_by) if sort_by
        append_pagination_sql(sql, model, sort_by, limit, offset)

        records = execute(sql, params).map { |row| normalize_record(model, row, join: join) }
        collection_join?(model, join) ? aggregate_collection_joins(model, records, join) : records
      end

      def update(model:, where:, update:)
        model = model.to_s
        return nil if Array(where).empty?

        ensure_update_input_has_fields!(model, update)
        if dialect == :postgres
          records = update_many(model: model, where: where, update: update, returning: true)
          return records.is_a?(Array) ? records.first : records
        end

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
        params = []
        assignments = data.each_key.map do |field|
          params << data[field]
          "#{quote(storage_field(model, field))} = #{placeholder(params.length)}"
        end
        where_sql = build_where(model, where || [], params)
        sql = +"UPDATE "
        sql << quote(table_for(model))
        sql << " SET "
        sql << assignments.join(", ")
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        sql << " RETURNING *" if dialect == :postgres && returning
        result = execute(sql, params, affected_rows_result: !returning)
        return result.map { |row| normalize_record(model, row) } if returning

        affected_rows(result)
      end

      def delete(model:, where:)
        delete_many(model: model, where: where)
        nil
      end

      def delete_many(model:, where:, limit: nil)
        model = model.to_s
        params = []
        where_sql = build_where(model, where || [], params)
        sql = +"DELETE FROM "
        sql << quote(table_for(model))
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        sql << " LIMIT #{Integer(limit)}" if limit && dialect == :mysql
        result = execute(sql, params, affected_rows_result: true)
        affected_rows(result)
      end

      def count(model:, where: nil)
        model = model.to_s
        params = []
        where_sql = build_where(model, where || [], params)
        sql = +"SELECT COUNT(*) AS count FROM "
        sql << quote(table_for(model))
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        row = execute(sql, params).first || {}
        (row["count"] || row[:count] || 0).to_i
      end

      def consume_one(model:, where:)
        model = model.to_s
        case dialect
        when :postgres, :sqlite
          consume_one_with_returning(model, where)
        when :mssql
          consume_one_with_output(model, where)
        else
          transaction { consume_one_with_lock(model, where) }
        end
      end

      def increment_one(model:, where:, increment:, set: nil, allow_server_managed: false)
        model = model.to_s
        increments, assignments = normalize_atomic_update(model, increment, set, allow_server_managed)
        case dialect
        when :postgres, :sqlite
          increment_one_with_returning(model, where, increments, assignments)
        when :mssql
          increment_one_with_output(model, where, increments, assignments)
        else
          transaction { increment_one_with_lock(model, where, increments, assignments) }
        end
      end

      def transaction
        return yield active_transaction_adapter if active_transaction_adapter

        @connection_lock.synchronize do
          execute("BEGIN", [])
          result = with_transaction_context(self) { yield self }
          execute("COMMIT", [])
          result
        rescue
          execute("ROLLBACK", [])
          raise
        end
      end

      private

      def consume_one_with_returning(model, where)
        params = []
        where_sql = build_where(model, where || [], params)
        lookup = quote(storage_field(model, atomic_lookup_field(model)))
        lock = (dialect == :postgres) ? " FOR UPDATE" : ""
        table = quote(table_for(model))
        sql = "DELETE FROM #{table} WHERE #{lookup} IN (SELECT #{lookup} FROM #{table}"
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        sql << " LIMIT 1#{lock}) RETURNING *"
        normalize_record(model, execute(sql, params).first)
      end

      def consume_one_with_output(model, where)
        params = []
        where_sql = build_where(model, where || [], params)
        sql = "DELETE TOP (1) FROM #{quote(table_for(model))} OUTPUT deleted.*"
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        normalize_record(model, execute(sql, params).first)
      end

      def consume_one_with_lock(model, where)
        target = select_atomic_target(model, where)
        return nil unless target

        lookup = record_lookup(model, target)
        raise Error, "#{self.class} cannot atomically identify a #{model} row" unless lookup

        deleted = delete_many(model: model, where: [lookup], limit: 1)
        ensure_numeric_affected_rows!(deleted, "delete_many")
        deleted.positive? ? target : nil
      end

      def increment_one_with_returning(model, where, increments, assignments)
        params = []
        assignment_sql = atomic_assignments_sql(model, increments, assignments, params)
        where_sql = build_where(model, where || [], params)
        lookup = quote(storage_field(model, atomic_lookup_field(model)))
        lock = (dialect == :postgres) ? " FOR UPDATE" : ""
        table = quote(table_for(model))
        sql = "UPDATE #{table} SET #{assignment_sql} WHERE #{lookup} IN (SELECT #{lookup} FROM #{table}"
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        sql << " LIMIT 1#{lock}) RETURNING *"
        normalize_record(model, execute(sql, params).first)
      end

      def increment_one_with_output(model, where, increments, assignments)
        params = []
        assignment_sql = atomic_assignments_sql(model, increments, assignments, params)
        where_sql = build_where(model, where || [], params)
        sql = "UPDATE TOP (1) #{quote(table_for(model))} SET #{assignment_sql} OUTPUT inserted.*"
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        normalize_record(model, execute(sql, params).first)
      end

      def increment_one_with_lock(model, where, increments, assignments)
        target = select_atomic_target(model, where)
        return nil unless target

        lookup = record_lookup(model, target)
        raise Error, "#{self.class} cannot atomically identify a #{model} row" unless lookup

        params = []
        assignment_sql = atomic_assignments_sql(model, increments, assignments, params)
        guarded_where = Array(where) + [lookup.merge(connector: "AND")]
        where_sql = build_where(model, guarded_where, params)
        sql = "UPDATE #{quote(table_for(model))} SET #{assignment_sql} WHERE #{where_sql} LIMIT 1"
        affected = affected_rows(execute(sql, params, affected_rows_result: true))
        ensure_numeric_affected_rows!(affected, "update")
        find_one(model: model, where: [lookup])
      end

      def select_atomic_target(model, where)
        params = []
        where_sql = build_where(model, where || [], params)
        sql = "SELECT #{select_sql(model, nil, nil)} FROM #{quote(table_for(model))}"
        sql << " WHERE #{where_sql}" unless where_sql.empty?
        sql << " LIMIT 1 FOR UPDATE"
        normalize_record(model, execute(sql, params).first)
      end

      def normalize_atomic_update(model, increment, set, allow_server_managed)
        raise APIError.new("BAD_REQUEST", message: "increment must be a Hash") unless increment.is_a?(Hash)

        fields = schema_for(model).fetch(:fields)
        increments = increment.each_with_object({}) do |(field, delta), result|
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
        assignments = if set.nil? || set.empty?
          {}
        else
          ensure_update_input_has_fields!(model, set)
          transform_input(model, set, "update", true)
        end
        increments.reject! { |field, _delta| assignments.key?(field) }
        if increments.empty? && assignments.empty?
          raise APIError.new("BAD_REQUEST", message: "increment_one requires a non-empty increment or set")
        end

        [increments, assignments]
      end

      def atomic_assignments_sql(model, increments, assignments, params)
        increment_sql = increments.map do |field, delta|
          column = quote(storage_field(model, field))
          params << delta
          "#{column} = COALESCE(#{column}, 0) + #{placeholder(params.length)}"
        end
        set_sql = assignments.map do |field, value|
          params << value
          "#{quote(storage_field(model, field))} = #{placeholder(params.length)}"
        end
        (increment_sql + set_sql).join(", ")
      end

      def atomic_schema_field(fields, field)
        candidate = storage_key(field)
        return candidate if fields.key?(candidate)

        fields.find { |logical, attributes| storage_key(attributes[:field_name] || logical) == candidate }&.first
      end

      def create_if_absent_mysql(model, field, input, table, columns, values, params)
        savepoint = "better_auth_create_if_absent"
        execute("SAVEPOINT #{savepoint}", [])
        begin
          execute("INSERT INTO #{table} (#{columns}) VALUES (#{values})", params)
          execute("RELEASE SAVEPOINT #{savepoint}", [])
          true
        rescue => error
          execute("ROLLBACK TO SAVEPOINT #{savepoint}", [])
          execute("RELEASE SAVEPOINT #{savepoint}", [])
          existing = find_one(model: model, where: [{field: field, value: input.fetch(field)}])
          return false if mysql_duplicate_error?(error) && existing

          raise error
        end
      end

      def mysql_duplicate_error?(error)
        (error.respond_to?(:error_number) && error.error_number == 1062) ||
          (error.respond_to?(:errno) && error.errno == 1062)
      end

      def atomic_lookup_field(model)
        fields = schema_for(model).fetch(:fields)
        return "id" if fields.key?("id")

        unique = fields.find { |_field, attributes| attributes[:unique] }
        return unique.first if unique

        raise Error, "#{self.class} cannot atomically identify a #{model} row without an id or unique field"
      end

      def ensure_numeric_affected_rows!(value, operation)
        return value if value.is_a?(Numeric)

        raise Error, "#{self.class} returned a non-numeric affected-row result from #{operation}"
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
          output[field] = coerce_value(value, attributes) if value_provided
        end

        output["id"] = generated_id if action == "create" && !output.key?("id") && fields.key?("id")
        output
      end

      def create_lookup(model, input)
        fields = schema_for(model).fetch(:fields)
        return {field: "id", value: input.fetch("id")} if fields.key?("id") && input.key?("id")

        unique_field = fields.find { |field, attributes| attributes[:unique] && input.key?(field) }
        return {field: unique_field.first, value: input.fetch(unique_field.first)} if unique_field

        nil
      end

      def record_lookup(model, record)
        fields = schema_for(model).fetch(:fields)
        return {field: "id", value: record.fetch("id")} if fields.key?("id") && record.key?("id")

        unique_field = fields.find { |field, attributes| attributes[:unique] && record.key?(field) }
        return {field: unique_field.first, value: record.fetch(unique_field.first)} if unique_field

        nil
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

      def select_sql(model, select, join)
        fields = Array(select).empty? ? schema_for(model).fetch(:fields).keys : Array(select).map { |field| storage_key(field) }
        columns = fields.map do |field|
          column = storage_field(model, field)
          "#{quote(table_for(model))}.#{quote(column)} AS #{quote(column)}"
        end
        columns.concat(join_select_sql(model, join)) if join
        columns.join(", ")
      end

      def join_select_sql(model, join)
        normalized_join(model, join).flat_map do |join_model, _config|
          schema_for(join_model).fetch(:fields).map do |field, attributes|
            column = attributes[:field_name] || physical_name(field)
            "#{quote(join_model)}.#{quote(column)} AS #{quote("#{join_model}__#{column}")}"
          end
        end
      end

      def join_sql(model, join)
        return "" unless join

        normalized_join(model, join).map do |join_model, config|
          local_field = storage_field(model, config.fetch(:from))
          foreign_field = storage_field(join_model, config.fetch(:to))
          " LEFT JOIN #{quote(table_for(join_model))} AS #{quote(join_model)} ON #{quote(join_model)}.#{quote(foreign_field)} = #{quote(table_for(model))}.#{quote(local_field)}"
        end.join
      end

      def inferred_join_config(model, join_model)
        foreign_keys = schema_for(join_model).fetch(:fields).select do |_field, attributes|
          reference_model_matches?(attributes, model)
        end
        forward_join = true

        if foreign_keys.empty?
          foreign_keys = schema_for(model).fetch(:fields).select do |_field, attributes|
            reference_model_matches?(attributes, join_model)
          end
          forward_join = false
        end

        raise Error, "No foreign key found for model #{join_model} and base model #{model} while performing join operation." if foreign_keys.empty?
        raise Error, "Multiple foreign keys found for model #{join_model} and base model #{model} while performing join operation. Only one foreign key is supported." if foreign_keys.length > 1

        foreign_key, attributes = foreign_keys.first
        reference = attributes.fetch(:references)
        if forward_join
          unique = attributes[:unique] == true
          {from: reference.fetch(:field).to_s, to: foreign_key, relation: unique ? "one-to-one" : "one-to-many", unique: unique}
        else
          {from: foreign_key, to: reference.fetch(:field).to_s, relation: "one-to-one", unique: true}
        end
      end

      def build_where(model, where, params)
        and_clauses, or_clauses = grouped_where_clauses(where)
        and_sql = and_clauses.map { |clause| build_where_clause(model, clause, params) }
        or_sql = or_clauses.map { |clause| build_where_clause(model, clause, params) }
        return and_sql.join(" AND ") if or_sql.empty?
        return or_sql.join(" OR ") if and_sql.empty?

        "(#{and_sql.join(" AND ")}) AND (#{or_sql.join(" OR ")})"
      end

      def build_where_clause(model, clause, params)
        field = storage_key(fetch_key(clause, :field))
        column = "#{quote(table_for(model))}.#{quote(storage_field(model, field))}"
        operator = (fetch_key(clause, :operator) || "eq").to_s
        value = fetch_key(clause, :value)
        attributes = schema_for(model).fetch(:fields).fetch(field)
        insensitive = insensitive_string_predicate?(clause, attributes)
        predicate_column = insensitive ? "LOWER(#{column})" : column

        if value.nil? && %w[eq ne].include?(operator)
          null_operator = (operator == "ne") ? "IS NOT NULL" : "IS NULL"
          "#{column} #{null_operator}"
        else
          case operator
          when "in", "not_in"
            values = Array(value).map { |entry| insensitive ? entry.to_s.downcase : coerce_where_value(entry, attributes) }
            placeholders = values.map do |entry|
              params << entry
              placeholder(params.length)
            end.join(", ")
            sql_operator = (operator == "not_in") ? "NOT IN" : "IN"
            "#{predicate_column} #{sql_operator} (#{placeholders})"
          when "contains", "starts_with", "ends_with"
            escaped = escape_like(insensitive ? value.to_s.downcase : value)
            pattern = case operator
            when "starts_with" then "#{escaped}%"
            when "ends_with" then "%#{escaped}"
            else "%#{escaped}%"
            end
            params << pattern
            "#{predicate_column} LIKE #{placeholder(params.length)} ESCAPE #{escape_literal}"
          else
            params << (insensitive ? value.to_s.downcase : coerce_where_value(value, attributes))
            "#{predicate_column} #{sql_operator(operator)} #{placeholder(params.length)}"
          end
        end
      end

      def order_sql(model, sort_by)
        field = Schema.storage_key(fetch_key(sort_by, :field))
        direction = (fetch_key(sort_by, :direction).to_s.downcase == "desc") ? "DESC" : "ASC"
        " ORDER BY #{quote(table_for(model))}.#{quote(storage_field(model, field))} #{direction}"
      end

      def append_pagination_sql(sql, model, sort_by, limit, offset)
        if dialect == :mssql
          return if limit && !offset
          return unless offset

          sql << order_sql(model, {field: "id", direction: "asc"}) unless sort_by
          sql << " OFFSET #{Integer(offset)} ROWS"
          sql << " FETCH NEXT #{Integer(limit)} ROWS ONLY" if limit
          return
        end

        sql << " LIMIT #{Integer(limit)}" if limit
        sql << " OFFSET #{Integer(offset)}" if offset
      end

      def sql_operator(operator)
        {
          "ne" => "!=",
          "gt" => ">",
          "gte" => ">=",
          "lt" => "<",
          "lte" => "<="
        }.fetch(operator, "=")
      end

      def insensitive_string_predicate?(clause, attributes)
        fetch_key(clause, :mode).to_s == "insensitive" && attributes[:type] == "string"
      end

      def execute(sql, params, affected_rows_result: false)
        @connection_lock.synchronize do
          if connection.respond_to?(:exec_params)
            result = connection.exec_params(sql, params)
            return affected_rows_result ? result : [] if result.respond_to?(:fields) && result.fields.empty?
            return result.to_a if result.respond_to?(:to_a)

            result
          elsif connection.respond_to?(:query) && params.empty?
            result = connection.query(sql)
            result.respond_to?(:to_a) ? result.to_a : result
          elsif dialect == :sqlite && connection.respond_to?(:execute)
            result = connection.execute(sql, params)
            result.respond_to?(:to_a) ? result.to_a : result
          elsif connection.respond_to?(:prepare)
            statement = connection.prepare(sql)
            result = nil
            begin
              result = statement.execute(*params)
              if result.nil?
                return [] unless affected_rows_result
                return statement.affected_rows if statement.respond_to?(:affected_rows)
                return connection.affected_rows if connection.respond_to?(:affected_rows)
              end

              rows = result.respond_to?(:to_a) ? result.to_a : result
              rows
            ensure
              if result.respond_to?(:close)
                result.close
              elsif statement.respond_to?(:close)
                statement.close
              end
            end
          elsif connection.respond_to?(:execute)
            result = connection.execute(sql, params)
            result.respond_to?(:to_a) ? result.to_a : result
          else
            raise Error, "SQL connection must respond to exec_params or prepare"
          end
        end
      end

      def affected_rows(result)
        value = if result.respond_to?(:cmd_tuples)
          result.cmd_tuples
        elsif result.respond_to?(:affected_rows)
          result.affected_rows
        elsif result.is_a?(Numeric)
          result
        elsif connection.respond_to?(:affected_rows)
          connection.affected_rows
        elsif connection.respond_to?(:changes)
          connection.changes
        end
        ensure_numeric_affected_rows!(value, "SQL mutation")
      end

      def normalize_record(model, row, join: nil)
        return nil unless row

        fields = schema_for(model).fetch(:fields)
        record = fields.each_with_object({}) do |(field, attributes), output|
          column = attributes[:field_name] || physical_name(field)
          output[field] = coerce_output_value(fetch_row(row, column), attributes) if row_key?(row, column)
        end

        normalized_join(model, join).each_key do |join_model|
          record[join_model] = normalize_joined_record(join_model, row)
        end

        record
      end

      def normalize_joined_record(model, row)
        schema_for(model).fetch(:fields).each_with_object({}) do |(field, attributes), output|
          column = attributes[:field_name] || physical_name(field)
          key = "#{model}__#{column}"
          output[field] = coerce_output_value(fetch_row(row, key), attributes) if row_key?(row, key)
        end
      end

      def aggregate_collection_joins(model, records, join)
        join_config = normalized_join(model, join)
        grouped = {}
        records.each do |record|
          key = record.fetch("id")
          grouped[key] ||= begin
            base = record.reject { |field, _value| join_config.key?(field) }
            join_defaults = join_config.each_with_object({}) do |(join_model, config), defaults|
              defaults[join_model] = (config[:relation] == "one-to-one" || config[:unique] == true) ? nil : []
            end
            base.merge(join_defaults)
          end

          join_config.each do |join_model, config|
            joined = record[join_model]
            next unless joined&.values&.any?

            if config[:relation] == "one-to-one" || config[:unique] == true
              grouped[key][join_model] = joined
            else
              next if grouped[key][join_model].length >= join_limit(config)

              grouped[key][join_model] << joined
            end
          end
        end
        grouped.values
      end

      def row_key?(row, key)
        row.key?(key) || row.key?(key.to_sym)
      end

      def fetch_row(row, key)
        return row[key] if row.key?(key)

        row[key.to_sym]
      end

      def table_for(model)
        schema_for(model).fetch(:model_name)
      end

      def schema_for(model)
        Schema.auth_tables(options).fetch(model.to_s)
      end

      def storage_field(model, field)
        schema_for(model).fetch(:fields).fetch(field.to_s).fetch(:field_name, physical_name(field))
      end

      def quote(identifier)
        Schema::SQL.quote(identifier, dialect)
      end

      def placeholder(index)
        (dialect == :postgres) ? "$#{index}" : "?"
      end

      def generated_id
        generator = options.advanced.dig(:database, :generate_id)
        return generator.call.to_s if generator.respond_to?(:call)
        return SecureRandom.uuid if generator == "uuid"

        SecureRandom.hex(16)
      end

      def escape_like(value)
        value.to_s.gsub(/[!%_]/) { |match| "!#{match}" }
      end

      def escape_literal
        "'!'"
      end

      def resolve_default(default)
        default.respond_to?(:call) ? default.call : default
      end

      def coerce_value(value, attributes)
        return value if value.nil?
        return value ? 1 : 0 if dialect == :sqlite && attributes[:type] == "boolean"
        if dialect == :sqlite && attributes[:type] == "date"
          value = Time.parse(value) if value.is_a?(String)
          return value.iso8601(6) if value.respond_to?(:iso8601)
        end
        return Time.parse(value) if attributes[:type] == "date" && value.is_a?(String)
        return JSON.generate(value) if json_like?(attributes) && !value.is_a?(String)
        return value.encode(Encoding::UTF_8) if attributes[:type] == "string" && value.is_a?(String) && value.encoding == Encoding::ASCII_8BIT

        value
      end

      def coerce_where_value(value, attributes)
        return value if value.nil?

        case attributes[:type]
        when "boolean"
          return coerce_value(false, attributes) if value == false || value == 0 || value.to_s.downcase == "false" || value.to_s == "0"
          return coerce_value(true, attributes) if value == true || value == 1 || value.to_s.downcase == "true" || value.to_s == "1"
        when "number"
          return coerce_number(value)
        when "date"
          return Time.parse(value) if value.is_a?(String)
        end

        coerce_value(value, attributes)
      end

      def coerce_output_value(value, attributes)
        return value if value.nil?
        return coerce_boolean(value) if attributes[:type] == "boolean"
        return coerce_number(value) if attributes[:type] == "number"
        return Time.parse(value) if attributes[:type] == "date" && value.is_a?(String)
        return parse_json_value(value) if json_like?(attributes) && value.is_a?(String)

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

      def coerce_boolean(value)
        return value if value == true || value == false
        return false if value == 0 || value.to_s == "0" || value.to_s.downcase == "f" || value.to_s.downcase == "false"
        return true if value == 1 || value.to_s == "1" || value.to_s.downcase == "t" || value.to_s.downcase == "true"

        value
      end

      def coerce_number(value)
        return value unless value.is_a?(String)
        return value.to_i if /\A-?\d+\z/.match?(value)
        return value.to_f if /\A-?\d+\.\d+\z/.match?(value)

        value
      end

      def stringify_keys(data)
        data.each_with_object({}) do |(key, value), result|
          result[storage_key(key)] = value
        end
      end

      def fetch_key(hash, key)
        [key, key.to_s, storage_key(key), storage_key(key).to_sym].each do |candidate|
          return hash[candidate] if hash.key?(candidate)
        end
        nil
      end

      def storage_key(value)
        parts = physical_name(value).split("_")
        ([parts.first] + parts.drop(1).map(&:capitalize)).join
      end

      def physical_name(value)
        value.to_s
          .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
          .tr("-", "_")
          .downcase
      end
    end
  end
end
