# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def scim_user_schema(base_url = nil)
      {
        id: SCIM_USER_SCHEMA_ID,
        schemas: ["urn:ietf:params:scim:schemas:core:2.0:Schema"],
        name: "User",
        description: "User Account",
        attributes: [
          {name: "id", type: "string", multiValued: false, description: "Unique opaque identifier for the User", required: false, caseExact: true, mutability: "readOnly", returned: "default", uniqueness: "server"},
          {name: "userName", type: "string", multiValued: false, description: "Unique identifier for the User, typically used by the user to directly authenticate to the service provider", required: true, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "server"},
          {name: "displayName", type: "string", multiValued: false, description: "The name of the User, suitable for display to end-users.  The name SHOULD be the full name of the User being described, if known.", required: false, caseExact: true, mutability: "readOnly", returned: "default", uniqueness: "none"},
          {name: "active", type: "boolean", multiValued: false, description: "A Boolean value indicating the User's administrative status.", required: false, mutability: "readWrite", returned: "default"},
          {
            name: "name",
            type: "complex",
            multiValued: false,
            description: "The components of the user's real name.",
            required: false,
            subAttributes: [
              {name: "formatted", type: "string", multiValued: false, description: "The full name, including all middlenames, titles, and suffixes as appropriate, formatted for display(e.g., 'Ms. Barbara J Jensen, III').", required: false, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "none"},
              {name: "familyName", type: "string", multiValued: false, description: "The family name of the User, or last name in most Western languages (e.g., 'Jensen' given the fullname 'Ms. Barbara J Jensen, III').", required: false, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "none"},
              {name: "givenName", type: "string", multiValued: false, description: "The given name of the User, or first name in most Western languages (e.g., 'Barbara' given the full name 'Ms. Barbara J Jensen, III').", required: false, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "none"}
            ]
          },
          {
            name: "emails",
            type: "complex",
            multiValued: true,
            description: "Email addresses for the user.  The value SHOULD be canonicalized by the service provider, e.g., 'bjensen@example.com' instead of 'bjensen@EXAMPLE.COM'. Canonical type values of 'work', 'home', and 'other'.",
            required: false,
            mutability: "readWrite",
            returned: "default",
            uniqueness: "none",
            subAttributes: [
              {name: "value", type: "string", multiValued: false, description: "Email addresses for the user.  The value SHOULD be canonicalized by the service provider, e.g., 'bjensen@example.com' instead of 'bjensen@EXAMPLE.COM'. Canonical type values of 'work', 'home', and 'other'.", required: false, caseExact: false, mutability: "readWrite", returned: "default", uniqueness: "server"},
              {name: "primary", type: "boolean", multiValued: false, description: "A Boolean value indicating the 'primary' or preferred attribute value for this attribute, e.g., the preferred mailing address or primary email address.  The primary attribute value 'true' MUST appear no more than once.", required: false, mutability: "readWrite", returned: "default"}
            ]
          }
        ],
        meta: {resourceType: "Schema", location: scim_resource_url(base_url, "/scim/v2/Schemas/#{SCIM_USER_SCHEMA_ID}")}
      }
    end

    def scim_user_resource_type(base_url = nil)
      {
        schemas: ["urn:ietf:params:scim:schemas:core:2.0:ResourceType"],
        id: "User",
        name: "User",
        endpoint: "/Users",
        description: "User Account",
        schema: SCIM_USER_SCHEMA_ID,
        meta: {resourceType: "ResourceType", location: scim_resource_url(base_url, "/scim/v2/ResourceTypes/User")}
      }
    end
  end
end
