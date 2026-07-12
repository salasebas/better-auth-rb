# frozen_string_literal: true

require "uri"

module BetterAuth
  class Context
    attr_reader :app_name,
      :version,
      :options,
      :social_providers,
      :adapter,
      :internal_adapter,
      :logger,
      :session_config,
      :rate_limit_config,
      :secret,
      :secret_config

    def initialize(configuration)
      @app_name = configuration.app_name
      @canonical_base_url = configuration.context_base_url
      @base_url = @canonical_base_url
      @version = BetterAuth::VERSION
      @options = configuration
      @social_providers = configuration.social_providers
      @auth_cookies = Cookies.get_cookies(configuration)
      @cookies = @auth_cookies
      @adapter = configuration.database
      @internal_adapter = nil
      @logger = configuration.logger
      @session_config = configuration.session
      @rate_limit_config = configuration.rate_limit
      @trusted_origins = configuration.trusted_origins
      @secret = configuration.secret
      @secret_config = configuration.secret_config
      @current_session = nil
      @new_session = nil
    end

    def trusted_origin?(url, allow_relative_paths: false)
      trusted_origins.any? do |origin|
        Configuration.matches_origin_pattern?(url, origin, allow_relative_paths: allow_relative_paths)
      end
    end

    def base_url
      runtime_fetch(:base_url, @base_url)
    end

    attr_reader :canonical_base_url

    def trusted_origins
      runtime_fetch(:trusted_origins, @trusted_origins)
    end

    def auth_cookies
      runtime_fetch(:auth_cookies, @auth_cookies)
    end

    def cookies
      runtime_fetch(:cookies, @cookies)
    end

    def current_session
      runtime_fetch(:current_session, @current_session)
    end

    def new_session
      runtime_fetch(:new_session, @new_session)
    end

    def set_new_session(session)
      runtime_store(:new_session, session) || @new_session = session
    end

    def set_current_session(session)
      runtime_store(:current_session, session) || @current_session = session
    end

    def run_in_background(task)
      handler = options.advanced.dig(:background_tasks, :handler)
      if handler.respond_to?(:call)
        handler.call(task)
      elsif task.respond_to?(:call)
        task.call
      end
    end

    def password
      config = {
        min_password_length: options.email_and_password[:min_password_length],
        max_password_length: options.email_and_password[:max_password_length]
      }
      password_config = options.email_and_password[:password] || {}

      {
        config: config,
        hash: ->(value) { Password.hash(value, hasher: password_config[:hash], algorithm: options.password_hasher) },
        verify: lambda do |password:, hash:|
          Password.verify(
            password: password,
            hash: hash,
            verifier: password_config[:verify],
            algorithm: options.password_hasher
          )
        end,
        check_password: lambda do |value|
          length = value.to_s.length
          length.between?(config[:min_password_length].to_i, config[:max_password_length].to_i)
        end
      }
    end

    def create_auth_cookie(cookie_name, override_attributes = {})
      Cookies.create_cookie(options, cookie_name.to_s, override_attributes)
    end

    def set_adapter(adapter)
      @adapter = adapter
    end

    def set_internal_adapter(adapter)
      @internal_adapter = adapter
    end

    def apply_plugin_context!(attributes)
      normalize_context(attributes).each do |key, value|
        instance_variable_set("@#{key}", value) if plugin_context_attribute?(key)
      end
    end

    def refresh_from_options!
      @social_providers = options.social_providers
      @session_config = options.session
      @rate_limit_config = options.rate_limit
      @trusted_origins = options.trusted_origins
      @secret = options.secret
      @secret_config = options.secret_config
    end

    def method_missing(name, *arguments, &block)
      variable_name = :"@#{name}"
      return instance_variable_get(variable_name) if arguments.empty? && instance_variable_defined?(variable_name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      instance_variable_defined?(:"@#{name}") || super
    end

    def prepare_for_request!(request)
      runtime = request_runtime
      runtime[:current_session] = nil
      runtime[:new_session] = nil
      runtime[:base_url] = serving_base_url(request)
      runtime[:trusted_origins] = current_trusted_origins(request)
    end

    def prepare_for_api_call!(source)
      runtime = request_runtime
      runtime[:current_session] = nil
      runtime[:new_session] = nil
      runtime[:base_url] = serving_base_url(source)
      runtime[:trusted_origins] = current_trusted_origins(request_for_callbacks(source))
    end

    def reset_runtime!
      Thread.current[runtime_key] = nil if request_runtime?
      @current_session = nil
      @new_session = nil
    end

    def clear_runtime!
      Thread.current[runtime_key] = nil
    end

    private

    def serving_base_url(source)
      candidate = inferred_origin(source)
      return canonical_base_url unless candidate
      return canonical_base_url if candidate == options.base_url
      return canonical_base_url unless options.serving_origins.any? { |pattern| Configuration.matches_origin_pattern?(candidate, pattern) }

      path = options.base_path
      path.empty? ? candidate : "#{candidate}#{path}"
    end

    def request_for_callbacks(source)
      return source if source.respond_to?(:get_header)

      DirectAPIRequest.new(source, base_url) if source.is_a?(Hash)
    end

    def request_runtime
      Thread.current[runtime_key] ||= {
        base_url: @base_url,
        trusted_origins: @trusted_origins,
        auth_cookies: @auth_cookies,
        cookies: @cookies,
        current_session: nil,
        new_session: nil
      }
    end

    def request_runtime?
      !!Thread.current[runtime_key]
    end

    def runtime_fetch(key, fallback)
      request_runtime? ? Thread.current[runtime_key].fetch(key, fallback) : fallback
    end

    def runtime_store(key, value)
      return false unless request_runtime?

      Thread.current[runtime_key][key] = value
      true
    end

    def runtime_key
      :"better_auth_context_runtime_#{object_id}"
    end

    def inferred_origin(source)
      return nil unless source

      trusted_proxy_headers = options.advanced[:trusted_proxy_headers] == true
      forwarded_host = URLHelpers.header_value(URLHelpers.headers_from_source(source), "x-forwarded-host")
      if trusted_proxy_headers && forwarded_host
        forwarded_proto = URLHelpers.header_value(URLHelpers.headers_from_source(source), "x-forwarded-proto")
        return nil unless valid_proxy_host?(forwarded_host.to_s) && valid_proxy_proto?(forwarded_proto.to_s)

        return "#{forwarded_proto}://#{forwarded_host}"
      end

      host = URLHelpers.host_from_source(source, trusted_proxy_headers: false)
      return nil unless host && valid_proxy_host?(host)

      protocol = URLHelpers.protocol_from_source(source, trusted_proxy_headers: false)
      return nil unless valid_proxy_proto?(protocol)

      "#{protocol}://#{host}"
    end

    def valid_proxy_proto?(proto)
      %w[http https].include?(proto)
    end

    def valid_proxy_host?(host)
      return false if host.strip.empty?

      suspicious_patterns = [
        /\.\./,
        /\0/,
        /\s/,
        /\A[.]/,
        /[<>'"]/,
        /javascript:/i,
        /file:/i,
        /data:/i,
        %r{[/\\]}
      ]
      return false if suspicious_patterns.any? { |pattern| host.match?(pattern) }

      hostname = /\A[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*(:[0-9]{1,5})?\z/
      ipv4 = /\A(\d{1,3}\.){3}\d{1,3}(:[0-9]{1,5})?\z/
      ipv6 = /\A\[[0-9a-fA-F:]+\](:[0-9]{1,5})?\z/
      localhost = /\Alocalhost(:[0-9]{1,5})?\z/i
      return false unless [hostname, ipv4, ipv6, localhost].any? { |pattern| host.match?(pattern) }

      valid_port?(host)
    end

    def valid_port?(host)
      port = host[/:(\d{1,5})\z/, 1]
      return true unless port

      port.to_i.between?(1, 65_535)
    end

    def current_trusted_origins(request)
      origins = options.trusted_origins.dup
      if options.trusted_origins_callback
        origins.concat(Array(options.trusted_origins_callback.call(request)).compact)
      end
      origins.concat(Env.csv("BETTER_AUTH_TRUSTED_ORIGINS"))
      origins.map(&:to_s).reject(&:empty?).uniq
    end

    def normalize_context(value)
      return {} unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, object), result|
        normalized = key.to_s
          .gsub(/([a-z\d])([A-Z])/, "\\1_\\2")
          .tr("-", "_")
          .downcase
          .to_sym
        result[normalized] = object
      end
    end

    def plugin_context_attribute?(key)
      ![:options, :adapter, :internal_adapter].include?(key)
    end

    class DirectAPIRequest
      attr_reader :headers, :url

      def initialize(headers, url)
        @headers = headers.transform_keys { |key| key.to_s.downcase }
        @url = url
      end

      def get_header(key)
        normalized = key.to_s
          .sub(/\AHTTP_/, "")
          .downcase
          .tr("_", "-")
        headers[normalized] || headers[key.to_s] || headers[key.to_s.downcase]
      end
    end
  end
end
