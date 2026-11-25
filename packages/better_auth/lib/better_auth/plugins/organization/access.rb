# frozen_string_literal: true

module BetterAuth
  module Plugins
    ORGANIZATION_DEFAULT_STATEMENTS = {
      organization: ["update", "delete"],
      member: ["create", "update", "delete"],
      invitation: ["create", "cancel"],
      team: ["create", "update", "delete"],
      ac: ["create", "read", "update", "delete"]
    }.freeze

    module_function

    def organization_default_roles(config = {})
      ac = config[:ac] || create_access_control(ORGANIZATION_DEFAULT_STATEMENTS)
      {
        "admin" => ac.new_role(organization: ["update"], invitation: ["create", "cancel"], member: ["create", "update", "delete"], team: ["create", "update", "delete"], ac: ["create", "read", "update", "delete"]),
        "owner" => ac.new_role(organization: ["update", "delete"], member: ["create", "update", "delete"], invitation: ["create", "cancel"], team: ["create", "update", "delete"], ac: ["create", "read", "update", "delete"]),
        "member" => ac.new_role(organization: [], member: [], invitation: [], team: [], ac: ["read"])
      }
    end
  end
end
