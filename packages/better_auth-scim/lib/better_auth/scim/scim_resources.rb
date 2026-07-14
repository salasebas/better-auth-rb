# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def scim_user_resource(user, account = nil, base_url = nil)
      {
        schemas: [SCIM_USER_SCHEMA_ID],
        id: user.fetch("id"),
        userName: user.fetch("email"),
        externalId: account&.fetch("accountId", nil),
        displayName: user["name"],
        active: user["banned"] != true,
        name: {formatted: user["name"]},
        emails: [{primary: true, value: user.fetch("email")}],
        meta: {
          resourceType: "User",
          created: user["createdAt"],
          lastModified: user["updatedAt"],
          location: base_url ? "#{base_url}/scim/v2/Users/#{user.fetch("id")}" : nil
        }.compact
      }.compact
    end
  end
end
