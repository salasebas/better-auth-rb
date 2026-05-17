# frozen_string_literal: true

module BetterAuth
  module Env
    module_function

    def get(name)
      open_auth_name = open_auth_name(name)
      return nil unless open_auth_name

      value = ENV[open_auth_name]
      return value if present?(value)

      value = ENV[name]
      present?(value) ? value : nil
    end

    def fetch(name, default = nil)
      value = get(name)
      value.nil? ? default : value
    end

    def csv(name)
      fetch(name, "").split(",").map(&:strip).reject(&:empty?)
    end

    def open_auth_name(name)
      text = name.to_s
      return nil unless text.start_with?("BETTER_AUTH_")

      text.sub(/\ABETTER_AUTH_/, "OPEN_AUTH_")
    end

    def present?(value)
      value && !value.empty?
    end
  end
end
