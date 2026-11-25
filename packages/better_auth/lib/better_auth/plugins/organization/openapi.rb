# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def organization_openapi(operation_id, description, response:, response_description: "Success", request: nil, required: [], parameters: nil)
      request ||= organization_request_schema(operation_id)
      openapi = {
        operationId: operation_id,
        description: description,
        responses: {
          "200" => OpenAPI.json_response(response_description, response)
        }
      }
      openapi[:requestBody] = OpenAPI.json_request_body(OpenAPI.object_schema(request, required: required)) if request
      openapi[:parameters] = parameters if parameters

      {openapi: openapi}
    end

    def organization_request_schema(operation_id)
      string = {type: "string"}
      boolean = {type: "boolean"}
      array = ->(items = string) { {type: "array", items: items} }
      object = {type: "object", additionalProperties: true}
      {
        "createOrganization" => {
          name: string,
          slug: string,
          logo: string,
          metadata: object,
          userId: string,
          keepCurrentActiveOrganization: boolean
        },
        "checkOrganizationSlug" => {slug: string},
        "updateOrganization" => {
          organizationId: string,
          organizationSlug: string,
          data: object,
          name: string,
          slug: string,
          logo: string,
          metadata: object
        },
        "deleteOrganization" => {organizationId: string, organizationSlug: string},
        "setActiveOrganization" => {organizationId: string, organizationSlug: string},
        "createOrganizationInvitation" => {
          organizationId: string,
          organizationSlug: string,
          email: {type: "string", format: "email"},
          role: {oneOf: [string, array.call]},
          teamId: string,
          teamIds: array.call
        },
        "acceptOrganizationInvitation" => {invitationId: string, id: string},
        "rejectOrganizationInvitation" => {invitationId: string},
        "cancelOrganizationInvitation" => {invitationId: string},
        "addOrganizationMember" => {organizationId: string, userId: string, role: {oneOf: [string, array.call]}},
        "removeOrganizationMember" => {memberId: string, userId: string, organizationId: string},
        "updateOrganizationMemberRole" => {memberId: string, userId: string, organizationId: string, role: {oneOf: [string, array.call]}},
        "leaveOrganization" => {organizationId: string},
        "hasOrganizationPermission" => {organizationId: string, permission: object, permissions: object},
        "createOrganizationTeam" => {organizationId: string, name: string},
        "updateOrganizationTeam" => {teamId: string, name: string},
        "removeOrganizationTeam" => {teamId: string},
        "setActiveOrganizationTeam" => {teamId: string},
        "addTeamMember" => {teamId: string, userId: string},
        "removeTeamMember" => {teamId: string, userId: string},
        "createOrganizationRole" => {organizationId: string, role: string, roleName: string, permission: object, permissions: object},
        "updateOrganizationRole" => {organizationId: string, roleId: string, role: string, roleName: string, permission: object, permissions: object, data: object},
        "deleteOrganizationRole" => {organizationId: string, roleId: string, role: string, roleName: string}
      }[operation_id]
    end

    def organization_ref_schema(name)
      {
        type: "object",
        "$ref": "#/components/schemas/#{name}"
      }
    end

    def organization_nullable_schema(name)
      {
        type: ["object", "null"],
        "$ref": "#/components/schemas/#{name}"
      }
    end

    def organization_array_schema(name)
      {
        type: "array",
        items: organization_ref_schema(name)
      }
    end

    def organization_accept_invitation_schema
      OpenAPI.object_schema(
        {
          invitation: organization_ref_schema("Invitation"),
          member: organization_ref_schema("Member")
        },
        required: ["invitation", "member"]
      )
    end

    def organization_active_member_role_schema
      OpenAPI.object_schema(
        {
          role: {type: "string"},
          member: organization_ref_schema("Member")
        },
        required: ["role", "member"]
      )
    end

    def organization_members_response_schema
      OpenAPI.object_schema(
        {
          members: organization_array_schema("Member"),
          total: {type: "number"}
        },
        required: ["members", "total"]
      )
    end

    def organization_permission_response_schema
      OpenAPI.object_schema(
        {
          error: {type: ["string", "null"]},
          success: {type: "boolean"}
        },
        required: ["success"]
      )
    end

    def organization_role_schema
      OpenAPI.object_schema(
        {
          id: {type: "string"},
          organizationId: {type: "string"},
          role: {type: "string"},
          permission: {type: "object"}
        },
        required: ["role", "permission"]
      )
    end

    def organization_role_action_schema
      OpenAPI.object_schema(
        {
          success: {type: "boolean"},
          roleData: organization_role_schema,
          statements: {type: "object"}
        },
        required: ["success", "roleData"]
      )
    end
  end
end
