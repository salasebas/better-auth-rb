# frozen_string_literal: true

require_relative "../../test_helper"

class BetterAuthPasskeyAuthenticatorMetadataTest < Minitest::Test
  def test_common_authenticator_names_cover_every_upstream_provider_family
    expected = {
      "ea9b8d66-4d01-1d21-3ce4-b6b48cb575d4" => "Google Password Manager",
      "fbfc3007-154e-4ecc-8c0b-6e020557d7bd" => "Apple Passwords",
      "dd4ec289-e01d-41c9-bb89-70fa845d4bf2" => "iCloud Keychain (Managed)",
      "08987058-cadc-4b81-b6e1-30de50dcbe96" => "Windows Hello",
      "9ddd1817-af5a-4672-a2b9-3e3dd95000a9" => "Windows Hello",
      "6028b017-b1d4-4c02-b4b3-afcdafc96bb2" => "Windows Hello",
      "bada5566-a7aa-401f-bd96-45619a55120d" => "1Password",
      "d548826e-79b4-db40-a3d8-11116f7e8349" => "Bitwarden",
      "531126d6-e717-415c-9320-3d9aa6981239" => "Dashlane",
      "b78a0a55-6ef8-d246-a042-ba0f6d55050c" => "LastPass",
      "b84e4048-15dc-4dd0-8640-f4f60813c8af" => "NordPass",
      "50726f74-6f6e-5061-7373-50726f746f6e" => "Proton Pass",
      "0ea242b4-43c4-4a1b-8b17-dd6d0b6baec6" => "Keeper",
      "53414d53-554e-4700-0000-000000000000" => "Samsung Pass"
    }

    assert_equal expected, BetterAuth::Passkey::COMMON_AUTHENTICATOR_NAMES
    expected.each do |aaguid, name|
      assert_equal name, BetterAuth::Passkey.get_authenticator_name(aaguid)
    end
  end

  def test_authenticator_name_normalizes_case_and_whitespace
    assert_equal "Google Password Manager", BetterAuth::Passkey.get_authenticator_name("  EA9B8D66-4D01-1D21-3CE4-B6B48CB575D4  ")
  end

  def test_authenticator_name_rejects_zero_unknown_missing_and_inherited_like_values
    assert_nil BetterAuth::Passkey.get_authenticator_name("00000000-0000-0000-0000-000000000000")
    assert_nil BetterAuth::Passkey.get_authenticator_name("unknown")
    assert_nil BetterAuth::Passkey.get_authenticator_name(123)
    assert_nil BetterAuth::Passkey.get_authenticator_name(nil)
    assert_nil BetterAuth::Passkey.get_authenticator_name("to_s")
    assert_nil BetterAuth::Passkey.get_authenticator_name("__proto__")
  end

  def test_custom_names_extend_without_mutating_common_map
    before = BetterAuth::Passkey::COMMON_AUTHENTICATOR_NAMES.dup
    custom = {" CUSTOM-AAGUID " => "Custom Key"}

    assert_equal "Custom Key", BetterAuth::Passkey.get_authenticator_name("custom-aaguid", names: custom)
    assert_equal "Apple Passwords", BetterAuth::Passkey.get_authenticator_name("fbfc3007-154e-4ecc-8c0b-6e020557d7bd", names: custom)
    assert_equal before, BetterAuth::Passkey::COMMON_AUTHENTICATOR_NAMES
    assert_nil BetterAuth::Passkey.get_authenticator_name("bad", names: {"bad" => 123})
  end
end
