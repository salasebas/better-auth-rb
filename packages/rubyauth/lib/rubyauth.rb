# frozen_string_literal: true

require "better_auth"

module RubyAuth
  VERSION = BetterAuth::VERSION unless const_defined?(:VERSION, false)

  def self.alias_better_auth_constants!
    BetterAuth.constants(false).each do |name|
      const_set(name, BetterAuth.const_get(name, false)) unless const_defined?(name, false)
    end
  end

  def self.auth(...)
    BetterAuth.auth(...)
  end

  def self.const_missing(name)
    constant = BetterAuth.const_get(name, false)
    const_set(name, constant) unless const_defined?(name, false)
    constant
  rescue NameError
    super
  end

  alias_better_auth_constants!
end
