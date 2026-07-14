# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    SCIM_BUILT_IN_ACCOUNT_PROVIDER_IDS = %w[
      credential email-otp magic-link phone-number anonymous siwe
    ].freeze

    def scim_has_organization_plugin?(ctx)
      Array(ctx.context.options.plugins).any? { |plugin| plugin.id == "organization" }
    end

    def scim_organization_plugin(ctx)
      Array(ctx.context.options.plugins).find { |plugin| plugin.id == "organization" }
    end

    def scim_required_roles(ctx, config)
      configured = config[:required_role] || config[:required_roles]
      return Array(configured).map(&:to_s) if configured

      creator_role = scim_organization_plugin(ctx)&.options&.fetch(:creator_role, nil)
      ["admin", creator_role || "owner"].uniq
    end

    def scim_provider_ownership_enabled?(config)
      normalize_hash(config[:provider_ownership] || {})[:enabled] == true
    end

    def scim_find_organization_member(ctx, user_id, organization_id)
      ctx.context.adapter.find_one(
        model: "member",
        where: [
          {field: "userId", value: user_id},
          {field: "organizationId", value: organization_id}
        ]
      )
    end

    def scim_parse_roles(role)
      Array(role).flat_map { |entry| entry.to_s.split(",") }.map(&:strip).reject(&:empty?)
    end

    def scim_has_required_role?(role, required_roles)
      required = Array(required_roles).map(&:to_s)
      required.empty? || scim_parse_roles(role).any? { |candidate| required.include?(candidate) }
    end

    def scim_user_org_memberships(ctx, user_id)
      ctx.context.adapter.find_many(model: "member", where: [{field: "userId", value: user_id}]).each_with_object({}) do |member, result|
        result[member.fetch("organizationId")] = member
      end
    end

    def scim_assert_provider_access!(ctx, user_id, provider, required_roles, config = {})
      return unless provider

      organization_id = provider["organizationId"]
      if organization_id
        raise APIError.new("FORBIDDEN", message: "Organization plugin is required to access this SCIM provider") unless scim_has_organization_plugin?(ctx)

        member = scim_find_organization_member(ctx, user_id, organization_id)
        raise APIError.new("FORBIDDEN", message: "You must be a member of the organization to access this provider") unless member
        raise APIError.new("FORBIDDEN", message: "Insufficient role for this operation") unless scim_has_required_role?(member.fetch("role", ""), required_roles)
      elsif scim_provider_ownership_enabled?(config)
        raise APIError.new("FORBIDDEN", message: "You must be the owner to access this provider") unless provider["userId"] == user_id
      elsif provider.key?("userId") && provider["userId"] && provider["userId"] != user_id
        raise APIError.new("FORBIDDEN", message: "You must be the owner to access this provider")
      end
    end

    def scim_provider_by_provider_id!(ctx, provider_id)
      raise APIError.new("BAD_REQUEST", message: BASE_ERROR_CODES["VALIDATION_ERROR"]) unless provider_id.is_a?(String)

      provider = ctx.context.adapter.find_one(model: "scimProvider", where: [{field: "providerId", value: provider_id.to_s}])
      raise APIError.new("NOT_FOUND", message: "SCIM provider not found") unless provider

      provider
    end

    def scim_provider_id_query(ctx)
      ctx.query[:providerId] || ctx.query[:provider_id] || ctx.query["providerId"] || ctx.query["provider_id"]
    end

    def scim_normalized_provider(provider)
      {
        id: provider.fetch("id"),
        providerId: provider.fetch("providerId"),
        organizationId: provider["organizationId"]
      }
    end

    def scim_call_token_hook(callback, payload)
      callback.call(payload) if callback.respond_to?(:call)
    end

    def scim_can_link_existing_user?(ctx, config, user, email, provider)
      policy = config[:link_existing_users]
      return false unless policy
      return true if policy == true
      return false unless policy.is_a?(Hash)

      policy = normalize_hash(policy)
      trusted_domains = Array(policy[:trusted_domains]).map { |domain| domain.to_s.downcase }
      requires_membership = policy[:require_existing_org_membership] == true
      callback = policy[:should_link_user]
      return false if trusted_domains.empty? && !requires_membership && !callback.respond_to?(:call)

      organization_id = provider["organizationId"]
      if requires_membership
        return false unless organization_id
        return false unless scim_find_organization_member(ctx, user.fetch("id"), organization_id)
      end

      domain = email.to_s.split("@", 2)[1]&.downcase
      return false if trusted_domains.any? && (!domain || !trusted_domains.include?(domain))

      return false if callback.respond_to?(:call) && !callback.call(
        user: user,
        email: email,
        provider: {provider_id: provider.fetch("providerId"), organization_id: organization_id}.compact
      )

      true
    end

    def scim_assert_can_generate_token!(config, user:, provider_id:, organization_id:, member:)
      callback = config[:can_generate_token]
      return unless callback.respond_to?(:call)
      return if callback.call(user: user, provider_id: provider_id, organization_id: organization_id, member: member)

      raise APIError.new("FORBIDDEN", message: "You are not allowed to generate a SCIM token")
    end

    def scim_assert_provider_id_available!(ctx, provider_id)
      reserved = SCIM_BUILT_IN_ACCOUNT_PROVIDER_IDS.dup
      reserved.concat(ctx.context.options.configured_social_provider_ids)
      ctx.context.social_providers.each do |id, provider|
        reserved << id.to_s
        declared_id = fetch_value(provider, :id)
        reserved << declared_id.to_s if declared_id
      end

      sso_plugin = Array(ctx.context.options.plugins).find { |plugin| plugin.id == "sso" }
      if sso_plugin
        sso_options = normalize_hash(sso_plugin.options || {})
        defaults = sso_options[:default_sso]
        defaults = [defaults] if defaults.is_a?(Hash)
        Array(defaults).each do |provider|
          provider = normalize_hash(provider)
          reserved << provider[:provider_id].to_s if provider[:provider_id]
        end
        collision = ctx.context.adapter.find_one(model: "ssoProvider", where: [{field: "providerId", value: provider_id}])
        reserved << provider_id if collision
      end

      return unless reserved.include?(provider_id)

      raise APIError.new("BAD_REQUEST", message: "Provider id collides with another account provider and cannot be used for SCIM")
    end

    def scim_create_org_membership(ctx, user_id, organization_id)
      return unless organization_id
      return if ctx.context.adapter.find_one(model: "member", where: [{field: "organizationId", value: organization_id}, {field: "userId", value: user_id}])

      ctx.context.adapter.create(model: "member", data: {userId: user_id, organizationId: organization_id, role: "member", createdAt: Time.now})
    end

    def scim_admin_plugin?(ctx)
      Array(ctx.context.options.plugins).any? { |plugin| plugin.id == "admin" }
    end

    def scim_assert_active_supported!(ctx, active)
      return unless active == false
      return if scim_admin_plugin?(ctx)

      raise scim_error("BAD_REQUEST", "SCIM deactivation requires the admin plugin")
    end

    def scim_active_update(ctx, active)
      return {} unless [true, false].include?(active)
      return {} unless scim_admin_plugin?(ctx)

      if active
        {banned: false, banReason: nil, banExpires: nil}
      else
        {banned: true, banReason: "Deactivated by SCIM", banExpires: nil}
      end
    end

    def scim_assert_email_available!(ctx, user, email)
      existing = ctx.context.internal_adapter.find_user_by_email(email)&.fetch(:user)
      return unless existing && existing.fetch("id") != user.fetch("id")

      raise scim_error("CONFLICT", "A user with this email already exists", scim_type: "uniqueness")
    end
  end
end
