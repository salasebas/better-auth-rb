# frozen_string_literal: true

require "json"

module BetterAuth
  class RateLimiter
    MISSING_CLIENT_IP = "no-trusted-ip"
    MEMORY_STORE_MAX_ENTRIES = 100_000
    DATABASE_CONSUME_ATTEMPTS = 8
    LEGACY_STORAGE_WARNING = "Rate limiting is best-effort: the configured storage has no atomic `consume`, so concurrent requests may bypass the limit. Provide a storage that implements `consume` for strict enforcement."
    MISSING_CLIENT_IP_WARNING = "Rate limiting could not determine a trustworthy client IP address and is falling back to a " \
      "single shared per-path bucket. Ensure your runtime forwards a trusted client IP header, then configure " \
      "`advanced.ip_address.ip_address_headers` and, for proxy chains, `advanced.ip_address.trusted_proxies`."

    class MemoryStore
      def initialize(clock: -> { Time.now.to_f }, max_entries: MEMORY_STORE_MAX_ENTRIES)
        @clock = clock
        @max_entries = max_entries
        @entries = {}
        @mutex = Mutex.new
      end

      def get(key)
        @mutex.synchronize do
          entry = @entries[key]
          return nil unless entry

          if clock.call > entry[:expires_at]
            @entries.delete(key)
            return nil
          end

          entry[:data]
        end
      end

      def set(key, value, ttl:, update: false)
        @mutex.synchronize do
          @entries.delete(key)
          @entries[key] = {data: value, expires_at: clock.call + ttl.to_f}
          prune!(sweep: @entries.size > @max_entries)
        end
      end

      def consume(key, window:, max:)
        @mutex.synchronize do
          now = clock.call
          prune!(now, sweep: true)
          entry = @entries[key]
          data = entry[:data] if entry && now <= entry[:expires_at]
          decision = RateLimiter.decide_consume(data, window: window, max: max, now: now)
          if decision[:allowed]
            @entries.delete(key)
            @entries[key] = {data: decision.fetch(:next).merge(key: key), expires_at: now + window.to_f}
            prune!(now)
          end
          decision.slice(:allowed, :retry_after)
        end
      end

      def size
        @mutex.synchronize { @entries.size }
      end

      private

      attr_reader :clock

      def prune!(now = clock.call, sweep: false)
        @entries.delete_if { |_key, entry| now > entry[:expires_at] } if sweep
        overflow = @entries.size - @max_entries
        overflow.times { @entries.delete(@entries.first.first) } if overflow.positive?
      end
    end

    def self.decide_consume(data, window:, max:, now:)
      return {next: {key: "", count: 1, last_request: now}, allowed: true, retry_after: nil} unless data

      last_request = data.fetch(:last_request).to_f
      if now - last_request > window.to_f
        return {next: data.merge(count: 1, last_request: now), allowed: true, retry_after: nil}
      end
      if data.fetch(:count).to_i >= max.to_i
        return {
          next: data,
          allowed: false,
          retry_after: [(last_request + window.to_f - now).ceil, 0].max
        }
      end

      {
        next: data.merge(count: data.fetch(:count).to_i + 1, last_request: now),
        allowed: true,
        retry_after: nil
      }
    end

    def initialize(clock: -> { Time.now.to_f }, memory_store: nil)
      @clock = clock
      @memory_store = memory_store || MemoryStore.new(clock: clock)
      @warned_missing_client_ip = false
      @warned_legacy_storage = false
      @warning_mutex = Mutex.new
    end

    def call(request, context, path)
      config = context.rate_limit_config || {}
      return unless config[:enabled]
      return if context.options.advanced.dig(:ip_address, :disable_ip_tracking)

      ip = client_ip(request, context.options)
      unless ip
        warn_missing_client_ip(context)
        ip = MISSING_CLIENT_IP
      end
      rule = rate_limit_rule(request, context, config, path)
      return if rule == false

      window = (rule[:window] || 10).to_f
      max = (rule[:max] || 100).to_i
      key = rate_limit_key(ip, path)
      decision = consume(storage_for(context, config), key, window: window, max: max, context: context)
      return if decision[:allowed]

      rate_limit_response(decision[:retry_after] || window)
    end

    private

    attr_reader :clock

    def consume((type, storage), key, window:, max:, context:)
      case type
      when :memory then storage.consume(key, window: window, max: max)
      when :database then consume_database(storage, key, window: window, max: max, context: context)
      when :secondary then consume_secondary(storage, key, window: window, max: max, context: context)
      when :custom
        if storage.respond_to?(:consume)
          normalize_consume_result(storage.consume(key, window: window, max: max))
        else
          legacy_consume(storage, key, window: window, max: max, context: context)
        end
      end
    end

    def consume_database(adapter, key, window:, max:, context:)
      DATABASE_CONSUME_ATTEMPTS.times do
        now = clock.call
        now_ms = (now * 1000).to_i
        data = read_database_storage(adapter, key)
        unless data
          created = adapter.create_if_absent(
            model: "rateLimit",
            data: {key: key, count: 1, lastRequest: now_ms},
            conflict_field: "key"
          )
          return {allowed: true, retry_after: nil} if created
          next
        end

        last_request = data.fetch(:last_request).to_f
        if now - last_request > window
          reset = adapter.increment_one(
            model: "rateLimit",
            where: [
              {field: "key", value: key},
              {field: "lastRequest", operator: "lte", value: (last_request * 1000).to_i}
            ],
            increment: {},
            set: {count: 1, lastRequest: now_ms}
          )
          if reset
            schedule_database_cleanup(adapter, context, now_ms)
            return {allowed: true, retry_after: nil}
          end
          next
        end

        incremented = adapter.increment_one(
          model: "rateLimit",
          where: [
            {field: "key", value: key},
            {field: "lastRequest", operator: "gte", value: ((now - window) * 1000).to_i},
            {field: "count", operator: "lt", value: max}
          ],
          increment: {count: 1},
          set: {lastRequest: now_ms}
        )
        return {allowed: true, retry_after: nil} if incremented

        fresh = read_database_storage(adapter, key)
        next unless fresh
        next if now - fresh.fetch(:last_request).to_f > window

        return {allowed: false, retry_after: retry_after(fresh.fetch(:last_request).to_f, window, now)}
      end

      data = read_database_storage(adapter, key)
      return {allowed: false, retry_after: window.ceil} unless data

      {allowed: false, retry_after: retry_after(data.fetch(:last_request).to_f, window, clock.call)}
    end

    def consume_secondary(storage, key, window:, max:, context:)
      if storage.respond_to?(:increment)
        existing = storage.get(key)
        legacy_data = parse_secondary_legacy_data(existing)
        if legacy_data
          return legacy_consume(
            storage, key, window: window, max: max, context: context, secondary: true, data: legacy_data
          )
        end

        count = storage.increment(key, window)
        return {allowed: count.to_i <= max, retry_after: (count.to_i > max) ? window.ceil : nil}
      end

      legacy_consume(storage, key, window: window, max: max, context: context, secondary: true)
    end

    def legacy_consume(storage, key, window:, max:, context:, secondary: false, data: nil)
      warn_legacy_storage(context)
      data ||= read_legacy_storage(storage, key, secondary: secondary)
      decision = self.class.decide_consume(data, window: window, max: max, now: clock.call)
      return decision.slice(:allowed, :retry_after) unless decision[:allowed]

      next_data = decision.fetch(:next).merge(key: key)
      value = secondary ? JSON.generate(secondary_storage_data(next_data)) : next_data
      call_legacy_set(storage, key, value, ttl: window, update: !data.nil?, secondary: secondary)
      decision.slice(:allowed, :retry_after)
    end

    def normalize_consume_result(result)
      invalid_consume!("must return a Hash") unless result.is_a?(Hash)
      allowed = result.key?(:allowed) ? result[:allowed] : result["allowed"]
      retry_after = result.key?(:retry_after) ? result[:retry_after] : result["retry_after"]
      invalid_consume!("must include boolean allowed") unless allowed == true || allowed == false
      valid_retry_after = retry_after.nil? || (retry_after.is_a?(Numeric) && retry_after.finite? && retry_after >= 0)
      unless valid_retry_after
        invalid_consume!("retry_after must be nil or a finite nonnegative number")
      end
      {allowed: allowed, retry_after: retry_after&.ceil}
    end

    def invalid_consume!(message)
      raise APIError.new("INTERNAL_SERVER_ERROR", message: "Invalid rate limit consume result: #{message}")
    end

    def parse_secondary_legacy_data(value)
      return normalize_rate_limit_data(symbolize_keys(value)) if value.is_a?(Hash)
      return nil unless value.is_a?(String) && value.lstrip.start_with?("{")

      parsed = JSON.parse(value)
      normalize_rate_limit_data(symbolize_keys(parsed)) if parsed.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def read_legacy_storage(storage, key, secondary:)
      data = storage.get(key)
      data = JSON.parse(data) if secondary && data.is_a?(String)
      normalize_rate_limit_data(symbolize_keys(data))
    rescue JSON::ParserError
      nil
    end

    def call_legacy_set(storage, key, value, ttl:, update:, secondary:)
      parameters = storage.method(:set).parameters
      keyword_capable = parameters.any? { |type, _name| [:key, :keyreq].include?(type) }
      if !secondary && keyword_capable
        storage.set(key, value, ttl: ttl, update: update)
      elsif secondary
        storage.set(key, value, ttl)
      else
        storage.set(key, value, ttl, update)
      end
    end

    def read_database_storage(adapter, key)
      data = adapter.find_one(model: "rateLimit", where: [{field: "key", value: key}])
      normalize_rate_limit_data(symbolize_keys(data))
    end

    def schedule_database_cleanup(adapter, context, now_ms)
      longest_window = longest_static_window(context)
      return unless longest_window

      task = lambda do
        adapter.delete_many(
          model: "rateLimit",
          where: [{field: "lastRequest", operator: "lt", value: now_ms - (longest_window * 1000).to_i}]
        )
      rescue => error
        log(context.logger, :error, "Error pruning rate limit rows", error)
      end
      context.run_in_background(task)
    rescue => error
      log(context.logger, :error, "Error scheduling rate limit row pruning", error)
    end

    def longest_static_window(context)
      config = context.rate_limit_config || {}
      custom_rules = config[:custom_rules] || {}
      return nil if custom_rules.values.any? { |rule| rule.respond_to?(:call) }

      windows = [(config[:window] || 10).to_f, 10, 60]
      context.options.plugins.each do |plugin|
        Array(plugin[:rate_limit]).each do |rule|
          window = rule[:window]
          return nil if window.respond_to?(:call)
          windows << window.to_f if window
        end
      end
      custom_rules.each_value do |rule|
        next if rule == false

        window = rule[:window]
        return nil if window.respond_to?(:call)
        windows << window.to_f if window
      end
      windows.max
    end

    def rate_limit_response(retry_after)
      [
        429,
        {"content-type" => "application/json", "x-retry-after" => retry_after.ceil.to_s},
        [JSON.generate({message: "Too many requests. Please try again later."})]
      ]
    end

    def retry_after(last_request, window, now)
      [(last_request + window - now).ceil, 0].max
    end

    def rate_limit_rule(request, context, config, path)
      rule = {window: config[:window] || 10, max: config[:max] || 100}
      rule = default_special_rule(path) || rule
      rule = matching_plugin_rule(context, path) || rule
      custom_rule = matching_custom_rule(config, path)
      return resolve_custom_rule(custom_rule, request, rule) unless custom_rule.nil?
      rule
    end

    def default_special_rule(path)
      return {window: 10, max: 3} if path.start_with?("/sign-in", "/sign-up", "/change-password", "/change-email")
      return {window: 60, max: 3} if path == "/request-password-reset" ||
        path == "/send-verification-email" || path.start_with?("/forget-password") ||
        path == "/email-otp/send-verification-otp" || path == "/email-otp/request-password-reset"
      nil
    end

    def matching_custom_rule(config, path)
      custom_rules = config[:custom_rules] || {}
      custom_rules.find { |pattern, _rule| path_matches?(pattern.to_s, path) }&.last
    end

    def resolve_custom_rule(rule, request, current)
      return false if rule == false
      return rule.call(request, current) if rule.respond_to?(:call)
      rule || current
    end

    def storage_for(context, config)
      return [:custom, config[:custom_storage]] if config[:custom_storage]
      return [:database, context.internal_adapter.adapter] if config[:storage] == "database"
      if config[:storage] == "secondary-storage" && context.options.secondary_storage
        return [:secondary, context.options.secondary_storage]
      end
      [:memory, @memory_store]
    end

    def secondary_storage_data(data)
      {key: data[:key], count: data[:count], lastRequest: (data[:last_request].to_f * 1000).to_i}
    end

    def symbolize_keys(value)
      return value unless value.is_a?(Hash)

      value.each_with_object({}) do |(key, object_value), result|
        result[key.to_s.gsub(/([a-z\d])([A-Z])/, "\\1_\\2").tr("-", "_").downcase.to_sym] = object_value
      end
    end

    def normalize_rate_limit_data(data)
      return data unless data.is_a?(Hash)

      last_request = data[:last_request]
      return data unless last_request.is_a?(Numeric) && last_request > 10_000_000_000
      data.merge(last_request: last_request / 1000.0)
    end

    def rate_limit_key(ip, path)
      "#{ip}|#{path}"
    end

    def client_ip(request, options)
      RequestIP.client_ip(request, options)
    end

    def warn_missing_client_ip(context)
      warn_once(:@warned_missing_client_ip) { log(context.logger, :warn, MISSING_CLIENT_IP_WARNING) }
    end

    def warn_legacy_storage(context)
      warn_once(:@warned_legacy_storage) { log(context.logger, :warn, LEGACY_STORAGE_WARNING) }
    end

    def warn_once(variable)
      @warning_mutex.synchronize do
        return if instance_variable_get(variable)

        instance_variable_set(variable, true)
        yield
      end
    end

    def log(logger, level, message, *arguments)
      if logger.respond_to?(:call)
        logger.call(level, message, *arguments)
      elsif logger.respond_to?(level)
        logger.public_send(level, message, *arguments)
      end
    end

    def matching_plugin_rule(context, path)
      context.options.plugins.flat_map { |plugin| Array(plugin[:rate_limit]) }
        .find { |rule| rule[:path_matcher]&.call(path) }
    end

    def path_matches?(pattern, path)
      return path == pattern unless pattern.include?("*")

      /\A#{Regexp.escape(pattern).gsub("\\*", ".*")}\z/.match?(path)
    end
  end
end
