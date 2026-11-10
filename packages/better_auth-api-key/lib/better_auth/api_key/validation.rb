# frozen_string_literal: true

module BetterAuth
  module APIKey
    module Validation
      module_function

      def validate_create_update!(body, config, create:, client:)
        name = body[:name]
        if create && config[:require_name] && name.to_s.empty?
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["NAME_REQUIRED"])
        end
        if name && (!create || !name.to_s.empty?) && !name.to_s.length.between?(config[:minimum_name_length].to_i, config[:maximum_name_length].to_i)
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_NAME_LENGTH"])
        end
        prefix = body[:prefix]
        if prefix && !prefix.to_s.length.between?(config[:minimum_prefix_length].to_i, config[:maximum_prefix_length].to_i)
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_PREFIX_LENGTH"])
        end
        if prefix && !prefix.to_s.match?(/\A[a-zA-Z0-9_-]+\z/)
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_PREFIX_LENGTH"])
        end
        if body.key?(:remaining) && !body[:remaining].nil?
          minimum = create ? 0 : 1
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_REMAINING"]) if body[:remaining].to_i < minimum
        end
        if body.key?(:refill_amount) && !body[:refill_amount].nil? && body[:refill_amount].to_i < 1
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_REMAINING"])
        end
        if create && BetterAuth::APIKey::Utils.javascript_truthy?(body[:metadata])
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["METADATA_DISABLED"]) unless config[:enable_metadata]
          unless body[:metadata].is_a?(Hash) || body[:metadata].is_a?(Array)
            raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_METADATA_TYPE"])
          end
        elsif !create && body[:metadata] && config[:enable_metadata]
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_METADATA_TYPE"]) unless body[:metadata].is_a?(Hash)
        end
        validate_server_only!(body, create: create, client: client)
        amount_present = create ? BetterAuth::APIKey::Utils.javascript_truthy?(body[:refill_amount]) : body.key?(:refill_amount)
        interval_present = create ? BetterAuth::APIKey::Utils.javascript_truthy?(body[:refill_interval]) : body.key?(:refill_interval)
        if amount_present && !interval_present
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["REFILL_AMOUNT_AND_INTERVAL_REQUIRED"])
        end
        if interval_present && !amount_present
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["REFILL_INTERVAL_AND_AMOUNT_REQUIRED"])
        end
        if body.key?(:expires_in)
          return if body[:expires_in].nil?

          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["KEY_DISABLED_EXPIRATION"]) if config[:key_expiration][:disable_custom_expires_time]

          days = body[:expires_in].to_f / 86_400
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["EXPIRES_IN_IS_TOO_SMALL"]) if days < config[:key_expiration][:min_expires_in].to_f
          raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["EXPIRES_IN_IS_TOO_LARGE"]) if days > config[:key_expiration][:max_expires_in].to_f
        end
      end

      def validate_server_only!(body, create:, client:)
        return unless client

        server_only_keys = %i[refill_amount refill_interval rate_limit_max rate_limit_time_window rate_limit_enabled remaining permissions]
        return unless server_only_keys.any? { |key| (create && key == :remaining) ? !body[:remaining].nil? : body.key?(key) }

        raise BetterAuth::APIError.new("BAD_REQUEST", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["SERVER_ONLY_PROPERTY"])
      end

      def update_payload(body, config)
        update = {}
        update[:name] = body[:name] if body.key?(:name)
        update[:enabled] = body[:enabled] unless body[:enabled].nil?
        update[:remaining] = body[:remaining] if body.key?(:remaining)
        update[:refillAmount] = body[:refill_amount] if body.key?(:refill_amount)
        update[:refillInterval] = body[:refill_interval] if body.key?(:refill_interval)
        update[:rateLimitEnabled] = body[:rate_limit_enabled] if body.key?(:rate_limit_enabled)
        update[:rateLimitTimeWindow] = body[:rate_limit_time_window] if body.key?(:rate_limit_time_window)
        update[:rateLimitMax] = body[:rate_limit_max] if body.key?(:rate_limit_max)
        update[:expiresAt] = body[:expires_in].nil? ? nil : Time.now + body[:expires_in].to_i if body.key?(:expires_in)
        update[:metadata] = BetterAuth::APIKey::Utils.encode_json(body[:metadata]) if body.key?(:metadata) && config[:enable_metadata]
        update[:permissions] = BetterAuth::APIKey::Utils.encode_json(body[:permissions]) if body.key?(:permissions)
        update
      end

      def validate_api_key!(ctx, key, config, permissions: nil, configurations: nil, expected_config_id: config[:config_id], run_custom_validator: false)
        hashed = BetterAuth::APIKey::Keys.hash(key, config)
        record = BetterAuth::APIKey::Adapter.find_by_hash(ctx, hashed, config)
        raise invalid_api_key_error unless record
        # Adapters are expected to return row snapshots. The in-memory test
        # adapter exposes its backing hash directly, so copy the top-level row
        # before evaluating guards to avoid one request mutating another's
        # decision snapshot.
        record = record.dup
        if !expected_config_id.nil? && !BetterAuth::APIKey::Routes.config_id_matches?(BetterAuth::APIKey::Types.record_config_id(record), expected_config_id)
          raise invalid_api_key_error
        end
        validation_config = if configurations
          BetterAuth::APIKey::Routes.resolve_config(
            ctx.context,
            {configurations: configurations},
            BetterAuth::APIKey::Types.record_config_id(record)
          )
        else
          config
        end

        validator = validation_config[:custom_api_key_validator]
        if run_custom_validator && validator.respond_to?(:call) && !validator.call({ctx: ctx, key: key})
          raise BetterAuth::APIError.new(
            "UNAUTHORIZED",
            message: BetterAuth::Plugins::API_KEY_ERROR_CODES["KEY_NOT_FOUND"],
            code: "KEY_NOT_FOUND"
          )
        end

        raise BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["KEY_DISABLED"]) if record["enabled"] == false
        if record["expiresAt"] && BetterAuth::APIKey::Utils.normalize_time(record["expiresAt"]) < Time.now
          BetterAuth::APIKey::Adapter.schedule_record_delete(ctx, record, validation_config)
          raise BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["KEY_EXPIRED"])
        end

        check_permissions!(record, permissions)

        if record["remaining"] == 0 && record["refillAmount"].nil?
          BetterAuth::APIKey::Adapter.schedule_record_delete(ctx, record, validation_config)
          raise usage_exceeded_error
        end

        if validation_config[:storage] == "database" || validation_config[:fallback_to_database]
          claim_usage_in_database(ctx, record, validation_config)
        else
          warn_best_effort_secondary(ctx, validation_config)
          claim_usage_in_secondary(ctx, record, validation_config, hashed)
        end
      end

      def claim_usage_in_database(ctx, record, config)
        row = record
        row = consume_remaining_database(ctx, row) unless row["remaining"].nil?
        row = consume_rate_limit_database(ctx, row, config)

        final_row = ctx.context.adapter.update(
          model: BetterAuth::Plugins::API_KEY_TABLE_NAME,
          where: [{field: "id", value: row["id"]}],
          update: {updatedAt: Time.now}
        )
        raise invalid_api_key_error unless final_row

        if config[:storage] == "secondary-storage"
          BetterAuth::APIKey::Adapter.set(ctx, final_row, config)
        end
        final_row
      end

      def consume_remaining_database(ctx, record)
        now = Time.now
        refill_interval = record["refillInterval"]
        refill_amount = record["refillAmount"]
        if refill_interval && refill_amount.to_i.positive?
          last_refill = BetterAuth::APIKey::Utils.normalize_time(record["lastRefillAt"] || record["createdAt"])
          if last_refill && ((now - last_refill) * 1000) > refill_interval.to_i
            refilled = ctx.context.adapter.increment_one(
              model: BetterAuth::Plugins::API_KEY_TABLE_NAME,
              where: [
                {field: "id", value: record["id"]},
                {field: "lastRefillAt", value: record["lastRefillAt"]}
              ],
              increment: {},
              set: {remaining: refill_amount.to_i - 1, lastRefillAt: now},
              allow_server_managed: true
            )
            return refilled if refilled
          end
        end

        decremented = ctx.context.adapter.increment_one(
          model: BetterAuth::Plugins::API_KEY_TABLE_NAME,
          where: [{field: "id", value: record["id"]}, {field: "remaining", operator: "gt", value: 0}],
          increment: {remaining: -1},
          allow_server_managed: true
        )
        return decremented if decremented

        raise usage_exceeded_error
      end

      def consume_rate_limit_database(ctx, record, config)
        now = Time.now
        decision = BetterAuth::APIKey::RateLimit.evaluate(record, config, now)
        if decision[:type] == :deny
          raise BetterAuth::APIError.new(
            "TOO_MANY_REQUESTS",
            message: decision[:message],
            code: "RATE_LIMITED",
            body: {
              message: decision[:message],
              code: "RATE_LIMITED",
              details: {tryAgainIn: decision[:try_again_in]}
            }
          )
        end

        case decision[:type]
        when :skip
          return record unless decision[:last_request]

          updated = ctx.context.adapter.update(
            model: BetterAuth::Plugins::API_KEY_TABLE_NAME,
            where: [{field: "id", value: record["id"]}],
            update: {lastRequest: decision[:last_request]}
          )
          return updated || record
        when :start, :reset
          guard = if decision[:type] == :reset
            {field: "lastRequest", operator: "lte", value: decision[:window_start]}
          else
            {field: "lastRequest", value: nil}
          end
          started = ctx.context.adapter.increment_one(
            model: BetterAuth::Plugins::API_KEY_TABLE_NAME,
            where: [{field: "id", value: record["id"]}, guard],
            increment: {},
            set: {requestCount: 1, lastRequest: decision[:now]},
            allow_server_managed: true
          )
          return started if started
        when :increment
          incremented = ctx.context.adapter.increment_one(
            model: BetterAuth::Plugins::API_KEY_TABLE_NAME,
            where: [
              {field: "id", value: record["id"]},
              {field: "lastRequest", operator: "gt", value: decision[:window_start]},
              {field: "requestCount", operator: "lt", value: decision[:max]}
            ],
            increment: {requestCount: 1},
            set: {lastRequest: decision[:now]},
            allow_server_managed: true
          )
          return incremented if incremented
        end

        fresh = ctx.context.adapter.find_one(model: BetterAuth::Plugins::API_KEY_TABLE_NAME, where: [{field: "id", value: record["id"]}])
        raise invalid_api_key_error unless fresh

        # One concurrent writer may have opened/reset the window. Re-evaluate
        # against the fresh row; this recursion is bounded by the finite race.
        consume_rate_limit_database(ctx, fresh, config)
      end

      def claim_usage_in_secondary(ctx, record, config, hashed)
        now = Time.now
        update = usage_update(record, config, now)
        storage_update = update.transform_keys { |key_name| BetterAuth::Schema.storage_key(key_name) }
        performer = lambda do
          fresh = BetterAuth::APIKey::Adapter.find_by_hash(ctx, hashed, config)
          next nil unless fresh

          merged = fresh.merge(storage_update)
          BetterAuth::APIKey::Adapter.set(ctx, merged, config)
          merged
        end

        if config[:defer_updates]
          BetterAuth::APIKey::Utils.run_background_task(ctx, "API key update", performer)
          return record.merge(storage_update)
        end

        updated = performer.call
        raise failed_to_update_api_key_error unless updated

        updated
      end

      def usage_update(record, config, now = Time.now)
        update = {lastRequest: now, updatedAt: now}
        decision = BetterAuth::APIKey::RateLimit.evaluate(record, config, now)
        if decision[:type] == :deny
          raise BetterAuth::APIError.new(
            "TOO_MANY_REQUESTS",
            message: decision[:message],
            code: "RATE_LIMITED",
            body: {message: decision[:message], code: "RATE_LIMITED", details: {tryAgainIn: decision[:try_again_in]}}
          )
        end
        case decision[:type]
        when :start, :reset
          update[:requestCount] = 1
        when :increment
          update[:requestCount] = record["requestCount"].to_i + 1
        when :skip
          update[:lastRequest] = decision[:last_request] if decision[:last_request]
        end

        remaining = record["remaining"]
        if !remaining.nil?
          if record["refillAmount"].to_i.positive? && record["refillInterval"]
            last_refill = BetterAuth::APIKey::Utils.normalize_time(record["lastRefillAt"] || record["createdAt"])
            if !last_refill || ((now - last_refill) * 1000) > record["refillInterval"].to_i
              remaining = record["refillAmount"].to_i
              update[:lastRefillAt] = now
            end
          end
          raise usage_exceeded_error if remaining.to_i == 0

          update[:remaining] = remaining.to_i - 1
        end
        update
      end

      def invalid_api_key_error
        BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["INVALID_API_KEY"])
      end

      def usage_exceeded_error
        BetterAuth::APIError.new("TOO_MANY_REQUESTS", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["USAGE_EXCEEDED"])
      end

      def failed_to_update_api_key_error
        BetterAuth::APIError.new(
          "INTERNAL_SERVER_ERROR",
          message: BetterAuth::Plugins::API_KEY_ERROR_CODES["FAILED_TO_UPDATE_API_KEY"],
          code: "FAILED_TO_UPDATE_API_KEY"
        )
      end

      def warn_best_effort_secondary(ctx, config)
        return if config[:storage] != "secondary-storage" || config[:fallback_to_database]
        return if ctx.context.respond_to?(:runtime_fetch) && ctx.context.runtime_fetch(:api_key_secondary_warning, false)

        logger = ctx.context.logger if ctx.context.respond_to?(:logger)
        logger.warn("[API KEY PLUGIN] Secondary-storage-only API-key counters are best-effort; use fallback_to_database for atomic enforcement.") if logger.respond_to?(:warn)
        ctx.context.runtime_store(:api_key_secondary_warning, true) if ctx.context.respond_to?(:runtime_store)
      end

      def check_permissions!(record, required)
        return if required.nil?

        BetterAuth::Plugins.load_plugin!(:access)
        actual = BetterAuth::APIKey::Utils.decode_json(record["permissions"])
        unless actual
          raise BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["KEY_NOT_FOUND"], code: "KEY_NOT_FOUND")
        end
        result = BetterAuth::Plugins::Role.new(actual).authorize(required)
        unless result[:success]
          raise BetterAuth::APIError.new("UNAUTHORIZED", message: BetterAuth::Plugins::API_KEY_ERROR_CODES["KEY_NOT_FOUND"], code: "KEY_NOT_FOUND")
        end
      end
    end
  end
end
