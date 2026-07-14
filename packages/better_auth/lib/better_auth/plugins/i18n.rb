# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def i18n(options = {})
      config = normalize_i18n_options(options)
      validate_i18n_translations!(config)

      Plugin.new(
        id: "i18n",
        hooks: {
          after: [
            {
              matcher: ->(_ctx) { true },
              handler: ->(ctx) { apply_i18n_translation(ctx, config) }
            }
          ]
        },
        options: config
      )
    end

    def normalize_i18n_options(options)
      return {} unless options.is_a?(Hash)

      translations = normalize_i18n_translations(fetch_i18n_option(options, :translations))
      default_locale = fetch_i18n_option(options, :default_locale)
      detection = normalize_i18n_detection(fetch_i18n_option(options, :detection))
      locale_cookie = fetch_i18n_option(options, :locale_cookie) || "locale"
      user_locale_field = fetch_i18n_option(options, :user_locale_field) || "locale"
      get_locale = fetch_i18n_option(options, :get_locale)
      available_locales = translations.keys

      {
        translations: translations,
        default_locale: resolve_i18n_default_locale(default_locale, available_locales),
        detection: detection,
        locale_cookie: locale_cookie.to_s,
        user_locale_field: user_locale_field.to_s,
        get_locale: get_locale
      }
    end

    def fetch_i18n_option(options, name)
      snake = name.to_s
      camel = snake.split("_").map.with_index { |part, index| index.zero? ? part : part.capitalize }.join
      options[snake.to_sym] || options[snake] || options[camel.to_sym] || options[camel]
    end

    def normalize_i18n_translations(translations)
      return {} unless translations.is_a?(Hash)

      translations.each_with_object({}) do |(locale, codes), result|
        locale_key = locale.to_s
        next if locale_key.empty?

        normalized_codes = {}
        next unless codes.is_a?(Hash)

        codes.each do |(code, message)|
          normalized_codes[code.to_s.tr("-", "_").upcase] = message
        end
        result[locale_key] = normalized_codes
      end
    end

    def normalize_i18n_detection(detection)
      return ["header"] if detection.nil?

      Array(detection).map { |strategy| strategy.to_s.downcase }
    end

    def validate_i18n_translations!(config)
      translations = config[:translations]
      if translations.nil? || translations.empty?
        raise BetterAuth::Error, "i18n plugin: translations object is empty"
      end
    end

    def resolve_i18n_default_locale(explicit, available_locales)
      explicit_locale = explicit.to_s
      return explicit_locale if explicit && available_locales.include?(explicit_locale)
      return "en" if available_locales.include?("en")

      nil
    end

    def parse_accept_language(header)
      return [] if header.nil? || header.to_s.empty?

      header.to_s
        .split(",")
        .map do |part|
          locale_str, quality = part.strip.split(";", 2)
          q_string = quality ? quality.strip.sub(/\Aq=/i, "") : "1"
          q = Float(q_string)
          locale = locale_str.to_s.strip.split("-").first.to_s
          {locale: locale, q: q}
        end
        .select { |item| !item[:locale].empty? }
        .sort_by { |item| -item[:q] }
        .map { |item| item[:locale] }
    end

    def detect_i18n_locale(ctx, config)
      available_locales = config[:translations].keys

      config[:detection].each do |strategy|
        locale = case strategy
        when "header"
          detect_locale_from_header(ctx, available_locales)
        when "cookie"
          detect_locale_from_cookie(ctx, config, available_locales)
        when "session"
          detect_locale_from_session(ctx, config, available_locales)
        when "callback"
          detect_locale_from_callback(ctx, config, available_locales)
        end
        return locale if locale && available_locales.include?(locale)
      end

      config[:default_locale]
    end

    def detect_locale_from_header(ctx, available_locales)
      parse_accept_language(ctx.headers["accept-language"]).find do |locale|
        available_locales.include?(locale)
      end
    end

    def detect_locale_from_cookie(ctx, config, available_locales)
      value = ctx.get_cookie(config[:locale_cookie])
      locale = value.to_s
      locale if value && available_locales.include?(locale)
    end

    def detect_locale_from_session(ctx, config, available_locales)
      session = ctx.context.current_session || ctx.context.new_session
      return nil unless session

      user = session[:user] || session["user"]
      return nil unless user.is_a?(Hash)

      locale = fetch_value(user, config[:user_locale_field])
      locale = locale.to_s
      locale if locale && !locale.empty? && available_locales.include?(locale)
    end

    def detect_locale_from_callback(ctx, config, available_locales)
      callback = config[:get_locale]
      return nil unless callback.respond_to?(:call)

      locale = callback.call(ctx)
      locale = locale.to_s
      locale if locale && !locale.empty? && available_locales.include?(locale)
    end

    def apply_i18n_translation(ctx, config)
      error = ctx.returned
      return nil unless error.is_a?(BetterAuth::APIError)

      error_code = resolve_i18n_error_code(error, ctx)
      return nil unless error_code

      locale = detect_i18n_locale(ctx, config)
      translation = config.dig(:translations, locale, error_code)
      return nil unless translation

      raise BetterAuth::APIError.new(
        error.status,
        message: translation,
        headers: error.headers,
        code: error.code,
        body: {
          code: error_code,
          message: translation,
          originalMessage: error.message
        }
      )
    end

    def resolve_i18n_error_code(error, ctx)
      body = error.body
      if body.is_a?(Hash)
        code = body[:code] || body["code"]
        return code.to_s.tr("-", "_").upcase if code
      end

      unless error.code.to_s.upcase == error.status.to_s.upcase
        return error.code.to_s.tr("-", "_").upcase
      end

      reverse_lookup_i18n_error_code(error.message, ctx)
    end

    def reverse_lookup_i18n_error_code(message, ctx)
      merged_i18n_error_catalog(ctx).find { |_code, text| text == message }&.first
    end

    def merged_i18n_error_catalog(ctx)
      catalog = BetterAuth::BASE_ERROR_CODES.dup
      ctx.context.options.plugins.each do |plugin|
        next unless plugin.respond_to?(:error_codes)

        codes = plugin.error_codes
        next if codes.nil? || codes.empty?

        catalog.merge!(codes)
      end
      catalog
    end
  end
end
