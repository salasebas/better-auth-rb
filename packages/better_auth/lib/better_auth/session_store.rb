# frozen_string_literal: true

module BetterAuth
  class SessionStore
    MAX_COOKIE_SIZE = 4050
    MAX_COOKIE_CHUNKS = 100

    CookieValue = Struct.new(:name, :value, :attributes)

    attr_reader :cookie_name, :cookie_options, :context, :chunks

    def initialize(cookie_name, cookie_options, context, store_name: "Session")
      @cookie_name = cookie_name
      @cookie_options = cookie_options || {}
      @context = context
      @store_name = store_name
      @chunks = read_existing_chunks
    end

    def value
      chunks[cookie_name] || self.class.chunked_value(chunks, cookie_name)
    end

    def chunk(value, options = {})
      cookies = clean.to_h { |cookie| [cookie.name, cookie] }
      build_chunks(value.to_s, cookie_options.merge(options || {})).each do |cookie|
        cookies[cookie.name] = cookie
      end
      cookies.values
    end

    def clean
      existing = chunks.keys.map do |name|
        CookieValue.new(name: name, value: "", attributes: cookie_options.merge(max_age: 0))
      end
      chunks.clear
      existing
    end

    def set_cookies(cookies)
      cookies.each do |cookie|
        context.set_cookie(cookie.name, cookie.value, cookie.attributes)
      end
    end

    def self.get_chunked_cookie(context, cookie_name)
      direct = context.get_cookie(cookie_name)
      return direct if direct && !direct.empty?

      chunked_value(context.cookies, cookie_name)
    end

    def self.chunked_value(cookies, cookie_name)
      join_chunks(cookies.select { |name, _| name.start_with?("#{cookie_name}.") })
    end

    def self.join_chunks(chunks)
      indexed = chunks.filter_map.with_index do |(name, value), position|
        suffix = name.rpartition(".").last
        index = suffix.empty? ? 0 : Cookies.parse_cookie_integer(suffix)
        [index, position, value] if index
      end
      return nil if indexed.empty?

      indexed.sort_by { |index, position, _| [index, position] }.map(&:last).join
    end

    private

    def read_existing_chunks
      context.cookies.select { |name, _| name.start_with?(cookie_name) }
    end

    def build_chunks(value, attributes)
      overhead = context.serialize_cookie("#{cookie_name}.#{MAX_COOKIE_CHUNKS - 1}", "", attributes).bytesize
      chunk_size = MAX_COOKIE_SIZE - overhead
      if chunk_size <= 0 || value.bytesize > chunk_size * MAX_COOKIE_CHUNKS
        warn_oversized_cookie
        return []
      end

      return [build_cookie(cookie_name, value, attributes)] if value.bytesize <= chunk_size

      (0...value.bytesize).step(chunk_size).with_index.map do |offset, index|
        build_cookie("#{cookie_name}.#{index}", value.byteslice(offset, chunk_size), attributes)
      end
    end

    def build_cookie(name, value, attributes)
      chunks[name] = value
      CookieValue.new(name: name, value: value, attributes: attributes)
    end

    def warn_oversized_cookie
      message = "#{@store_name} cookie is too large to store even after chunking, so the cache was skipped. Reduce the cached data or use a database session."
      logger = context.context.logger || Logger.create
      if logger.respond_to?(:call)
        logger.call(:warn, message)
      elsif logger.respond_to?(:warn)
        logger.warn(message)
      end
    end
  end
end
