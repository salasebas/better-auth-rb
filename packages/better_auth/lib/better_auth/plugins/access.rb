# frozen_string_literal: true

module BetterAuth
  module Plugins
    class Role
      attr_reader :statements

      def initialize(statements)
        @statements = stringify_statements(statements)
      end

      def authorize(request, connector = "AND")
        connector = (connector == "OR") ? "OR" : "AND"
        success = false
        stringify_request(request).each do |resource, requested_actions|
          allowed_actions = statements[resource]
          unless allowed_actions
            next if connector == "OR"

            return {success: false, error: "You are not allowed to access resource: #{resource}"}
          end

          success = if requested_actions.is_a?(Array)
            requested_actions.any? && requested_actions.all? { |action| action.is_a?(String) && allowed_actions.include?(action) }
          elsif requested_actions.is_a?(Hash)
            raw_actions = requested_actions["actions"] || requested_actions[:actions]
            actions = raw_actions.is_a?(Array) ? raw_actions : []
            action_connector = ((requested_actions["connector"] || requested_actions[:connector]) == "OR") ? "OR" : "AND"
            if action_connector == "OR"
              actions.any? { |action| action.is_a?(String) && allowed_actions.include?(action) }
            else
              actions.any? && actions.all? { |action| action.is_a?(String) && allowed_actions.include?(action) }
            end
          else
            raise Error, "Invalid access control request"
          end

          return {success: true} if success && connector == "OR"
          return {success: false, error: "unauthorized to access resource \"#{resource}\""} if !success && connector == "AND"
        end

        success ? {success: true} : {success: false, error: "Not authorized"}
      end

      private

      def stringify_statements(value)
        (value || {}).each_with_object({}) do |(resource, actions), result|
          result[resource.to_s] = Array(actions).map(&:to_s)
        end
      end

      def stringify_request(value)
        (value || {}).each_with_object({}) do |(resource, actions), result|
          result[resource.to_s] = actions
        end
      end
    end

    class AccessControl
      attr_reader :statements

      def initialize(statements)
        @statements = (statements || {}).each_with_object({}) do |(resource, actions), result|
          result[resource.to_s] = Array(actions).map(&:to_s)
        end
      end

      def new_role(statements)
        Role.new(statements)
      end

      alias_method :newRole, :new_role
    end

    module_function

    def create_access_control(statements)
      AccessControl.new(statements)
    end

    singleton_class.alias_method :createAccessControl, :create_access_control
  end
end
