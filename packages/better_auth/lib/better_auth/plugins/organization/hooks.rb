# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def run_org_hook(config, key, data, ctx)
      hooks = org_hook_candidates(config, key)
      hooks.concat(ctx.context.options.plugins.flat_map { |plugin| org_hook_candidates(plugin_options(plugin), key) }) if ctx&.context&.options
      hooks.compact.uniq.filter_map { |hook| hook.call(data, ctx) if hook.respond_to?(:call) }.find { |response| response.is_a?(Hash) && normalize_hash(response).key?(:data) }
    end

    def org_hook_candidates(options, key)
      data = normalize_hash(options || {})
      camel_key = camelize_lower(key)
      candidates = [
        data.dig(:organization_hooks, key),
        data.dig(:organization_hooks, camel_key),
        data.dig(:hooks, key),
        data.dig(:hooks, camel_key)
      ]
      if options.respond_to?(:dig)
        candidates << options.dig("organizationHooks", camel_key)
        candidates << options.dig("organizationHooks", key.to_s)
        candidates << options.dig(:organizationHooks, camel_key)
        candidates << options.dig(:organizationHooks, key.to_s)
      end
      candidates
    end

    def plugin_options(plugin)
      plugin.respond_to?(:dig) ? (plugin.dig(:options) || plugin.dig("options") || {}) : {}
    end

    def camelize_lower(key)
      parts = key.to_s.split("_")
      ([parts.first] + parts.drop(1).map(&:capitalize)).join
    end

    def merge_hook_data!(target, response)
      data = if response.is_a?(Hash)
        normalize_hash(response)[:data]
      end
      target.merge!(normalize_hash(data)) if data.is_a?(Hash)
      target
    end
  end
end
