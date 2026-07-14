# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def scim_apply_patch_value!(user, update, account_update, value, operation_name, path = nil)
      value.each do |key, nested_value|
        nested_key = Schema.storage_key(key)
        nested_path = path ? "#{path}.#{nested_key}" : nested_key
        if nested_value.is_a?(Hash)
          scim_apply_patch_value!(user, update, account_update, normalize_hash(nested_value), operation_name, nested_path)
        else
          scim_apply_patch_path!(user, update, account_update, nested_path, nested_value, operation_name)
        end
      end
    end

    def scim_apply_patch_path!(user, update, account_update, path, value, operation_name)
      remove = operation_name == "remove"
      normalized = "/" + path.to_s.sub(%r{\A/+}, "").tr(".", "/")
      case normalized
      when "/active"
        update[:banned] = value == false || value.to_s == "false" unless remove
      when "/userName"
        new_value = value.to_s.downcase
        if scim_patch_should_apply?(user["email"], new_value, operation_name)
          update[:email] = new_value
        end
      when "/externalId"
        account_update[:accountId] = value unless remove
      when "/name/formatted"
        update[:name] = value if scim_patch_should_apply?(user["name"], value, operation_name)
      when "/name/givenName"
        new_value = scim_full_name(user.fetch("email"), given_name: value, family_name: scim_family_name(update[:name] || user["name"]))
        update[:name] = new_value if scim_patch_should_apply?(user["name"], new_value, operation_name)
      when "/name/familyName"
        new_value = scim_full_name(user.fetch("email"), given_name: scim_given_name(update[:name] || user["name"]), family_name: value)
        update[:name] = new_value if scim_patch_should_apply?(user["name"], new_value, operation_name)
      end
    end

    def scim_patch_should_apply?(current_value, new_value, operation_name)
      return false if operation_name == "remove"
      return false if operation_name == "add" && current_value == new_value

      true
    end
  end
end
