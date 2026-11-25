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
        reference_model.to_s == model.to_s || reference_model.to_s == schema_for(model).fetch(:model_name)
      end

      def inferred_join_config(model, join_model)
        foreign_keys = schema_for(join_model).fetch(:fields).select do |_field, attributes|
          reference_model_matches?(attributes, model)
        end
        forward_join = !foreign_keys.empty?

        unless forward_join
          foreign_keys = schema_for(model).fetch(:fields).select do |_field, attributes|
            reference_model_matches?(attributes, join_model)
          end
        end

        raise Error, "No foreign key found for model #{join_model} and base model #{model} while performing join operation." if foreign_keys.empty?
        raise Error, "Multiple foreign keys found for model #{join_model} and base model #{model} while performing join operation. Only one foreign key is supported." if foreign_keys.length > 1

        foreign_key, attributes = foreign_keys.first
        referenced_field = attributes.fetch(:references).fetch(:field).to_s
        from, to = forward_join ? [referenced_field, foreign_key] : [foreign_key, referenced_field]
        target_column = schema_for(join_model).fetch(:fields).fetch(to, {}).fetch(:field_name, to)
        unique = target_column == "id" || attributes[:unique] == true
        {from: from, to: to, relation: unique ? "one-to-one" : "one-to-many", unique: unique}
      end

      def projected_join_fields(select, join)
        return [] unless select

        Array(select).map { |field| storage_key(field) } | join.values.map { |config| config.fetch(:from) }
      end

      def one_to_one_join?(config)
        config[:relation] == "one-to-one" || config[:unique] == true
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
        return default_find_many_limit if value.nil?

        Integer(value)
      rescue ArgumentError, TypeError
        default_find_many_limit
      end
    end
  end
end
