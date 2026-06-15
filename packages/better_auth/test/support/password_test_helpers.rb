# frozen_string_literal: true

module BetterAuthTestPasswordHelpers
  FAST_PASSWORD_PREFIX = "test-password:"

  module_function

  def fast_password_hash(password)
    "#{FAST_PASSWORD_PREFIX}#{password}"
  end

  def fast_password_verify(password = nil, hash = nil, **kwargs)
    pwd = kwargs[:password] || password
    digest = kwargs[:hash] || hash
    digest == fast_password_hash(pwd)
  end

  def fast_email_and_password_config(overrides = {})
    normalized = overrides.each_with_object({}) do |(key, value), result|
      result[key.to_sym] = value
    end

    base = {
      enabled: true,
      password: {
        hash: ->(password) { fast_password_hash(password) },
        verify: method(:fast_password_verify)
      }
    }

    merge_email_and_password(base, normalized)
  end

  def merge_email_and_password(base, overrides)
    base.merge(overrides) do |key, old_value, new_value|
      if key == :password && old_value.is_a?(Hash) && new_value.is_a?(Hash)
        old_value.merge(new_value)
      else
        new_value
      end
    end
  end
end
