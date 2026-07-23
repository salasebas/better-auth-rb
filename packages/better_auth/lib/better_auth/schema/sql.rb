# frozen_string_literal: true

module BetterAuth
  module Schema
    module SQL
      module_function

      def create_statements(options, dialect:)
        dialect = dialect.to_sym
        tables = Schema.migration_tables(options)
        delete_actions = mssql_delete_actions(tables, dialect)
        statements = tables.map do |logical_name, table|
          create_table_statement(logical_name, table, dialect, tables, delete_actions: delete_actions)
        end
        statements.concat(tables.flat_map { |_logical_name, table| index_statements(table, dialect) })
      end

      def pending_statements(plan)
        delete_actions = mssql_delete_actions(plan.tables, plan.dialect)
        statements = plan.to_create.map do |change|
          create_table_statement(change.logical_name, change.table, plan.dialect, plan.tables, delete_actions: delete_actions)
        end
        statements.concat(plan.to_add.flat_map do |change|
          change.fields.map do |logical_field, attributes|
            if logical_name(logical_field, attributes) == "id" && plan.dialect == :postgres
              add_postgres_id_column_statements(change.table_name)
            else
              add_column_statement(change.table_name, logical_field, attributes, plan.dialect)
            end
          end
        end.flatten)
        statements.concat(plan.to_index.map do |change|
          index_statement(
            change.table_name,
            change.field_name,
            change.name,
            plan.dialect,
            unique: change.unique,
            where_not_null: filtered_unique_index?(change.field, plan.dialect)
          )
        end)
      end

      def create_table_statement(logical_name, table, dialect, tables = nil, delete_actions: nil)
        table_name = table.fetch(:model_name)
        columns = table.fetch(:fields).map do |logical_field, attributes|
          column_definition(table_name, logical_field, attributes, dialect)
        end
        constraints = table.fetch(:fields).flat_map do |logical_field, attributes|
          field_constraints(table_name, logical_field, attributes, dialect, tables, delete_actions: delete_actions)
        end
        body = (columns + constraints).join(",\n  ")

        case dialect
        when :postgres, :sqlite
          %(CREATE TABLE IF NOT EXISTS #{quote(table_name, dialect)} (\n  #{body}\n);)
        when :mysql
          %(CREATE TABLE IF NOT EXISTS #{quote(table_name, dialect)} (\n  #{body}\n) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;)
        when :mssql
          %(#{mssql_required_set_options}\nIF OBJECT_ID(N'#{quote(table_name, dialect)}', N'U') IS NULL\nCREATE TABLE #{quote(table_name, dialect)} (\n  #{body}\n);)
        else
          raise ArgumentError, "Unsupported SQL dialect: #{dialect}"
        end
      end

      def column_definition(table_name, logical_field, attributes, dialect)
        column = quote(attributes[:field_name] || physical_name(logical_field), dialect)
        parts = [column, sql_type(logical_name(logical_field, attributes), attributes, dialect)]
        parts << "PRIMARY KEY" if logical_name(logical_field, attributes) == "id"
        if attributes[:required]
          parts << "NOT NULL"
        elsif dialect == :mssql
          parts << "NULL"
        end
        default = default_sql(attributes, dialect)
        parts << "DEFAULT #{default}" if default
        parts.join(" ")
      end

      def field_constraints(table_name, logical_field, attributes, dialect, tables = nil, delete_actions: nil)
        constraints = []
        column = attributes[:field_name] || physical_name(logical_field)

        if attributes[:unique] && logical_name(logical_field, attributes) != "id" && !(dialect == :mssql && !attributes[:required])
          constraints << unique_constraint(table_name, column, dialect)
        end

        reference = attributes[:references]
        if reference
          constraints << foreign_key_constraint(table_name, column, reference, dialect, tables, delete_actions: delete_actions)
        end

        constraints
      end

      def index_statements(table, dialect)
        table_name = table.fetch(:model_name)
        table.fetch(:fields).filter_map do |logical_field, attributes|
          nullable_unique_mssql = dialect == :mssql && attributes[:unique] && logical_name(logical_field, attributes) != "id" && !attributes[:required]
          next if attributes[:unique] && !nullable_unique_mssql
          next unless attributes[:index] || nullable_unique_mssql

          column = attributes[:field_name] || Schema.physical_name(logical_field)
          unique = attributes[:unique] && dialect == :mssql
          name = unique ? "uniq_#{table_name}_#{column}" : "index_#{table_name}_on_#{column}"
          index_statement(table_name, column, name, dialect, unique: unique, where_not_null: filtered_unique_index?(attributes, dialect))
        end
      end

      def add_column_statement(table_name, logical_field, attributes, dialect)
        keyword = (dialect == :mssql) ? "ADD" : "ADD COLUMN"
        %(ALTER TABLE #{quote(table_name, dialect)} #{keyword} #{column_definition(table_name, logical_field, attributes, dialect)};)
      end

      def add_postgres_id_column_statements(table_name)
        quoted_table = quote(table_name, :postgres)
        quoted_id = quote("id", :postgres)
        [
          %(ALTER TABLE #{quoted_table} ADD COLUMN #{quoted_id} text;),
          %(UPDATE #{quoted_table} SET #{quoted_id} = md5(random()::text || clock_timestamp()::text || ctid::text) WHERE #{quoted_id} IS NULL;),
          %(ALTER TABLE #{quoted_table} ALTER COLUMN #{quoted_id} SET NOT NULL;),
          %(ALTER TABLE #{quoted_table} ADD PRIMARY KEY (#{quoted_id});)
        ]
      end

      def index_statement(table_name, column, name, dialect, unique: false, where_not_null: false)
        unique_prefix = unique ? "UNIQUE " : ""
        case dialect
        when :postgres, :sqlite
          %(CREATE #{unique_prefix}INDEX IF NOT EXISTS #{quote(name, dialect)} ON #{quote(table_name, dialect)} (#{quote(column, dialect)});)
        when :mysql
          %(CREATE #{unique_prefix}INDEX #{quote(name, dialect)} ON #{quote(table_name, dialect)} (#{quote(column, dialect)});)
        when :mssql
          filter = where_not_null ? " WHERE #{quote(column, dialect)} IS NOT NULL" : ""
          %(#{mssql_required_set_options}\nIF NOT EXISTS (SELECT name FROM sys.indexes WHERE name = '#{name.gsub("'", "''")}' AND object_id = OBJECT_ID(N'#{quote(table_name, dialect)}')) CREATE #{unique_prefix}INDEX #{quote(name, dialect)} ON #{quote(table_name, dialect)} (#{quote(column, dialect)})#{filter};)
        end
      end

      def filtered_unique_index?(attributes, dialect)
        dialect == :mssql && attributes[:unique] && !attributes[:required]
      end

      def mssql_required_set_options
        <<~SQL.strip
          SET ANSI_NULLS ON;
          SET QUOTED_IDENTIFIER ON;
          SET ANSI_WARNINGS ON;
          SET ANSI_PADDING ON;
          SET CONCAT_NULL_YIELDS_NULL ON;
          SET ARITHABORT ON;
          SET NUMERIC_ROUNDABORT OFF;
        SQL
      end

      def sql_type(logical_field, attributes, dialect)
        type = attributes[:type] || "string"
        case type
        when "boolean"
          case dialect
          when :mysql
            "tinyint(1)"
          when :sqlite
            "integer"
          when :mssql
            "smallint"
          else
            "boolean"
          end
        when "date"
          case dialect
          when :mysql
            "datetime(6)"
          when :sqlite
            "date"
          when :mssql
            "datetime2(3)"
          else
            "timestamptz"
          end
        when "number"
          attributes[:bigint] ? "bigint" : "integer"
        when "json", "string[]", "number[]"
          case dialect
          when :postgres
            "jsonb"
          when :mysql
            "json"
          when :mssql
            "varchar(8000)"
          else
            "text"
          end
        when "string"
          indexed_string_sql_type(logical_field, attributes, dialect)
        else
          raise BetterAuth::Error, "Unsupported field type: #{type}"
        end
      end

      def indexed_string_sql_type(logical_field, attributes, dialect)
        if dialect == :mysql
          indexed = logical_field == "id" || attributes[:unique] || attributes[:index] || attributes[:references] || attributes[:sortable] || attributes.key?(:default_value)
          indexed ? "varchar(191)" : "text"
        elsif dialect == :mssql
          indexed = logical_field == "id" || attributes[:unique] || attributes[:index] || attributes[:references] || attributes[:sortable]
          indexed ? "varchar(255)" : "varchar(8000)"
        else
          "text"
        end
      end

      def default_sql(attributes, dialect)
        default = attributes[:default_value]
        return unless default == false || default == true || default.is_a?(Numeric) || default.is_a?(String) || default.respond_to?(:call)

        if attributes[:type] == "date" && default.respond_to?(:call)
          return (dialect == :mysql) ? "CURRENT_TIMESTAMP(6)" : "CURRENT_TIMESTAMP"
        end

        case default
        when true
          (dialect == :mysql || dialect == :sqlite || dialect == :mssql) ? "1" : "true"
        when false
          (dialect == :mysql || dialect == :sqlite || dialect == :mssql) ? "0" : "false"
        when Numeric
          default.to_s
        when String
          "'#{default.gsub("'", "''")}'"
        end
      end

      def unique_constraint(table_name, column, dialect)
        case dialect
        when :postgres, :sqlite
          %(UNIQUE (#{quote(column, dialect)}))
        when :mysql
          %(UNIQUE KEY #{quote("uniq_#{table_name}_#{column}", dialect)} (#{quote(column, dialect)}))
        when :mssql
          %(CONSTRAINT #{quote("uniq_#{table_name}_#{column}", dialect)} UNIQUE (#{quote(column, dialect)}))
        end
      end

      def foreign_key_constraint(table_name, column, reference, dialect, tables = nil, delete_actions: nil)
        target_table = foreign_key_target_table(reference, tables)
        target_model = target_table&.fetch(:model_name) || reference.fetch(:model)
        target_field = foreign_key_target_field(reference, target_table)
        delete_action = delete_actions&.fetch([table_name.to_s, column.to_s], reference[:on_delete]) || reference[:on_delete]
        on_delete = delete_action ? " ON DELETE #{delete_action.to_s.upcase}" : ""

        case dialect
        when :postgres, :sqlite
          %(FOREIGN KEY (#{quote(column, dialect)}) REFERENCES #{quote(target_model, dialect)} (#{quote(target_field, dialect)})#{on_delete})
        when :mysql
          %(CONSTRAINT #{quote("fk_#{table_name}_#{column}", dialect)} FOREIGN KEY (#{quote(column, dialect)}) REFERENCES #{quote(target_model, dialect)} (#{quote(target_field, dialect)})#{on_delete})
        when :mssql
          %(CONSTRAINT #{quote("fk_#{table_name}_#{column}", dialect)} FOREIGN KEY (#{quote(column, dialect)}) REFERENCES #{quote(target_model, dialect)} (#{quote(target_field, dialect)})#{on_delete})
        end
      end

      def mssql_delete_actions(tables, dialect)
        return unless dialect.to_sym == :mssql

        graph = {}
        tables.each_with_object({}) do |(_logical_name, table), actions|
          child = table.fetch(:model_name).to_s
          table.fetch(:fields).each do |logical_field, attributes|
            reference = attributes[:references]
            next unless reference

            column = (attributes[:field_name] || physical_name(logical_field)).to_s
            action = reference[:on_delete]&.to_s
            key = [child, column]
            unless mssql_cascading_action?(action)
              actions[key] = action
              next
            end

            target_table = foreign_key_target_table(reference, tables)
            parent = (target_table&.fetch(:model_name) || reference.fetch(:model)).to_s
            if mssql_cascade_conflict?(graph, parent, child)
              actions[key] = "no action"
            else
              graph[parent] ||= []
              graph[parent] << child unless graph[parent].include?(child)
              actions[key] = action
            end
          end
        end
      end

      def mssql_cascading_action?(action)
        %w[cascade set\ null set\ default].include?(action.to_s.downcase.tr("_", " "))
      end

      def mssql_cascade_conflict?(graph, parent, child)
        nodes = (graph.keys + graph.values.flatten + [parent, child]).uniq
        nodes.any? do |source|
          mssql_reachable?(graph, source, parent) && mssql_reachable?(graph, source, child)
        end
      end

      def mssql_reachable?(graph, source, target, visited = {})
        return true if source == target
        return false if visited[source]

        visited[source] = true
        Array(graph[source]).any? { |child| mssql_reachable?(graph, child, target, visited) }
      end

      def foreign_key_target_table(reference, tables)
        return unless tables

        model = reference.fetch(:model).to_s
        tables.fetch(model, nil) || tables.each_value.find { |table| table.fetch(:model_name).to_s == model }
      end

      def foreign_key_target_field(reference, target_table)
        field = reference.fetch(:field).to_s
        return field unless target_table

        fields = target_table.fetch(:fields)
        attributes = fields.fetch(field, nil)
        return attributes[:field_name] || physical_name(field) if attributes

        if fields.each_value.any? { |data| data[:field_name].to_s == field }
          field
        else
          physical_name(field)
        end
      end

      def quote(identifier, dialect)
        case dialect
        when :postgres, :sqlite
          %("#{identifier.to_s.gsub("\"", "\"\"")}")
        when :mysql
          "`#{identifier.to_s.gsub("`", "``")}`"
        when :mssql
          "[#{identifier.to_s.gsub("]", "]]")}]"
        else
          raise ArgumentError, "Unsupported SQL dialect: #{dialect}"
        end
      end

      def physical_name(value)
        value.to_s
          .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
          .tr("-", "_")
          .downcase
      end

      def logical_name(logical_field, attributes)
        (attributes[:logical_name] || logical_field).to_s
      end
    end
  end
end
