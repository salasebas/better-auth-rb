# frozen_string_literal: true

module BetterAuth
  module Plugins
    module_function

    def count_members_with_role(ctx, organization_id, role)
      count = 0
      organization_each_adapter_record(ctx.context.adapter, "member", where: [{field: "organizationId", value: organization_id}]) do |member|
        count += 1 if normalized_role_names(member["role"]).include?(role)
      end
      count
    end

    def require_member!(ctx, user_id, organization_id)
      member = require_member(ctx, user_id, organization_id)
      raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("USER_IS_NOT_A_MEMBER_OF_THE_ORGANIZATION")) unless member

      member
    end

    def require_member(ctx, user_id, organization_id)
      return nil if user_id.to_s.empty? || organization_id.to_s.empty?

      ctx.context.adapter.find_one(model: "member", where: [{field: "userId", value: user_id}, {field: "organizationId", value: organization_id}])
    end

    def require_team_member!(ctx, user_id, team_id)
      member = ctx.context.adapter.find_one(model: "teamMember", where: [{field: "userId", value: user_id}, {field: "teamId", value: team_id}])
      raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("USER_IS_NOT_A_MEMBER_OF_THE_TEAM")) unless member

      member
    end

    def member_by_id(ctx, id)
      return nil if id.to_s.empty?

      ctx.context.adapter.find_one(model: "member", where: [{field: "id", value: id}])
    end

    def find_member_by_email(ctx, organization_id, email)
      user = ctx.context.adapter.find_one(model: "user", where: [{field: "email", value: email.to_s.downcase}])
      user && require_member(ctx, user["id"], organization_id)
    end

    def organization_by_id(ctx, id)
      return nil if id.to_s.empty?

      ctx.context.adapter.find_one(model: "organization", where: [{field: "id", value: id}])
    end

    def organization_by_slug(ctx, slug)
      return nil if slug.to_s.empty?

      ctx.context.adapter.find_one(model: "organization", where: [{field: "slug", value: slug}])
    end

    def invitation_by_id(ctx, id)
      return nil if id.to_s.empty?

      ctx.context.adapter.find_one(model: "invitation", where: [{field: "id", value: id}])
    end

    def team_by_id(ctx, id)
      return nil if id.to_s.empty?

      ctx.context.adapter.find_one(model: "team", where: [{field: "id", value: id}])
    end

    def organization_role_by_id(ctx, id)
      return nil if id.to_s.empty?

      ctx.context.adapter.find_one(model: "organizationRole", where: [{field: "id", value: id}])
    end

    def organization_role_by_name(ctx, organization_id, role)
      return nil if role.to_s.empty?

      ctx.context.adapter.find_one(model: "organizationRole", where: [{field: "organizationId", value: organization_id}, {field: "role", value: role}])
    end

    def list_members_for(ctx, organization_id, query = {}, config = nil, user = nil)
      where = [{field: "organizationId", value: organization_id}]
      if query[:filter_field]
        where << {field: query[:filter_field], value: query[:filter_value], operator: query[:filter_operator]}
      elsif query[:filter].is_a?(Hash)
        filter = normalize_hash(query[:filter])
        where << {field: filter[:field], value: filter[:value], operator: filter[:operator]}
      end
      limit = member_list_limit(ctx, organization_id, query, config, user)
      members = ctx.context.adapter.find_many(
        model: "member",
        where: where,
        limit: limit,
        offset: query[:offset],
        sort_by: query[:sort_by] ? {field: query[:sort_by], direction: query[:sort_direction] || query[:sort_order] || "asc"} : nil
      )
      users_by_id = member_users_by_id(ctx, members)
      {
        members: members.map { |entry| member_wire(ctx, entry, users_by_id: users_by_id) },
        total: ctx.context.adapter.count(model: "member", where: where)
      }
    end

    def member_list_limit(ctx, organization_id, query, config, user)
      configured = config && config[:membership_limit]
      configured = 100 if configured.nil?
      default = numeric_member_limit(configured)
      default = 100 unless default.positive?
      requested = query[:limit].to_i if query.key?(:limit) && !query[:limit].to_s.empty?
      return default unless requested&.positive?

      [requested, default].min
    end

    def ensure_organization_member_capacity!(ctx, config, user, organization, adapter: ctx.context.adapter)
      limit = organization_membership_capacity_limit(ctx, config, user, organization)
      count = adapter.count(model: "member", where: [{field: "organizationId", value: organization["id"]}])
      return if count < limit

      raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("ORGANIZATION_MEMBERSHIP_LIMIT_REACHED"))
    end

    def organization_membership_capacity_limit(ctx, config, user, organization)
      configured = config[:membership_limit] || 100
      value = configured.respond_to?(:call) ? configured.call(user, organization_wire(ctx, organization)) : configured
      numeric_member_limit(value)
    end

    def numeric_member_limit(value)
      return value.to_i if value.is_a?(Numeric)
      return value.to_i if value.to_s.match?(/\A-?\d+\z/)

      100
    end

    def member_users_by_id(ctx, members)
      user_ids = members.map { |member| member["userId"] }.compact.uniq
      return {} if user_ids.empty?

      ctx.context.adapter.find_many(model: "user", where: [{field: "id", operator: "in", value: user_ids}]).each_with_object({}) do |user, result|
        result[user["id"]] = user
      end
    end

    def ensure_team_member_capacity!(ctx, config, team_ids, adapter: ctx.context.adapter, lock: false)
      max_members = config.dig(:teams, :maximum_members_per_team)
      return unless max_members && team_ids.any?

      team_ids.each do |team_id|
        team = adapter.find_one(model: "team", where: [{field: "id", value: team_id}])
        lock_team_capacity!(adapter, team) if lock && team
        count = adapter.count(model: "teamMember", where: [{field: "teamId", value: team_id}])
        if count >= max_members.to_i
          raise APIError.new("FORBIDDEN", message: ORGANIZATION_ERROR_CODES.fetch("TEAM_MEMBER_LIMIT_REACHED"))
        end
      end
    end

    def member_wire(ctx, member, users_by_id: nil)
      data = Schema.parse_output(ctx.context.options, "member", member)
      user = users_by_id ? users_by_id[member["userId"]] : ctx.context.internal_adapter.find_user_by_id(member["userId"])
      data["user"] = user.slice("id", "name", "email", "image") if user
      data
    end

    def organization_wire(ctx, organization)
      data = Schema.parse_output(ctx.context.options, "organization", organization)
      data["metadata"] = parse_metadata(data["metadata"]) if data&.key?("metadata")
      data
    end

    def invitation_wire(ctx, invitation)
      Schema.parse_output(ctx.context.options, "invitation", invitation)
    end

    def team_wire(ctx, team)
      Schema.parse_output(ctx.context.options, "team", team)
    end

    def team_member_wire(ctx, member)
      Schema.parse_output(ctx.context.options, "teamMember", member)
    end

    def organization_role_wire(role)
      role.merge("permission" => parse_permission(role["permission"]))
    end

    def clear_active_organization_session(ctx, session, organization_id)
      return unless session[:session]["activeOrganizationId"] == organization_id

      update = {activeOrganizationId: nil, activeTeamId: nil}
      updated_session = ctx.context.internal_adapter.update_session(session[:session]["token"], update)
      Cookies.set_session_cookie(ctx, {session: updated_session || session[:session].merge("activeOrganizationId" => nil, "activeTeamId" => nil), user: session[:user]})
    end

    def organization_created_count(ctx, user_id)
      count = 0
      organization_each_adapter_record(ctx.context.adapter, "member", where: [{field: "userId", value: user_id}]) do |member|
        count += 1 if member["role"].to_s.split(",").include?("owner")
      end
      count
    end

    def organization_each_adapter_record(adapter, model, where:, page_size: 100)
      offset = 0
      loop do
        records = adapter.find_many(model: model, where: where, limit: page_size, offset: offset)
        break if records.empty?

        records.each { |record| yield record }
        break if records.length < page_size

        offset += records.length
      end
    end

    def parse_metadata(value)
      return value if value.nil? || value.is_a?(Hash)

      JSON.parse(value)
    rescue JSON::ParserError
      value
    end

    def serialize_metadata(value)
      value.is_a?(Hash) ? JSON.generate(value) : value
    end

    def organization_transaction(ctx)
      adapter = ctx.context.adapter
      if adapter.method(:transaction).owner == BetterAuth::Adapters::Base
        raise BetterAuth::Error, "Organization mutations require an adapter with real transaction support"
      end

      adapter.transaction { |transaction_adapter| yield(transaction_adapter || adapter) }
    end

    def lock_organization_capacity!(adapter, organization)
      adapter.update(model: "organization", where: [{field: "id", value: organization["id"]}], update: {name: organization["name"]})
    end

    def lock_team_capacity!(adapter, team)
      adapter.update(model: "team", where: [{field: "id", value: team["id"]}], update: {name: team["name"]})
    end
  end
end
