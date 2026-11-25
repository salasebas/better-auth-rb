# frozen_string_literal: true

module BetterAuth
  class APIError < Error
    STATUS_CODES = {
      "BAD_REQUEST" => 400,
      "UNAUTHORIZED" => 401,
      "UNAUTHORIZED_INVALID_OR_EXPIRED_NONCE" => 401,
      "FORBIDDEN" => 403,
      "CONFLICT" => 409,
      "NOT_FOUND" => 404,
      "METHOD_NOT_ALLOWED" => 405,
      "UNSUPPORTED_MEDIA_TYPE" => 415,
      "UNPROCESSABLE_ENTITY" => 422,
      "TOO_MANY_REQUESTS" => 429,
      "BAD_GATEWAY" => 502,
      "NOT_IMPLEMENTED" => 501,
      "FOUND" => 302,
      "INTERNAL_SERVER_ERROR" => 500
    }.freeze

    attr_reader :status, :status_code, :headers, :code, :body

    def initialize(status, message: nil, headers: {}, code: nil, body: nil, response_headers: nil)
      @status = status.to_s.upcase
      @status_code = STATUS_CODES.fetch(@status, 500)
      @headers = response_headers || normalize_headers(headers)
      @code = code || @status
      @body = body
      super(message || default_message)
    end

    def to_h
      return body if body

      {
        code: code,
        message: message
      }
    end

    private

    def default_message
      status.split("_").map(&:capitalize).join(" ")
    end

    def normalize_headers(headers)
      headers.each_with_object({}) do |(key, value), result|
        result[key.to_s.downcase] = value
      end
    end
  end
end
