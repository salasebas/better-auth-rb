# frozen_string_literal: true

module BetterAuth
  module MigrationPlan
    TableChange = Struct.new(:logical_name, :table_name, :table, :order)
    FieldChange = Struct.new(:logical_name, :table_name, :fields, :table, :order)
    IndexChange = Struct.new(:table_name, :field_name, :name, :unique, :field)

    Plan = Struct.new(:to_create, :to_add, :to_index, :warnings, :dialect, :tables) do
      def empty?
        to_create.empty? && to_add.empty? && to_index.empty?
      end
    end
  end
end
