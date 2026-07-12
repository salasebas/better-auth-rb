# frozen_string_literal: true

module BetterAuth
  module Adapters
    module JoinSupport
      private

      def normalized_join(model, join)
        return {} unless join

        join.each_with_object({}) do |(join_model, config), result|
          join_model = join_model.to_s
          result[join_model] = normalize_join_config(model.to_s, join_model, config)
        end
      end

      def normalize_join_config(model, join_model, config)
        if config.is_a?(Hash) && (config.key?(:on) || config.key?("on"))
          on = config[:on] || config["on"]
          from = storage_key(fetch_key(on, :from))
          to = storage_key(fetch_key(on, :to))
          relation = config[:relation] || config["relation"]
          limit = config[:limit] || config["limit"]
          return {from: from, to: to, relation: relation, limit: limit, unique: unique_join_field?(join_model, to)}
        end

        inferred = inferred_join_config(model, join_model)
        if config.is_a?(Hash)
          relation = config[:relation] || config["relation"]
          limit = config[:limit] || config["limit"]
          inferred = inferred.merge(relation: relation) if relation
          inferred = inferred.merge(limit: limit) if limit
        end
        inferred
      end

      def reference_model_matches?(attributes, model)
        reference = attributes[:references]
        return false unless reference

        reference_model = reference[:model] || reference["model"]
        reference_model.to_s == model.to_s || reference_model.to_s == table_for(model)
      end

      def unique_join_field?(model, field)
        field = storage_key(field)
        field == "id" || schema_for(model).fetch(:fields).dig(field, :unique) == true
      end

      def collection_join?(model, join)
        normalized_join(model, join).any? do |_join_model, config|
          if config.key?(:relation)
            config[:relation] != "one-to-one" && config[:unique] != true
          elsif config.key?(:collection)
            config[:collection] == true
          else
            false
          end
        end
      end

      def join_limit(config)
        value = config[:limit]
        return 100 if value.nil?

        parsed = Integer(value)
        parsed.positive? ? parsed : 100
      rescue ArgumentError, TypeError
        100
      end
    end
  end
end
