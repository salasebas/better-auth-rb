# frozen_string_literal: true

require "json"
require "securerandom"
require "time"
require "monitor"

module BetterAuth
  module Adapters
    class InternalAdapter
      attr_reader :adapter, :options, :hooks

      def initialize(adapter, options)
        @adapter = adapter
        @options = options
        @hooks = DatabaseHooks.new(adapter, options)
        @verification_locks_guard = Mutex.new
        @verification_locks = {}
      end

      def create_oauth_user(user, account, context: nil)
        adapter.transaction do
          created_user = create_user(user, context: context)
          created_account = create_account(stringify_keys(account).merge("userId" => created_user["id"]))
          {user: created_user, account: created_account}
        end
      end

      def create_user(user = nil, context: nil, **keywords)
        data = timestamps.merge(stringify_keys((user || {}).merge(keywords)))
        data["email"] = data["email"].to_s.downcase if data["email"]
        hooks.create(data, "user", context: context)
      end

      def create_account(account)
        hooks.create(timestamps.merge(stringify_keys(account)), "account")
      end

      def link_account(account)
        create_account(account)
      end

      def list_sessions(user_id)
        if secondary_storage
          active_session_entries(user_id).filter_map do |entry|
            data = parse_storage(secondary_storage.get(entry.fetch("token")))
            next unless data && data["session"]

            normalize_session_dates(data["session"])
          end
        else
          adapter.find_many(model: "session", where: [{field: "userId", value: user_id}])
        end
      end

      def list_users(limit: nil, offset: nil, sort_by: nil, where: nil)
        adapter.find_many(model: "user", where: where || [], limit: limit, offset: offset, sort_by: sort_by)
      end

      def count_total_users(where: nil)
        adapter.count(model: "user", where: where || [])
      end

      def delete_user(user_id)
        deleted = hooks.delete([{field: "id", value: user_id}], "user")
        return false if deleted == false

        hooks.delete_many([{field: "userId", value: user_id}], "account")
        delete_sessions(user_id) if !secondary_storage || options.session[:store_session_in_database]
        deleted
      end

      def create_session(user_id, dont_remember_me = false, override = nil, override_all = false, context = nil)
        override = stringify_keys(override || {})
        token = override.delete("token") || SecureRandom.hex(16)
        base = {
          "ipAddress" => "",
          "userAgent" => "",
          "expiresAt" => Time.now + (dont_remember_me ? 86_400 : options.session[:expires_in].to_i),
          "userId" => user_id,
          "token" => token
        }.merge(timestamps)
        base["id"] = generated_id if secondary_storage
        data = override_all ? base.merge(override) : override.merge(base)

        custom = secondary_storage && lambda do |session_data|
          actual_session = apply_schema_create("session", session_data)
          store_session(actual_session)
          adapter.create(model: "session", data: actual_session, force_allow_id: true) if options.session[:store_session_in_database]
          actual_session
        end
        hooks.create(data, "session", custom: custom, context: context)
      end

      def find_session(token)
        if secondary_storage
          data = parse_storage(secondary_storage.get(token))
          unless data
            return nil unless options.session[:store_session_in_database] && !options.session[:preserve_session_in_database]
          end

          if data
            return {
              session: normalize_session_dates(data["session"]),
              user: normalize_user_dates(data["user"])
            }
          end
        end

        found = find_session_with_user(token)
        return nil unless found && found["user"]

        user = found.delete("user")
        {session: found, user: user}
      end

      def find_sessions(tokens)
        tokens.filter_map { |token| find_session(token) }
      end

      def update_session(token, session)
        data = stringify_keys(session)
        if secondary_storage
          return hooks.update(data, [{field: "token", value: token}], "session", custom: lambda { |actual_data|
            stored = update_stored_session(token, actual_data)
            db = adapter.update(model: "session", where: [{field: "token", value: token}], update: actual_data) if options.session[:store_session_in_database]
            db || stored
          })
        end

        hooks.update(data, [{field: "token", value: token}], "session")
      end

      def delete_session(token)
        if secondary_storage
          data = parse_storage(secondary_storage.get(token))
          if data && data["session"]
            user_id = data["session"]["userId"]
            entries = active_session_entries(user_id).reject { |entry| entry["token"] == token }
            write_active_sessions(user_id, entries)
          end
          secondary_storage.delete(token)
          return if !options.session[:store_session_in_database] || options.session[:preserve_session_in_database]
        end

        hooks.delete([{field: "token", value: token}], "session")
      end

      def delete_sessions(user_id_or_tokens)
        if secondary_storage
          if user_id_or_tokens.is_a?(Array)
            user_id_or_tokens.each { |token| secondary_storage.delete(token) }
          else
            active_session_entries(user_id_or_tokens).each { |entry| secondary_storage.delete(entry["token"]) }
            secondary_storage.delete(active_key(user_id_or_tokens))
          end
          return if !options.session[:store_session_in_database] || options.session[:preserve_session_in_database]
        end

        field = user_id_or_tokens.is_a?(Array) ? "token" : "userId"
        operator = user_id_or_tokens.is_a?(Array) ? "in" : nil
        hooks.delete_many([{field: field, value: user_id_or_tokens, operator: operator}], "session")
      end

      def delete_accounts(user_id)
        hooks.delete_many([{field: "userId", value: user_id}], "account")
      end

      def delete_account(account_id)
        hooks.delete([{field: "id", value: account_id}], "account")
      end

      def find_oauth_user(email, account_id, provider_id)
        account = find_account_with_user(account_id, provider_id)
        if account
          user = account["user"] || adapter.find_one(model: "user", where: [{field: "email", value: email.to_s.downcase}])
          return nil unless user

          linked = account.dup
          linked.delete("user")
          return {user: user, linked_account: linked, accounts: [linked]}
        end

        found_user = adapter.find_one(model: "user", where: [{field: "email", value: email.to_s.downcase}])
        return nil unless found_user

        {user: found_user, linked_account: nil, accounts: find_accounts(found_user["id"])}
      end

      def find_user_by_email(email, include_accounts: false)
        user = adapter.find_one(model: "user", where: [{field: "email", value: email.to_s.downcase}])
        return nil unless user

        {user: user, accounts: include_accounts ? find_accounts(user["id"]) : []}
      end

      def find_user_by_id(user_id)
        return nil if user_id.to_s.empty?

        adapter.find_one(model: "user", where: [{field: "id", value: user_id}])
      end

      def update_user(user_id, data)
        user = hooks.update(stringify_keys(data), [{field: "id", value: user_id}], "user")
        refresh_user_sessions(user) if user
        user
      end

      def update_user_by_email(email, data)
        user = hooks.update(stringify_keys(data), [{field: "email", value: email.to_s.downcase}], "user")
        refresh_user_sessions(user) if user
        user
      end

      def update_password(user_id, password)
        hooks.update_many({password: password}, [{field: "userId", value: user_id}, {field: "providerId", value: "credential"}], "account")
      end

      def find_accounts(user_id)
        adapter.find_many(model: "account", where: [{field: "userId", value: user_id}])
      end

      def find_account(account_id)
        adapter.find_one(model: "account", where: [{field: "accountId", value: account_id}])
      end

      def find_account_by_provider_id(account_id, provider_id)
        adapter.find_one(model: "account", where: [{field: "accountId", value: account_id}, {field: "providerId", value: provider_id}])
      end

      def find_account_by_user_id(user_id)
        find_accounts(user_id)
      end

      def update_account(id, data)
        hooks.update(stringify_keys(data), [{field: "id", value: id}], "account")
      end

      def create_verification_value(data)
        payload = timestamps.merge(stringify_keys(data))
        stored_identifier = processed_verification_identifier(payload.fetch("identifier"))
        payload["identifier"] = stored_identifier

        custom = secondary_storage && lambda do |verification_data|
          actual = apply_schema_create("verification", verification_data)
          actual["id"] ||= generated_id
          store_verification(actual)
          adapter.create(model: "verification", data: actual, force_allow_id: true) if verification_store_in_database?
          actual
        end

        hooks.create(payload, "verification", custom: custom)
      end

      def find_verification_value(identifier)
        stored_identifier = processed_verification_identifier(identifier)
        storage_option = verification_storage_option(identifier)
        if secondary_storage
          cached = read_verification(stored_identifier)
          cached ||= read_verification(identifier) if storage_option && storage_option.to_s != "plain"
          return cached if cached
          return nil unless verification_store_in_database?
        end

        values = adapter.find_many(
          model: "verification",
          where: [{field: "identifier", value: stored_identifier}],
          sort_by: {field: "createdAt", direction: "desc"},
          limit: 1
        )
        if values.empty? && storage_option && storage_option.to_s != "plain"
          values = adapter.find_many(
            model: "verification",
            where: [{field: "identifier", value: identifier}],
            sort_by: {field: "createdAt", direction: "desc"},
            limit: 1
          )
        end
        hooks.delete_many([{field: "expiresAt", value: Time.now, operator: "lt"}], "verification") unless options.verification[:disable_cleanup]
        values.first
      end

      def consume_verification_value(identifier)
        identifiers = verification_identifiers(identifier)
        consumed = if secondary_storage && !verification_store_in_database?
          consume_secondary_verification(identifiers)
        else
          consume_database_verification(identifiers)
        end

        invalidate_secondary_verification(identifiers, consumed) if consumed && secondary_storage && verification_store_in_database?
        return nil unless consumed

        expires_at = normalize_time(consumed["expiresAt"] || consumed[:expiresAt])
        (expires_at > Time.now) ? normalize_verification_dates(consumed) : nil
      rescue ArgumentError, TypeError
        nil
      end

      def reserve_verification_value(data)
        payload = stringify_keys(data)
        identifier = payload.fetch("identifier")
        stored_identifier = processed_verification_identifier(identifier)
        reservation_id = Crypto.sha256("reserve:#{identifier}", encoding: :base64url)
        verification = timestamps.merge(
          "id" => reservation_id,
          "identifier" => stored_identifier,
          "value" => payload.fetch("value"),
          "expiresAt" => normalize_time(payload.fetch("expiresAt"))
        )

        if secondary_storage && !verification_store_in_database?
          return reserve_secondary_verification(verification)
        end

        adapter.consume_one(
          model: "verification",
          where: [
            {field: "id", value: reservation_id},
            {field: "expiresAt", value: Time.now, operator: "lt"}
          ]
        )
        created = adapter.create_if_absent(
          model: "verification",
          data: verification,
          conflict_field: "id",
          force_allow_id: true
        )
        store_reserved_verification(verification) if created && secondary_storage
        created
      end

      def delete_verification_value(id)
        if secondary_storage
          stored_identifier = secondary_storage.get(verification_id_key(id))
          if stored_identifier
            secondary_storage.delete(verification_key(stored_identifier))
            secondary_storage.delete(verification_id_key(id))
            return nil unless verification_store_in_database?
          elsif !verification_store_in_database?
            return nil
          end
        end

        hooks.delete([{field: "id", value: id}], "verification")
      end

      def delete_verification_by_identifier(identifier)
        stored_identifier = processed_verification_identifier(identifier)
        if secondary_storage
          cached = read_verification(stored_identifier)
          secondary_storage.delete(verification_key(stored_identifier))
          secondary_storage.delete(verification_id_key(cached["id"])) if cached && cached["id"]
          return nil unless verification_store_in_database?
        end

        hooks.delete([{field: "identifier", value: stored_identifier}], "verification")
      end

      def update_verification_value(id, data)
        update = stringify_keys(data)
        if secondary_storage
          stored_identifier = secondary_storage.get(verification_id_key(id))
          if stored_identifier
            cached = read_verification(stored_identifier)
            if cached
              updated = cached.merge(update)
              store_verification(updated)
              return updated unless verification_store_in_database?
            end
          elsif !verification_store_in_database?
            return nil
          end
        end

        hooks.update(update, [{field: "id", value: id}], "verification")
      end

      private

      def verification_identifiers(identifier)
        stored_identifier = processed_verification_identifier(identifier)
        storage_option = verification_storage_option(identifier)
        if storage_option && storage_option.to_s != "plain" && stored_identifier != identifier.to_s
          [stored_identifier, identifier.to_s]
        else
          [stored_identifier]
        end
      end

      def consume_secondary_verification(identifiers)
        identifiers.each do |stored_identifier|
          key = verification_key(stored_identifier)
          raw = if secondary_storage.respond_to?(:get_and_delete)
            secondary_storage.get_and_delete(key)
          elsif secondary_storage.respond_to?(:getAndDelete)
            secondary_storage.getAndDelete(key)
          else
            raise Error, "Secondary storage must implement atomic `get_and_delete`/`getAndDelete`, or verification values must be database-backed"
          end
          consumed = begin
            parsed = parse_storage(raw)
            parsed ? normalize_verification_dates(parsed) : nil
          rescue ArgumentError, TypeError
            nil
          end
          next unless consumed

          invalidate_secondary_verification(identifiers, consumed)
          return consumed
        end
        nil
      end

      def reserve_secondary_verification(verification)
        key = verification_key(verification.fetch("identifier"))
        ttl_seconds = ttl(millis(verification.fetch("expiresAt")))
        return false unless ttl_seconds.positive?

        value = JSON.generate(normalize_verification_dates(verification))
        created = if secondary_storage.respond_to?(:set_if_absent)
          secondary_storage.set_if_absent(key, value, ttl_seconds)
        elsif secondary_storage.respond_to?(:setIfAbsent)
          secondary_storage.setIfAbsent(key, value, ttl_seconds)
        else
          raise Error, "Secondary storage must implement atomic `set_if_absent`/`setIfAbsent`, or verification values must be database-backed"
        end
        return false unless created
        true
      end

      def consume_database_verification(identifiers)
        identifiers.each do |stored_identifier|
          consumed = with_verification_lock(verification_key(stored_identifier)) do
            adapter.transaction do |transaction_adapter|
              where = [{field: "identifier", value: stored_identifier}]
              latest = transaction_adapter.find_many(
                model: "verification",
                where: where,
                sort_by: {field: "createdAt", direction: "desc"},
                limit: 1
              ).first
              next nil unless latest
              next nil if verification_delete_vetoed?(latest)

              row = transaction_adapter.consume_one(
                model: "verification",
                where: [{field: "id", value: latest.fetch("id")}]
              )
              next nil unless row

              transaction_adapter.delete_many(model: "verification", where: where)
              run_verification_delete_after(row)
              row
            end
          end
          return consumed if consumed
        end
        nil
      end

      def invalidate_secondary_verification(identifiers, consumed)
        identifiers.each { |stored_identifier| secondary_storage.delete(verification_key(stored_identifier)) }
        id = consumed && (consumed["id"] || consumed[:id])
        secondary_storage.delete(verification_id_key(id)) if id
      end

      def verification_delete_vetoed?(entity)
        hooks.send(:before_hooks, "verification", :delete).any? { |hook| hook.call(entity, nil) == false }
      end

      def run_verification_delete_after(entity)
        hooks.send(:after_hooks, "verification", :delete).each { |hook| hook.call(entity, nil) }
      end

      def with_verification_lock(key)
        lock = @verification_locks_guard.synchronize { @verification_locks[key] ||= Monitor.new }
        lock.synchronize { yield }
      end

      def secondary_storage
        options.secondary_storage
      end

      def joins_enabled?
        !!options.experimental[:joins]
      end

      def find_session_with_user(token)
        return adapter.find_one(model: "session", where: [{field: "token", value: token}], join: {user: true}) if joins_enabled?

        session = adapter.find_one(model: "session", where: [{field: "token", value: token}])
        user = session && adapter.find_one(model: "user", where: [{field: "id", value: session["userId"]}])
        (session && user) ? session.merge("user" => user) : nil
      end

      def find_account_with_user(account_id, provider_id)
        if joins_enabled?
          return adapter.find_one(model: "account", where: [{field: "accountId", value: account_id}, {field: "providerId", value: provider_id}], join: {user: true})
        end

        account = adapter.find_one(model: "account", where: [{field: "accountId", value: account_id}, {field: "providerId", value: provider_id}])
        user = account && adapter.find_one(model: "user", where: [{field: "id", value: account["userId"]}])
        (account && user) ? account.merge("user" => user) : account
      end

      def timestamps
        now = Time.now
        {"createdAt" => now, "updatedAt" => now}
      end

      def generated_id
        generator = options.advanced.dig(:database, :generate_id)
        return generator.call.to_s if generator.respond_to?(:call)
        return SecureRandom.uuid if generator == "uuid"

        SecureRandom.hex(16)
      end

      def stringify_keys(data)
        data.each_with_object({}) do |(key, value), result|
          result[Schema.storage_key(key)] = value
        end
      end

      def apply_schema_create(model, data)
        fields = Schema.auth_tables(options)[model]&.fetch(:fields)
        fields ||= session_additional_fields if model == "session"
        output = stringify_keys(data)
        return output unless fields

        fields.each do |field, attributes|
          unless output.key?(field)
            if attributes.key?(:default_value)
              output[field] = resolve_default(attributes[:default_value])
            elsif attributes[:required] && field != "id"
              raise APIError.new("BAD_REQUEST", message: "#{field} is required")
            end
          end
          output[field] = coerce_value(output[field], attributes) if output.key?(field)
        end
        output
      end

      def session_additional_fields
        (options.session[:additional_fields] || {}).each_with_object({}) do |(key, value), result|
          result[Schema.storage_key(key)] = value
        end
      end

      def resolve_default(default)
        default.respond_to?(:call) ? default.call : default
      end

      def coerce_value(value, attributes)
        return value if value.nil?
        return Time.parse(value) if attributes[:type] == "date" && value.is_a?(String)

        value
      end

      def store_session(session)
        user = adapter.find_one(model: "user", where: [{field: "id", value: session["userId"]}])
        now_ms = current_millis
        expires_ms = millis(session["expiresAt"])
        entries = active_session_entries(session["userId"])
          .reject { |entry| entry["expiresAt"].to_i <= now_ms || entry["token"] == session["token"] }
          .push({"token" => session["token"], "expiresAt" => expires_ms})
          .sort_by { |entry| entry["expiresAt"] }
        write_active_sessions(session["userId"], entries)
        ttl_seconds = ttl(expires_ms)
        secondary_storage.set(session["token"], JSON.generate({session: session, user: user}), ttl_seconds) if ttl_seconds.positive?
      end

      def update_stored_session(token, data)
        parsed = parse_storage(secondary_storage.get(token))
        return nil unless parsed && parsed["session"]

        merged = parsed["session"].merge(data)
        merged["expiresAt"] = normalize_time(merged["expiresAt"])
        merged["createdAt"] = normalize_time(merged["createdAt"])
        merged["updatedAt"] = normalize_time(merged["updatedAt"])
        ttl_seconds = ttl(millis(merged["expiresAt"]))
        if ttl_seconds.positive?
          secondary_storage.set(token, JSON.generate({session: merged, user: parsed["user"]}), ttl_seconds)
        else
          secondary_storage.delete(token)
        end
        entries = active_session_entries(merged["userId"])
          .reject { |entry| entry["token"] == token || entry["expiresAt"].to_i <= current_millis }
          .push({"token" => token, "expiresAt" => millis(merged["expiresAt"])})
          .sort_by { |entry| entry["expiresAt"] }
        write_active_sessions(merged["userId"], entries)
        merged
      end

      def refresh_user_sessions(user)
        return unless secondary_storage && user

        active_session_entries(user["id"]).each do |entry|
          parsed = parse_storage(secondary_storage.get(entry["token"]))
          next unless parsed && parsed["session"]

          secondary_storage.set(entry["token"], JSON.generate({session: parsed["session"], user: user}), ttl(millis(parsed["session"]["expiresAt"])))
        end
      end

      def active_session_entries(user_id)
        raw = secondary_storage.get(active_key(user_id))
        Array(parse_storage(raw)).map do |entry|
          entry.transform_keys(&:to_s)
        end.uniq { |entry| entry["token"] }
      end

      def write_active_sessions(user_id, entries)
        future = entries.select { |entry| entry["expiresAt"].to_i > current_millis }.sort_by { |entry| entry["expiresAt"] }
        if future.empty?
          secondary_storage.delete(active_key(user_id))
        else
          ttl_seconds = ttl(future.last["expiresAt"])
          if ttl_seconds.positive?
            secondary_storage.set(active_key(user_id), JSON.generate(future), ttl_seconds)
          else
            secondary_storage.delete(active_key(user_id))
          end
        end
      end

      def active_key(user_id)
        "active-sessions-#{user_id}"
      end

      def parse_storage(value)
        return value.transform_keys(&:to_s) if value.is_a?(Hash)
        return value.map { |entry| entry.is_a?(Hash) ? entry.transform_keys(&:to_s) : entry } if value.is_a?(Array)
        return nil unless value

        parsed = JSON.parse(value)
        parse_storage(parsed)
      rescue JSON::ParserError
        nil
      end

      def normalize_session_dates(session)
        return nil unless session

        session.transform_keys(&:to_s).merge(
          "expiresAt" => normalize_time(session["expiresAt"] || session[:expiresAt]),
          "createdAt" => normalize_time(session["createdAt"] || session[:createdAt]),
          "updatedAt" => normalize_time(session["updatedAt"] || session[:updatedAt])
        )
      end

      def normalize_user_dates(user)
        return nil unless user

        user.transform_keys(&:to_s).merge(
          "createdAt" => normalize_time(user["createdAt"] || user[:createdAt]),
          "updatedAt" => normalize_time(user["updatedAt"] || user[:updatedAt])
        )
      end

      def normalize_verification_dates(verification)
        return nil unless verification

        verification.transform_keys(&:to_s).merge(
          "expiresAt" => normalize_time(verification["expiresAt"] || verification[:expiresAt]),
          "createdAt" => normalize_time(verification["createdAt"] || verification[:createdAt]),
          "updatedAt" => normalize_time(verification["updatedAt"] || verification[:updatedAt])
        )
      end

      def store_verification(verification)
        normalized = normalize_verification_dates(verification)
        ttl_seconds = ttl(millis(normalized["expiresAt"]))
        return normalized unless ttl_seconds.positive?

        secondary_storage.set(verification_key(normalized["identifier"]), JSON.generate(normalized), ttl_seconds)
        secondary_storage.set(verification_id_key(normalized["id"]), normalized["identifier"], ttl_seconds) if normalized["id"]
        normalized
      end

      def store_reserved_verification(verification)
        normalized = normalize_verification_dates(verification)
        ttl_seconds = ttl(millis(normalized["expiresAt"]))
        return normalized unless ttl_seconds.positive?

        secondary_storage.set(verification_key(normalized["identifier"]), JSON.generate(normalized), ttl_seconds)
        normalized
      end

      def read_verification(identifier)
        normalize_verification_dates(parse_storage(secondary_storage.get(verification_key(identifier))))
      end

      def verification_key(identifier)
        "verification:#{identifier}"
      end

      def verification_id_key(id)
        "verification-id:#{id}"
      end

      def verification_store_in_database?
        !!options.verification[:store_in_database]
      end

      def processed_verification_identifier(identifier)
        option = verification_storage_option(identifier)
        return identifier.to_s if option.nil? || option.to_s == "plain"
        return Crypto.sha256(identifier.to_s, encoding: :base64url) if option.to_s == "hashed"
        return option[:hash].call(identifier.to_s).to_s if option.is_a?(Hash) && option[:hash].respond_to?(:call)
        return option["hash"].call(identifier.to_s).to_s if option.is_a?(Hash) && option["hash"].respond_to?(:call)

        identifier.to_s
      end

      def verification_storage_option(identifier)
        config = options.verification[:store_identifier]
        return nil unless config

        if config.is_a?(Hash) && (config.key?(:default) || config.key?("default"))
          overrides = config[:overrides] || config["overrides"] || {}
          overrides.each do |prefix, option|
            return option if identifier.to_s.start_with?(prefix.to_s)
          end
          return config[:default] || config["default"]
        end

        config
      end

      def normalize_time(value)
        return value if value.is_a?(Time)
        return Time.at(value / 1000.0) if value.is_a?(Integer) && value > 10_000_000_000
        return Time.at(value) if value.is_a?(Integer)

        Time.parse(value.to_s)
      end

      def millis(value)
        (normalize_time(value).to_f * 1000).to_i
      end

      def ttl(expires_ms)
        [(expires_ms - current_millis) / 1000, 0].max.floor
      end

      def current_millis
        (Time.now.to_f * 1000).to_i
      end
    end
  end
end
