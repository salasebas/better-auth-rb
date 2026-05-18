# frozen_string_literal: true

module BetterAuth
  module Grape
    module Extension
      def self.included(base)
        base.extend ClassMethods
        base.helpers Helpers if base.respond_to?(:helpers)
      end

      module ClassMethods
        attr_reader :better_auth_auth, :better_auth_mount_path

        def better_auth(at: BetterAuth::Configuration::DEFAULT_BASE_PATH, auth: nil, **overrides)
          mount_path = effective_better_auth_mount_path(at)
          if mount_path == "/"
            raise ArgumentError,
              "better_auth mount path cannot be '/' (it would capture every request). " \
              "Use a prefix such as #{BetterAuth::Configuration::DEFAULT_BASE_PATH.inspect}."
          end
          raise ArgumentError, "better_auth is already configured for this API" if @better_auth_auth

          config = BetterAuth::Grape.configuration.copy
          yield config if block_given?
          config.base_path = mount_path
          options = config.to_auth_options.merge(overrides).merge(base_path: mount_path)
          auth_instance = auth || BetterAuth.auth(options)
          @better_auth_auth = auth_instance
          @better_auth_mount_path = mount_path

          mounted_app = BetterAuth::Grape::MountedApp.new(auth_instance, mount_path: mount_path)
          helpers do
            define_method(:better_auth_auth) { auth_instance }
          end
          mount({mounted_app => mount_path})
          route_setting :better_auth_internal, true
          route(:any, "/*better_auth_path") do
            path_info = env.fetch("PATH_INFO", "").to_s
            normalized_path_info = path_info.start_with?("/") ? path_info.squeeze("/") : "/#{path_info}".squeeze("/")
            script_name = env.fetch("SCRIPT_NAME", "").to_s
            normalized_script_name = script_name.start_with?("/") ? script_name.squeeze("/") : "/#{script_name}".squeeze("/")
            unless normalized_path_info == mount_path ||
                normalized_path_info.start_with?("#{mount_path}/") ||
                normalized_script_name == mount_path ||
                normalized_script_name.end_with?(mount_path)
              error!({error: "Not Found"}, 404)
            end

            rack_status, rack_headers, rack_body = mounted_app.call(env)
            status rack_status
            rack_headers.each { |key, value| header key, value }
            env[::Grape::Env::API_FORMAT] = :txt
            body rack_body.each.to_a.join
            nil
          end
        end

        private

        def effective_better_auth_mount_path(path)
          mount_path = normalize_better_auth_mount_path(path)
          api_prefix = better_auth_api_prefix
          return mount_path if api_prefix == "/"
          return mount_path if mount_path == api_prefix || mount_path.start_with?("#{api_prefix}/")

          normalize_better_auth_mount_path("#{api_prefix}/#{mount_path.delete_prefix("/")}")
        end

        def better_auth_api_prefix
          parts = [better_auth_root_prefix]
          version_prefix = better_auth_path_version_prefix
          parts << version_prefix unless version_prefix == "/"
          normalize_better_auth_mount_path(parts.reject { |part| part == "/" }.join("/"))
        end

        def better_auth_root_prefix
          return "/" unless respond_to?(:prefix)

          configured_prefix = prefix
          return "/" if configured_prefix.nil? || configured_prefix.to_s.empty?

          normalize_better_auth_mount_path(configured_prefix)
        end

        def better_auth_path_version_prefix
          settings = inheritable_setting.namespace_inheritable if respond_to?(:inheritable_setting)
          version_options = settings&.[](:version_options) || {}
          return "/" unless version_options[:using]&.to_sym == :path

          versions = settings&.[](:version)
          version = Array(versions).first
          return "/" if version.nil? || version.to_s.empty?

          normalize_better_auth_mount_path(version)
        end

        def normalize_better_auth_mount_path(path)
          normalized = path.to_s
          normalized = "/#{normalized}" unless normalized.start_with?("/")
          normalized = normalized.squeeze("/")
          (normalized == "/") ? normalized : normalized.delete_suffix("/")
        end
      end
    end
  end
end
