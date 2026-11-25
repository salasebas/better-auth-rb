# frozen_string_literal: true

require "time"

module BetterAuth
  module Session
    SKIP_SESSION_REFRESH = RequestState.define { false }
    private_constant :SKIP_SESSION_REFRESH

    module_function

    def find_current(ctx, disable_cookie_cache: false, disable_refresh: false, sensitive: false)
      authoritative = sensitive && stateful?(ctx)
      if ctx.context.current_session && !authoritative
        return ctx.context.current_session
      end

      get_session(ctx, disable_cookie_cache: disable_cookie_cache || authoritative, disable_refresh: disable_refresh)
    end

    def get_session(ctx, disable_cookie_cache:, disable_refresh:, defer_refresh: ctx.context.session_config[:defer_session_refresh])
      token_cookie = ctx.context.auth_cookies[:session_token]
      token = ctx.get_signed_cookie(token_cookie.name, ctx.context.secret)
      unless token
        present = ctx.get_cookie(token_cookie.name)
        return missing_session(ctx) if present && !present.empty?

        return nil
      end

      cached = cached_session(ctx, token, bypass_cache: disable_cookie_cache)
      if cached
        ctx.context.set_current_session(cached) if ctx.context.respond_to?(:set_current_session)
        return cached
      end

      found = ctx.context.internal_adapter.find_session(token)
      return missing_session(ctx) unless found

      session = stringify_keys(found[:session] || found["session"])
      user = stringify_keys(found[:user] || found["user"])
      if expired?(session)
        missing_session(ctx)
        ctx.context.internal_adapter.delete_session(token) unless defer_refresh
        return nil
      end

      result = {session: session, user: user}
      ctx.context.set_current_session(result) if ctx.context.respond_to?(:set_current_session)
      return result if Cookies.dont_remember?(ctx) || disable_refresh

      needs_refresh = should_refresh?(ctx, session)
      if needs_refresh && !defer_refresh
        refreshed = refresh_session(ctx, result)
        ctx.context.set_current_session(refreshed) if ctx.context.respond_to?(:set_current_session)
        return refreshed
      end

      Cookies.set_cookie_cache(ctx, result, false)
      defer_refresh ? result.merge(needsRefresh: needs_refresh) : result
    end

    def cached_session(ctx, token, bypass_cache:)
      config = ctx.context.session_config[:cookie_cache] || {}
      payload = Cookies.read_session_cache(ctx, config, use_cache: config[:enabled] && !bypass_cache)
      return nil unless payload
      return nil if payload["session"]["token"] && payload["session"]["token"] != token

      result = {session: payload["session"], user: payload["user"]}
      if should_refresh_cookie_cache?(config, payload) && !should_skip_session_refresh?
        Cookies.set_cookie_cache(ctx, result, false)
        Cookies.set_session_token(ctx, result[:session].fetch("token"), Cookies.dont_remember?(ctx))
      end
      result
    end

    def missing_session(ctx)
      ctx.context.set_current_session(nil) if ctx.context.respond_to?(:set_current_session)
      Cookies.delete_session_cookie(ctx)
      nil
    end

    def stateful?(ctx)
      options = ctx.context.options
      !options.database.nil? || !options.secondary_storage.nil?
    end

    def expired?(session)
      expires_at = normalize_time(session["expiresAt"])
      expires_at && expires_at <= Time.now
    end

    def should_skip_session_refresh?
      RequestState.present? && SKIP_SESSION_REFRESH.get == true
    end

    def set_should_skip_session_refresh(value)
      SKIP_SESSION_REFRESH.set(value)
    end

    def should_refresh?(ctx, session)
      config = ctx.context.session_config
      return false if config[:disable_session_refresh] || should_skip_session_refresh?

      expires_at = normalize_time(session["expiresAt"])
      !!expires_at && expires_at - config[:expires_in].to_i + config[:update_age].to_i <= Time.now
    end

    def refresh_session(ctx, result)
      now = Time.now
      expires_at = now + ctx.context.session_config[:expires_in].to_i
      updated = ctx.context.internal_adapter.update_session(
        result[:session]["token"],
        "expiresAt" => expires_at,
        "updatedAt" => now
      )
      unless updated
        missing_session(ctx)
        raise APIError.new("UNAUTHORIZED", message: BASE_ERROR_CODES["FAILED_TO_GET_SESSION"])
      end

      session = stringify_keys(updated)
      refreshed = {session: session, user: result[:user]}
      Cookies.set_session_cookie(ctx, refreshed, false)
      refreshed
    end

    def should_refresh_cookie_cache?(config, payload)
      refresh_cache = config[:refresh_cache]
      return false if refresh_cache == false || refresh_cache.nil?

      max_age = Cookies.cache_max_age(config[:max_age]).to_i
      update_age_key = [:update_age, "updateAge", "update_age"].find do |key|
        refresh_cache.is_a?(Hash) && refresh_cache.key?(key)
      end
      update_age = update_age_key ? refresh_cache[update_age_key].to_f : (max_age * 0.2).floor
      expires_at = payload["expiresAt"]
      return false unless expires_at.is_a?(Numeric) && expires_at.positive?

      remaining_ms = expires_at - (Time.now.to_f * 1000).to_i
      remaining_ms < update_age * 1000
    end

    def normalize_time(value)
      return value if value.is_a?(Time)
      return Time.at(value / 1000.0) if value.is_a?(Integer) && value > 10_000_000_000
      return Time.at(value) if value.is_a?(Integer)
      return nil if value.nil?

      Time.parse(value.to_s)
    end

    def stringify_keys(value)
      return value.each_with_object({}) { |(key, object_value), result| result[key.to_s] = stringify_keys(object_value) } if value.is_a?(Hash)
      return value.map { |entry| stringify_keys(entry) } if value.is_a?(Array)

      value
    end
  end
end
