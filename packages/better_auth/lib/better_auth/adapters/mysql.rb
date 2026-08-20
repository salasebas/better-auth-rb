# frozen_string_literal: true

require "uri"

module BetterAuth
  module Adapters
    class MySQL < SQL
      URL_STRING_OPTIONS = %w[
        socket encoding flags sslkey sslcert sslca sslcapath sslcipher
        default_file default_group default_auth init_command
      ].freeze
      URL_INTEGER_OPTIONS = %w[connect_timeout read_timeout write_timeout].freeze
      URL_BOOLEAN_OPTIONS = %w[
        reconnect local_infile secure_auth get_server_public_key sslverify
      ].freeze
      URL_OPTIONS = (URL_STRING_OPTIONS + URL_INTEGER_OPTIONS + URL_BOOLEAN_OPTIONS + ["ssl_mode"]).freeze
      CONNECTION_OPTIONS = (
        URL_OPTIONS + %w[host username password port database connect_attrs symbolize_keys]
      ).freeze
      SSL_MODES = %w[disabled preferred required verify_ca verify_identity].freeze

      attr_reader :url

      def initialize(options = nil, url: nil, connection: nil, connection_options: nil)
        require "mysql2" unless connection

        config = options || Configuration.new(secret: Configuration::DEFAULT_SECRET, database: :memory)
        @url = url
        client = connection || Mysql2::Client.new(mysql_options(url, connection_options))
        super(config, connection: client, dialect: :mysql)
      end

      private

      def mysql_options(url, connection_options)
        uri = URI.parse(url.to_s)
        url_options = {
          host: uri.host,
          port: uri.port || 3306,
          username: decode_uri_component(uri.user),
          password: decode_uri_component(uri.password),
          database: decode_uri_component(uri.path.to_s.delete_prefix("/"))
        }.compact

        url_options
          .merge(mysql_query_options(uri.query))
          .merge(normalize_connection_options(connection_options))
          .merge(symbolize_keys: false)
      end

      def decode_uri_component(value)
        return if value.nil?

        URI::DEFAULT_PARSER.unescape(value)
      end

      def mysql_query_options(query)
        URI.decode_www_form(query.to_s).to_h.each_with_object({}) do |(key, value), options|
          unless URL_OPTIONS.include?(key)
            Kernel.warn("[better-auth/mysql] Ignoring unsupported MySQL URL option: #{key.inspect}")
            next
          end

          options[key.to_sym] = normalize_option_value(key, value)
        end
      end

      def normalize_connection_options(options)
        return {} if options.nil?
        raise ArgumentError, "MySQL connection_options must be a Hash" unless options.is_a?(Hash)

        options.each_with_object({}) do |(raw_key, value), normalized|
          key = raw_key.to_s
          raise ArgumentError, "Unsupported MySQL connection option: #{key}" unless CONNECTION_OPTIONS.include?(key)

          normalized[key.to_sym] = normalize_option_value(key, value)
        end
      end

      def normalize_option_value(key, value)
        return positive_integer_option(key, value) if URL_INTEGER_OPTIONS.include?(key)
        return boolean_option(key, value) if URL_BOOLEAN_OPTIONS.include?(key)
        return ssl_mode_option(value) if key == "ssl_mode"
        return positive_integer_option(key, value) if key == "port"

        value
      end

      def positive_integer_option(key, value)
        integer = value.is_a?(Integer) ? value : Integer(value, 10)
        raise ArgumentError unless integer.positive?

        integer
      rescue ArgumentError, TypeError
        raise ArgumentError, "MySQL option #{key} must be a positive integer"
      end

      def boolean_option(key, value)
        return value if value == true || value == false
        return true if value == "true"
        return false if value == "false"

        raise ArgumentError, "MySQL option #{key} must be true or false"
      end

      def ssl_mode_option(value)
        mode = value.to_s.downcase
        raise ArgumentError, "MySQL option ssl_mode must be one of: #{SSL_MODES.join(", ")}" unless SSL_MODES.include?(mode)

        mode.to_sym
      end
    end
  end
end
