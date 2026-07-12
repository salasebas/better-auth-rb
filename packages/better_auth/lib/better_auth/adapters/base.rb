# frozen_string_literal: true

module BetterAuth
  module Adapters
    class Base
      attr_reader :options

      TRANSACTION_CONTEXT_KEY = :better_auth_adapter_transaction_context

      def initialize(options, transaction_context_key: nil)
        @options = options
        @transaction_context_key = transaction_context_key || Object.new
      end

      def create(**)
        raise NotImplementedError
      end

      # Atomically insert a row unless +conflict_field+ already exists. Adapter
      # implementations must not emulate this with a check followed by create.
      def create_if_absent(model:, data:, conflict_field: "id", force_allow_id: true)
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

      # Atomically delete and return at most one matching row. Concurrent
      # consumers of the same row must produce exactly one non-nil result.
      def consume_one(**)
        raise NotImplementedError
      end

      # Atomically apply signed numeric deltas, with +where+ acting as the
      # selector and guard, and return the resulting row or nil on a miss.
      def increment_one(**)
        raise NotImplementedError
      end

      def transaction
        yield self
      end

      # The base yield preserves compatibility for non-atomic batch work. It
      # must never be used as proof that a check-then-act fallback is atomic.
      def atomic_transactions?
        false
      end

      private

      attr_reader :transaction_context_key

      def active_transaction_adapter
        Thread.current[TRANSACTION_CONTEXT_KEY]&.fetch(transaction_context_key, nil)
      end

      def with_transaction_context(transaction_adapter)
        context = Thread.current[TRANSACTION_CONTEXT_KEY] ||= {}
        had_previous = context.key?(transaction_context_key)
        previous = context[transaction_context_key]
        context[transaction_context_key] = transaction_adapter
        yield
      ensure
        if had_previous
          context[transaction_context_key] = previous
        else
          context&.delete(transaction_context_key)
          Thread.current[TRANSACTION_CONTEXT_KEY] = nil if context&.empty?
        end
      end

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
