# frozen_string_literal: true

require_relative "plugin_loader"

module BetterAuth
  module Plugins
    module_function

    def normalize_hash(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, object), result|
        result[normalize_key(key)] = object.is_a?(Hash) ? normalize_hash(object) : object
      end
    end

    def normalize_key(key)
      key.to_s
        .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
        .tr("-", "_")
        .downcase
        .to_sym
    end

    def storage_fields(fields)
      normalize_hash(fields).each_with_object({}) do |(key, value), result|
        result[Schema.storage_key(key)] = normalize_field(value)
      end
    end

    def normalize_field(value)
      data = normalize_hash(value || {})
      data[:default_value] = data.delete(:defaultValue) if data.key?(:defaultValue)
      data[:field_name] = data.delete(:fieldName) if data.key?(:fieldName)
      data
    end

    def fetch_value(data, key)
      return nil unless data.respond_to?(:[])

      data[key] || data[key.to_s] || data[Schema.storage_key(key)] || data[Schema.storage_key(key).to_sym] || data[normalize_key(key)]
    end

    def deep_merge_hashes(base, override)
      base.merge(override) do |_key, old_value, new_value|
        if old_value.is_a?(Hash) && new_value.is_a?(Hash)
          deep_merge_hashes(old_value, new_value)
        else
          new_value
        end
      end
    end

    def cookie_header_from_set_cookie(set_cookie)
      set_cookie.to_s.lines.map { |line| line.split(";").first }.join("; ")
    end

    PLUGIN_FACTORY_LOADERS = {
      create_access_control: :access,
      createAccessControl: :access
    }.freeze

    def method_missing(name, ...)
      if (loader = plugin_loader_for_method(name))
        load_plugin!(loader)
        return public_send(name, ...) if respond_to?(name, true)

        raise NoMethodError, "plugin file for #{loader} did not define BetterAuth::Plugins.#{name}"
      end

      if (loader = PLUGIN_FACTORY_LOADERS[name.to_sym])
        load_plugin!(loader)
        return public_send(name, ...) if respond_to?(name, true)

        raise NoMethodError, "plugin file for #{loader} did not define BetterAuth::Plugins.#{name}"
      end

      super
    end

    def respond_to_missing?(name, include_private = false)
      PLUGIN_FACTORY_LOADERS.key?(name.to_sym) || !plugin_loader_for_method(name).nil? || super
    end

    def const_missing(name)
      load_plugin_for_constant!(name)
      return const_get(name) if const_defined?(name, false)

      super
    end
  end
end
