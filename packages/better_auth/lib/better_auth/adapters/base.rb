# frozen_string_literal: true

module BetterAuth
  module Adapters
    class Base
      attr_reader :options

      def initialize(options)
        @options = options
      end

      def create(**)
        raise NotImplementedError
      end

      def find_one(**)
        raise NotImplementedError
      end

      def find_many(**)
        raise NotImplementedError
      end

      def update(**)
        raise NotImplementedError
      end

      def update_many(**)
        raise NotImplementedError
      end

      def delete(**)
        raise NotImplementedError
      end

      def delete_many(**)
        raise NotImplementedError
      end

      def count(**)
        raise NotImplementedError
      end

      def transaction
        yield self
      end

      private

      def grouped_where_clauses(where)
        Array(where).partition { |clause| fetch_key(clause, :connector).to_s.upcase != "OR" }
      end

      def fetch_key(hash, key)
        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end
    end
  end
end
