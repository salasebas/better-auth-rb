# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "../../support/upstream_test_parity"

class BetterAuthAPIKeyUpstreamInventoryTest < Minitest::Test
  include UpstreamPackageInventoryAssertions

  def test_upstream_inventory_contract
    assert_inventory_contract(BetterAuthAPIKeyUpstreamParity::LEDGER)
  end
end
