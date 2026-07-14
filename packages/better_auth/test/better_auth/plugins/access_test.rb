# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthPluginsAccessTest < Minitest::Test
  def setup
    statements = {
      project: ["create", "update", "delete", "delete-many"],
      ui: ["view", "edit", "comment", "hide"]
    }
    @ac = BetterAuth::Plugins.create_access_control(statements)
    @role = @ac.new_role(
      project: ["create", "update", "delete"],
      ui: ["view", "edit", "comment"]
    )
  end

  def test_allows_passing_defined_statements_directly_into_new_role
    role = @ac.new_role(@ac.statements)

    response = role.authorize(project: ["create"])

    assert_equal true, response.fetch(:success)
  end

  def test_validates_permissions
    assert_equal true, @role.authorize(project: ["create"]).fetch(:success)

    failed = @role.authorize(project: ["delete-many"])

    assert_equal false, failed.fetch(:success)
  end

  def test_validates_multiple_resource_permissions
    assert_equal true, @role.authorize(project: ["create"], ui: ["view"]).fetch(:success)

    failed = @role.authorize(project: ["delete-many"], ui: ["view"])

    assert_equal false, failed.fetch(:success)
  end

  def test_validates_multiple_actions_per_resource
    assert_equal true, @role.authorize(project: ["create", "delete"], ui: ["view", "edit"]).fetch(:success)

    failed = @role.authorize(project: ["create", "delete-many"], ui: ["view", "edit"])

    assert_equal false, failed.fetch(:success)
  end

  def test_validates_using_or_connector
    response = @role.authorize({project: ["create", "delete-many"], ui: ["view", "edit"]}, "OR")

    assert_equal true, response.fetch(:success)
  end

  def test_validates_using_or_connector_for_a_specific_resource
    response = @role.authorize(
      {
        project: {connector: "OR", actions: ["create", "delete-many"]},
        ui: ["view", "edit"]
      }
    )

    assert_equal true, response.fetch(:success)

    failed = @role.authorize(
      {
        project: {connector: "OR", actions: ["create", "delete-many"]},
        ui: ["view", "edit", "hide"]
      }
    )

    assert_equal false, failed.fetch(:success)
  end

  def test_rejects_unknown_resources
    failed = @role.authorize(billing: ["read"])

    assert_equal false, failed.fetch(:success)
    assert_match(/billing/, failed.fetch(:error))
  end

  def test_empty_actions_are_not_authorized_and_or_continues_after_unknown_resources
    refute @role.authorize(project: []).fetch(:success)

    response = @role.authorize({billing: ["read"], project: ["create"]}, "OR")
    assert_equal true, response.fetch(:success)
  end

  def test_rejects_malformed_resource_requests
    assert_raises(BetterAuth::Error) do
      @role.authorize(project: "create")
    end

    [{}, {connector: "AND"}, {actions: nil}, {actions: "create"}, {actions: []}, {actions: [123]}].each do |request|
      refute @role.authorize(project: request).fetch(:success)
    end

    refute @role.authorize(project: {connector: "unexpected", actions: ["create", "delete-many"]}).fetch(:success)
  end

  def test_unknown_connectors_default_to_and
    response = @role.authorize({project: {connector: "or", actions: ["create", "delete-many"]}}, "and")

    assert_equal false, response.fetch(:success)
  end

  def test_outer_connector_only_accepts_exact_or
    ["or", :OR, nil, "XOR"].each do |connector|
      refute @role.authorize({project: ["delete-many"], ui: ["view"]}, connector).fetch(:success)
      refute @role.authorize({billing: ["read"], project: ["create"]}, connector).fetch(:success)
    end
  end

  def test_create_access_control_has_camel_case_alias
    ac = BetterAuth::Plugins.createAccessControl(project: ["read"])

    assert_equal true, ac.newRole(project: ["read"]).authorize(project: ["read"]).fetch(:success)
  end
end
