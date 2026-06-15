# frozen_string_literal: true

module BetterAuth
  class SessionStore
    ALLOWED_COOKIE_SIZE = 4096
    ESTIMATED_EMPTY_COOKIE_SIZE = 200
    CHUNK_SIZE = ALLOWED_COOKIE_SIZE - ESTIMATED_EMPTY_COOKIE_SIZE

    CookieValue = Struct.new(:name, :value, :attributes)

    attr_reader :cookie_name, :cookie_options, :context, :chunks

    def initialize(cookie_name, cookie_options, context)
      @cookie_name = cookie_name
      @cookie_options = cookie_options || {}
      @context = context
      @chunks = read_existing_chunks
    end

    def value
      self.class.join_chunks(chunks)
    end

    def chunks?
      !chunks.empty?
    end

    def chunk(value, options = {})
      cleaned = clean
      new_chunks = build_chunks(value.to_s, cookie_options.merge(options || {}))
      cleaned + new_chunks
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

      chunks = context.cookies.each_with_object({}) do |(name, value), result|
        result[name] = value if name.start_with?("#{cookie_name}.")
      end
      return nil if chunks.empty?

      join_chunks(chunks)
    end

    def self.join_chunks(chunks)
      chunks.keys.sort_by { |name| chunk_index(name) }.map { |name| chunks[name] }.join
    end

    def self.chunk_index(cookie_name)
      Integer(cookie_name.split(".").last)
    rescue ArgumentError, TypeError
      0
    end

    private

    def read_existing_chunks
      context.cookies.each_with_object({}) do |(name, value), result|
        result[name] = value if name == cookie_name || name.start_with?("#{cookie_name}.")
      end
    end

    def build_chunks(value, attributes)
      if value.length <= CHUNK_SIZE
        chunks[cookie_name] = value
        return [CookieValue.new(name: cookie_name, value: value, attributes: attributes)]
      end

      value.chars.each_slice(CHUNK_SIZE).map(&:join).each_with_index.map do |part, index|
        name = "#{cookie_name}.#{index}"
        chunks[name] = part
        CookieValue.new(name: name, value: part, attributes: attributes)
      end
    end
  end
end
