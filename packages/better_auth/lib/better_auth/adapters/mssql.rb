# frozen_string_literal: true

module BetterAuth
  module Adapters
    class MSSQL < SQL
      attr_reader :url

      def initialize(options = nil, url: nil, connection: nil)
        unless connection
          require "sequel"
          require "tiny_tds"
        end

        config = options || Configuration.new(secret: Configuration::DEFAULT_SECRET, database: :memory)
        @url = url
        super(config, connection: connection || Sequel.connect(url), dialect: :mssql)
      end

      def transaction
        return yield active_transaction_adapter if active_transaction_adapter
        return super unless connection.respond_to?(:transaction)

        connection.transaction { with_transaction_context(self) { yield self } }
      end

      private

      def execute(sql, params, affected_rows_result: false)
        if connection.respond_to?(:fetch)
          dataset = connection.fetch(sql, *params)
          return dataset.delete if affected_rows_result

          dataset.all.map { |row| stringify_row(row) }
        else
          super
        end
      end

      def stringify_row(row)
        row.each_with_object({}) do |(key, value), result|
          result[key.to_s] = value
        end
      end
    end
  end
end
