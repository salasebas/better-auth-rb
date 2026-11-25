# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def organization_invite_endpoint(config)
      Endpoint.new(path: "/organization/invite-member", method: "POST", metadata: organization_openapi("createOrganizationInvitation", "Create an organization invitation", response: organization_ref_schema("Invitation"))) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        organization = organization_by_id(ctx, body[:organization_id] || session[:session]["activeOrganizationId"]) || organization_by_slug(ctx, body[:organization_slug])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization
        member = require_org_permission!(ctx, config, session, organization["id"], {invitation: ["create"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_INVITE_USERS_TO_THIS_ORGANIZATION"))
        email = body[:email].to_s.downcase
        raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES.fetch("INVALID_EMAIL")) unless Routes::EMAIL_PATTERN.match?(email)
        role = parse_roles(body[:role] || "member")
        role.split(",").each do |entry|
          unless organization_roles(config).key?(entry) || organization_role_by_name(ctx, organization["id"], entry)
            raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ROLE_NOT_FOUND"))
          end
        end
        creator_role = config[:creator_role]
        unless normalized_role_names(member["role"]).include?(creator_role)
          if normalized_role_names(role).include?(creator_role)
            raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_INVITE_USER_WITH_THIS_ROLE"))
          end
        end
        existing_member = find_member_by_email(ctx, organization["id"], email)
        raise APIError.new("CONFLICT", message: ORGANIZATION_ERROR_CODES.fetch("USER_IS_ALREADY_A_MEMBER_OF_THIS_ORGANIZATION")) if existing_member
        team_ids = organization_team_ids(body[:team_id] || body[:team_ids])
        invitation_outcome = organization_transaction(ctx) do |adapter|
          lock_organization_capacity!(adapter, organization)
          pending = adapter.find_many(model: "invitation", where: [{field: "organizationId", value: organization["id"]}, {field: "email", value: email}, {field: "status", value: "pending"}])

          if pending.any? && org_truthy?(body[:resend])
            existing = pending.first
            expires_at = Time.now + config[:invitation_expires_in].to_i
            updated = adapter.update(model: "invitation", where: [{field: "id", value: existing["id"]}], update: {expiresAt: expires_at})
            next {invitation: updated || existing.merge("expiresAt" => expires_at), reused: true}
          end

          if pending.any?
            if config[:cancel_pending_invitations_on_re_invite]
              adapter.update(model: "invitation", where: [{field: "id", value: pending.first["id"]}], update: {status: "canceled"})
            else
              raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("USER_IS_ALREADY_INVITED_TO_THIS_ORGANIZATION"))
            end
          end
          pending_count = adapter.count(model: "invitation", where: [{field: "organizationId", value: organization["id"]}, {field: "status", value: "pending"}])
          limit = config[:invitation_limit]
          if limit.respond_to?(:call)
            limit = limit.call(
              {
                user: session[:user],
                organization: organization_wire(ctx, organization),
                member: member.merge("user" => session[:user].slice("id", "name", "email", "image"))
              },
              ctx.context
            )
          end
          if limit && pending_count >= limit
            raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("INVITATION_LIMIT_REACHED"))
          end
          validate_invitation_team_ids!(ctx, config, organization["id"], body[:team_id] || body[:team_ids], team_ids)
          validate_stored_invitation_teams!(adapter, organization["id"], team_ids)
          ensure_team_member_capacity!(ctx, config, team_ids, adapter: adapter)

          invitation_data = {
            organizationId: organization["id"],
            email: email,
            role: role,
            status: "pending",
            expiresAt: Time.now + config[:invitation_expires_in].to_i,
            inviterId: session[:user]["id"],
            teamId: team_ids.any? ? team_ids.join(",") : nil,
            createdAt: Time.now
          }.merge(additional_input(body, :organization_id, :organization_slug, :email, :role, :resend, :team_id, :team_ids))
          merge_hook_data!(invitation_data, run_org_hook(config, :before_create_invitation, {invitation: invitation_data, inviter: session[:user], organization: organization_wire(ctx, organization)}, ctx))
          {invitation: adapter.create(model: "invitation", data: invitation_data, force_allow_id: true), reused: false}
        end
        invitation = invitation_outcome.fetch(:invitation)
        sender = config[:send_invitation_email]
        if sender.respond_to?(:call)
          inviter = member.merge("user" => session[:user])
          sender.call({id: invitation["id"], role: invitation["role"], email: invitation["email"].to_s.downcase, organization: organization_wire(ctx, organization), invitation: invitation_wire(ctx, invitation), inviter: inviter}, ctx.request)
        end
        unless invitation_outcome.fetch(:reused)
          run_org_hook(config, :after_create_invitation, {invitation: invitation_wire(ctx, invitation), inviter: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        end
        ctx.json(invitation_wire(ctx, invitation))
      end
    end

    def organization_accept_invitation_endpoint(config)
      Endpoint.new(path: "/organization/accept-invitation", method: "POST", metadata: organization_openapi("acceptOrganizationInvitation", "Accept an organization invitation", response: organization_accept_invitation_schema)) do |ctx|
        session = Routes.current_session(ctx)
        body = normalize_hash(ctx.body)
        invitation = invitation_by_id(ctx, body[:invitation_id] || body[:id])
        require_pending_invitation!(invitation)
        require_invitation_recipient!(invitation, session)
        require_verified_invitation_recipient!(ctx, config, session, "EMAIL_VERIFICATION_REQUIRED_BEFORE_ACCEPTING_OR_REJECTING_INVITATION")
        organization = organization_by_id(ctx, invitation["organizationId"])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization

        run_org_hook(config, :before_accept_invitation, {invitation: invitation_wire(ctx, invitation), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        member = nil
        updated = nil
        organization_transaction(ctx) do |adapter|
          lock_organization_capacity!(adapter, organization)
          accepted = adapter.increment_one(
            model: "invitation",
            where: [{field: "id", value: invitation["id"]}, {field: "status", value: "pending"}],
            increment: {},
            set: {status: "accepted"}
          )
          raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("INVITATION_NOT_FOUND")) unless accepted

          validate_organization_roles!(ctx, config, invitation["organizationId"], normalized_role_names(invitation["role"]), adapter: adapter)
          ensure_organization_member_capacity!(ctx, config, session[:user], organization, adapter: adapter)
          team_ids = organization_team_ids(invitation["teamId"])
          validate_stored_invitation_teams!(adapter, invitation["organizationId"], team_ids)
          ensure_team_member_capacity!(ctx, config, team_ids, adapter: adapter, lock: true)
          if adapter.find_one(model: "member", where: [{field: "userId", value: session[:user]["id"]}, {field: "organizationId", value: invitation["organizationId"]}])
            raise APIError.new("CONFLICT", message: ORGANIZATION_ERROR_CODES.fetch("USER_IS_ALREADY_A_MEMBER_OF_THIS_ORGANIZATION"))
          end
          member = adapter.create(model: "member", data: {organizationId: invitation["organizationId"], userId: session[:user]["id"], role: invitation["role"], createdAt: Time.now})
          team_ids.each do |team_id|
            adapter.create(model: "teamMember", data: {teamId: team_id, userId: session[:user]["id"], createdAt: Time.now})
          end
          updated = accepted
        end
        run_org_hook(config, :after_accept_invitation, {invitation: invitation_wire(ctx, updated), member: member_wire(ctx, member), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        ctx.json({invitation: invitation_wire(ctx, updated), member: member_wire(ctx, member)})
      end
    end

    def organization_reject_invitation_endpoint(config)
      Endpoint.new(path: "/organization/reject-invitation", method: "POST", metadata: organization_openapi("rejectOrganizationInvitation", "Reject an organization invitation", response: organization_ref_schema("Invitation"))) do |ctx|
        session = Routes.current_session(ctx)
        invitation = invitation_by_id(ctx, normalize_hash(ctx.body)[:invitation_id])
        require_pending_invitation!(invitation, check_expiration: false)
        require_invitation_recipient!(invitation, session)
        require_verified_invitation_recipient!(ctx, config, session, "EMAIL_VERIFICATION_REQUIRED_BEFORE_ACCEPTING_OR_REJECTING_INVITATION")
        organization = organization_by_id(ctx, invitation["organizationId"])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization
        run_org_hook(config, :before_reject_invitation, {invitation: invitation_wire(ctx, invitation), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        updated = ctx.context.adapter.update(model: "invitation", where: [{field: "id", value: invitation["id"]}], update: {status: "rejected"})
        run_org_hook(config, :after_reject_invitation, {invitation: invitation_wire(ctx, updated), user: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        ctx.json(invitation_wire(ctx, updated))
      end
    end

    def organization_cancel_invitation_endpoint(config)
      Endpoint.new(path: "/organization/cancel-invitation", method: "POST", metadata: organization_openapi("cancelOrganizationInvitation", "Cancel an organization invitation", response: organization_ref_schema("Invitation"))) do |ctx|
        session = Routes.current_session(ctx)
        invitation = invitation_by_id(ctx, normalize_hash(ctx.body)[:invitation_id])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("INVITATION_NOT_FOUND")) unless invitation
        require_org_permission!(ctx, config, session, invitation["organizationId"], {invitation: ["cancel"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_CANCEL_THIS_INVITATION"))
        organization = organization_by_id(ctx, invitation["organizationId"])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization
        run_org_hook(config, :before_cancel_invitation, {invitation: invitation_wire(ctx, invitation), cancelled_by: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        updated = ctx.context.adapter.update(model: "invitation", where: [{field: "id", value: invitation["id"]}], update: {status: "canceled"})
        run_org_hook(config, :after_cancel_invitation, {invitation: invitation_wire(ctx, updated), cancelled_by: session[:user], organization: organization_wire(ctx, organization)}, ctx)
        ctx.json(invitation_wire(ctx, updated))
      end
    end

    def organization_get_invitation_endpoint(config)
      Endpoint.new(path: "/organization/get-invitation", method: "GET", metadata: organization_openapi("getOrganizationInvitation", "Get an organization invitation", response: organization_ref_schema("Invitation"))) do |ctx|
        session = Routes.current_session(ctx)
        invitation = invitation_by_id(ctx, normalize_hash(ctx.query)[:id] || normalize_hash(ctx.query)[:invitation_id])
        require_pending_invitation!(invitation)
        require_invitation_recipient!(invitation, session)
        require_verified_invitation_recipient!(ctx, config, session, "EMAIL_VERIFICATION_REQUIRED_FOR_INVITATION")
        organization = organization_by_id(ctx, invitation["organizationId"])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_NOT_FOUND")) unless organization
        inviter = require_member(ctx, invitation["inviterId"], invitation["organizationId"])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("INVITER_IS_NO_LONGER_A_MEMBER_OF_THE_ORGANIZATION")) unless inviter
        inviter_user = ctx.context.internal_adapter.find_user_by_id(invitation["inviterId"])
        ctx.json(invitation_wire(ctx, invitation).merge(organizationName: organization["name"], organizationSlug: organization["slug"], inviterEmail: inviter_user && inviter_user["email"]))
      end
    end

    def organization_list_invitations_endpoint(config)
      Endpoint.new(path: "/organization/list-invitations", method: "GET", metadata: organization_openapi("listOrganizationInvitations", "List organization invitations", response: organization_array_schema("Invitation"))) do |ctx|
        session = Routes.current_session(ctx)
        organization_id = normalize_hash(ctx.query)[:organization_id] || session[:session]["activeOrganizationId"]
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("NO_ACTIVE_ORGANIZATION")) unless organization_id
        require_org_permission!(ctx, config, session, organization_id, {invitation: ["create"]}, ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_ALLOWED_TO_INVITE_USERS_TO_THIS_ORGANIZATION"))
        invitations = ctx.context.adapter.find_many(model: "invitation", where: [{field: "organizationId", value: organization_id}])
        ctx.json(invitations.map { |entry| invitation_wire(ctx, entry) })
      end
    end

    def organization_list_user_invitations_endpoint
      Endpoint.new(path: "/organization/list-user-invitations", method: "GET", metadata: organization_openapi("listUserInvitations", "List user invitations", response: organization_array_schema("Invitation"))) do |ctx|
        session = Routes.current_session(ctx)
        unless session[:user]["emailVerified"]
          raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("EMAIL_VERIFICATION_REQUIRED_FOR_INVITATION"))
        end
        invitations = ctx.context.adapter.find_many(model: "invitation", where: [{field: "email", value: session[:user]["email"].to_s.downcase}, {field: "status", value: "pending"}])
        ctx.json(invitations.map { |entry| invitation_wire(ctx, entry) })
      end
    end

    def organization_team_ids(value)
      Array(value).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:empty?)
    end

    def validate_invitation_team_ids!(ctx, config, organization_id, raw_value, team_ids)
      return if raw_value.nil?
      unless org_truthy?(config.dig(:teams, :enabled))
        raise APIError.new("BAD_REQUEST", message: "Teams are not enabled")
      end
      if Array(raw_value).any? { |team_id| team_id.to_s.include?(",") }
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("INVALID_TEAM_ID"))
      end
      team_ids.each do |team_id|
        team = team_by_id(ctx, team_id)
        unless team && team["organizationId"] == organization_id
          raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND"))
        end
      end
    end

    def require_pending_invitation!(invitation, check_expiration: true)
      expired = invitation && invitation["expiresAt"] && organization_time(invitation["expiresAt"]) < Time.now
      valid = invitation && invitation["status"] == "pending"
      valid &&= !expired if check_expiration
      unless valid
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("INVITATION_NOT_FOUND"))
      end
      invitation
    end

    def require_invitation_recipient!(invitation, session)
      return if invitation["email"].to_s.downcase == session[:user]["email"].to_s.downcase

      raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("YOU_ARE_NOT_THE_RECIPIENT_OF_THE_INVITATION"))
    end

    def require_verified_invitation_recipient!(ctx, config, session, error_code)
      return unless require_verified_email_for_invitation_id_action?(ctx, config)
      return if session[:user]["emailVerified"]

      raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch(error_code))
    end

    def require_verified_email_for_invitation_id_action?(ctx, config)
      return org_truthy?(config[:require_email_verification_on_invitation]) if config.key?(:require_email_verification_on_invitation)

      generator = ctx.context.options.advanced.dig(:database, :generate_id)
      !generator.nil? && generator != "uuid"
    end

    def organization_time(value)
      value.is_a?(Time) ? value : Time.parse(value.to_s)
    end

    def validate_stored_invitation_teams!(adapter, organization_id, team_ids)
      team_ids.each do |team_id|
        team = adapter.find_one(model: "team", where: [{field: "id", value: team_id}, {field: "organizationId", value: organization_id}])
        raise APIError.new("BAD_REQUEST", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_NOT_FOUND")) unless team
      end
    end
  end
end
