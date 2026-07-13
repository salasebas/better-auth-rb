# frozen_string_literal: true

require "better_auth"
require_relative "redis_storage/version"

module BetterAuth
  class RedisStorage
    UNSET = Object.new.freeze
    DEFAULT_KEY_PREFIX = "better-auth:"
    SCAN_DEFAULT_COUNT = 100
    DELETE_CHUNK_SIZE = 500
    GET_AND_DELETE_SCRIPT = <<~LUA
      local value = redis.call("GET", KEYS[1])
      if value ~= false then
        redis.call("DEL", KEYS[1])
      end
      return value
    LUA
    INCREMENT_SCRIPT = <<~LUA
      local value = redis.call("INCR", KEYS[1])
      if value == 1 then
        redis.call("EXPIRE", KEYS[1], ARGV[1])
      end
      return value
    LUA
    JSON_LIST_ADD_SCRIPT = <<~LUA
      local raw = redis.call("GET", KEYS[1])
      local values = {}
      if raw then
        local ok, decoded = pcall(cjson.decode, raw)
        local valid = ok and type(decoded) == "table" and string.match(raw, "^%s*%[") ~= nil and string.match(raw, "%]%s*$") ~= nil
        if valid then
          local count = 0
          for key, _ in pairs(decoded) do
            if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then valid = false break end
            count = count + 1
          end
          if valid then
            for index = 1, count do
              if decoded[index] == nil then valid = false break end
            end
          end
        end
        if valid then values = decoded end
      end
      local id = ARGV[1]
      for _, value in ipairs(values) do
        if tostring(value) == id then return 0 end
      end
      table.insert(values, id)
      redis.call("SET", KEYS[1], cjson.encode(values))
      return 1
    LUA
    JSON_LIST_REMOVE_SCRIPT = <<~LUA
      local raw = redis.call("GET", KEYS[1])
      if not raw then return 0 end
      local ok, decoded = pcall(cjson.decode, raw)
      local valid = ok and type(decoded) == "table" and string.match(raw, "^%s*%[") ~= nil and string.match(raw, "%]%s*$") ~= nil
      if valid then
        local count = 0
        for key, _ in pairs(decoded) do
          if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then valid = false break end
          count = count + 1
        end
        if valid then
          for index = 1, count do
            if decoded[index] == nil then valid = false break end
          end
        end
      end
      if not valid then redis.call("DEL", KEYS[1]) return 0 end
      local id = ARGV[1]
      local values = {}
      local removed = 0
      for _, value in ipairs(decoded) do
        if tostring(value) == id then removed = 1 else table.insert(values, value) end
      end
      if #values == 0 then redis.call("DEL", KEYS[1]) else redis.call("SET", KEYS[1], cjson.encode(values)) end
      return removed
    LUA

    attr_reader :client, :key_prefix, :scan_count, :atomic_clear

    def self.build(client:, key_prefix: UNSET, scan_count: UNSET, atomic_clear: false, **options)
      key_prefix_camel = extract_key_prefix_camel!(options)
      reject_unknown_keywords!(options)
      new(client: client, key_prefix: key_prefix, key_prefix_camel: key_prefix_camel, scan_count: scan_count, atomic_clear: atomic_clear)
    end

    def self.redisStorage(client:, key_prefix: UNSET, scan_count: UNSET, atomic_clear: false, **options)
      key_prefix_camel = extract_key_prefix_camel!(options)
      reject_unknown_keywords!(options)
      new(client: client, key_prefix: key_prefix, key_prefix_camel: key_prefix_camel, scan_count: scan_count, atomic_clear: atomic_clear)
    end

    def initialize(client:, key_prefix: UNSET, key_prefix_camel: UNSET, scan_count: UNSET, atomic_clear: false, **options)
      key_prefix_camel = self.class.extract_key_prefix_camel!(options) if key_prefix_camel.equal?(UNSET)
      self.class.reject_unknown_keywords!(options)
      @client = client
      @key_prefix = self.class.resolve_key_prefix(key_prefix, key_prefix_camel)
      scan_count = SCAN_DEFAULT_COUNT if scan_count.equal?(UNSET)
      if !scan_count.nil? && !(scan_count.is_a?(Integer) && scan_count.positive?)
        raise ArgumentError, "scan_count must be nil or a positive Integer; got #{scan_count.inspect}"
      end
      @scan_count = scan_count
      @atomic_clear = !!atomic_clear
      @supports_getdel = true
    end

    def self.extract_key_prefix_camel!(options)
      options.key?(:keyPrefix) ? options.delete(:keyPrefix) : UNSET
    end

    def self.reject_unknown_keywords!(options)
      return if options.empty?

      unknown = options.keys.map(&:inspect).join(", ")
      label = (options.length == 1) ? "keyword" : "keywords"
      raise ArgumentError, "unknown #{label}: #{unknown}"
    end

    def self.resolve_key_prefix(key_prefix, key_prefix_camel)
      if !key_prefix.equal?(UNSET) && !key_prefix_camel.equal?(UNSET) && key_prefix != key_prefix_camel
        raise ArgumentError, "key_prefix and keyPrefix cannot both be provided with different values"
      end

      selected = key_prefix.equal?(UNSET) ? key_prefix_camel : key_prefix
      selected = DEFAULT_KEY_PREFIX if selected.equal?(UNSET) || selected.nil?
      selected.to_s
    end

    def get(key)
      client.get(prefix_key(key))
    end

    def get_and_delete(key)
      prefixed_key = prefix_key(key)
      if @supports_getdel
        begin
          return client.getdel(prefixed_key) if client.respond_to?(:getdel)
          return client.call("GETDEL", prefixed_key) if client.respond_to?(:call)

          @supports_getdel = false
        rescue => error
          raise unless unknown_command_error?(error)

          @supports_getdel = false
        end
      end

      eval_script(GET_AND_DELETE_SCRIPT, keys: [prefixed_key])
    end

    def increment(key, ttl)
      seconds = coerce_ttl(ttl)
      raise ArgumentError, "ttl must be a positive number of seconds" unless seconds

      Integer(eval_script(INCREMENT_SCRIPT, keys: [prefix_key(key)], argv: [seconds]))
    end

    # Atomically mutate a JSON array stored at +key+. These operations keep
    # API-key reference indexes from losing IDs under concurrent writers.
    def json_list_add(key, id)
      eval_script(JSON_LIST_ADD_SCRIPT, keys: [prefix_key(key)], argv: [id.to_s])
      nil
    end

    def json_list_remove(key, id)
      eval_script(JSON_LIST_REMOVE_SCRIPT, keys: [prefix_key(key)], argv: [id.to_s])
      nil
    end

    def set(key, value, ttl = nil)
      prefixed_key = prefix_key(key)
      coerced_ttl = coerce_ttl(ttl)
      if coerced_ttl
        client.setex(prefixed_key, coerced_ttl, value)
      else
        client.set(prefixed_key, value)
      end
      nil
    end

    def set_if_absent(key, value, ttl = nil)
      options = {nx: true}
      coerced_ttl = coerce_ttl(ttl)
      options[:ex] = coerced_ttl if coerced_ttl
      result = client.set(prefix_key(key), value, **options)
      result == true || result.to_s == "OK"
    end

    def delete(key)
      client.del(prefix_key(key))
      nil
    end

    def list_keys
      prefix = storage_prefix
      storage_keys(prefix).map { |key| unprefix_key(key, prefix) }
    end

    def clear
      if atomic_clear
        clear_current_generation
      else
        delete_matching_keys(storage_prefix)
      end
      nil
    end

    alias_method :listKeys, :list_keys
    alias_method :getAndDelete, :get_and_delete
    alias_method :setIfAbsent, :set_if_absent

    private

    def prefix_key(key)
      raise ArgumentError, "secondary storage key must not be nil" if key.nil?

      "#{storage_prefix}#{key}"
    end

    def unprefix_key(key, prefix = storage_prefix)
      key.sub(/\A#{Regexp.escape(prefix)}/, "")
    end

    def storage_prefix(generation = current_generation)
      return key_prefix unless atomic_clear

      "#{key_prefix}v#{generation}:"
    end

    def generation_key
      "#{key_prefix}__generation__"
    end

    def current_generation
      return nil unless atomic_clear

      generation = client.get(generation_key).to_i
      generation.positive? ? generation : 1
    end

    def clear_current_generation
      generation = current_generation
      bump_generation(generation)
      delete_matching_keys(storage_prefix(generation), single_key: true)
    end

    def bump_generation(previous_generation)
      generation = client.incr(generation_key).to_i
      generation = client.incr(generation_key).to_i if generation <= previous_generation.to_i
      generation
    end

    def storage_keys(prefix = storage_prefix)
      return scan_keys(prefix) if scan_count

      client.keys(match_pattern(prefix))
    end

    def scan_keys(prefix = storage_prefix)
      seen = {}
      matches = []
      each_scan_batch(prefix) do |keys|
        keys.each do |key|
          next if seen[key]

          seen[key] = true
          matches << key
        end
      end
      matches
    end

    def each_scan_batch(prefix = storage_prefix)
      cursor = "0"
      loop do
        cursor, keys = client.scan(cursor, match: match_pattern(prefix), count: scan_count)
        yield keys
        break if cursor.to_s == "0"
      end
    end

    def delete_matching_keys(prefix, single_key: false)
      delete_keys(storage_keys(prefix), single_key: single_key)
    end

    def delete_keys(keys, single_key: false)
      # Upstream calls del(...keys) unconditionally; Ruby keeps this guard to
      # avoid Redis ERR wrong number of arguments when no prefixed keys exist.
      if single_key
        keys.each { |key| client.del(key) }
      else
        keys.each_slice(DELETE_CHUNK_SIZE) { |chunk| client.del(*chunk) }
      end
    end

    def match_pattern(prefix)
      "#{redis_glob_escape(prefix)}*"
    end

    def redis_glob_escape(value)
      value.to_s.gsub(/[\\*?\[\]]/) { |character| "\\#{character}" }
    end

    def coerce_ttl(ttl)
      numeric = case ttl
      when nil
        nil
      when Integer
        ttl
      when Float
        ttl.finite? ? ttl : nil
      when String
        Integer(ttl, exception: false)
      when Numeric
        ttl.to_f
      end

      return nil unless numeric.is_a?(Numeric)
      return nil unless numeric.respond_to?(:positive?) && numeric.positive?
      return nil if numeric.respond_to?(:finite?) && !numeric.finite?

      seconds = numeric.is_a?(Integer) ? numeric : numeric.to_i
      seconds.positive? ? seconds : nil
    end

    def eval_script(script, keys:, argv: [])
      client.eval(script, keys: keys, argv: argv)
    rescue ArgumentError
      client.eval(script, keys.length, *keys, *argv)
    end

    def unknown_command_error?(error)
      error.message.to_s.downcase.include?("unknown command")
    end
  end

  def self.redis_storage(client:, key_prefix: RedisStorage::UNSET, scan_count: RedisStorage::UNSET, atomic_clear: false, **options)
    key_prefix_camel = RedisStorage.extract_key_prefix_camel!(options)
    RedisStorage.reject_unknown_keywords!(options)
    RedisStorage.new(client: client, key_prefix: key_prefix, key_prefix_camel: key_prefix_camel, scan_count: scan_count, atomic_clear: atomic_clear)
  end

  def self.redisStorage(client:, key_prefix: RedisStorage::UNSET, scan_count: RedisStorage::UNSET, atomic_clear: false, **options)
    key_prefix_camel = RedisStorage.extract_key_prefix_camel!(options)
    RedisStorage.reject_unknown_keywords!(options)
    RedisStorage.new(client: client, key_prefix: key_prefix, key_prefix_camel: key_prefix_camel, scan_count: scan_count, atomic_clear: atomic_clear)
  end
end
