# frozen_string_literal: true

require "open3"
require_relative "../test_helper"

class BetterAuthPluginLoaderTest < Minitest::Test
  BOOT_SCRIPT = <<~'RUBY'
    $LOAD_PATH.unshift ARGV.fetch(0)
    require "better_auth"
    loaded = {
      oidc_provider: BetterAuth::Plugins.plugin_loaded?(:oidc_provider),
      oauth_protocol: BetterAuth::Plugins.plugin_loaded?(:oauth_protocol),
      oidc_provider_constant: BetterAuth::Plugins.const_defined?(:OIDCProvider, false),
      bearer: BetterAuth::Plugins.plugin_loaded?(:bearer),
      open_api: BetterAuth::Plugins.plugin_loaded?(:open_api),
      i18n: BetterAuth::Plugins.plugin_loaded?(:i18n)
    }
    puts loaded.map { |key, value| "#{key}=#{value}" }.join("\n")
  RUBY

  def test_core_boot_loads_open_api_but_not_other_plugins
    output = run_isolated_boot_script
    assert_equal "false", output.fetch(:oidc_provider)
    assert_equal "false", output.fetch(:oauth_protocol)
    assert_equal "false", output.fetch(:oidc_provider_constant)
    assert_equal "false", output.fetch(:bearer)
    assert_equal "true", output.fetch(:open_api)
    assert_equal "false", output.fetch(:i18n)
  end

  def test_i18n_loads_only_when_factory_is_called
    output = run_isolated_script(<<~RUBY)
      require "better_auth"
      raise "i18n should not be loaded at boot" if BetterAuth::Plugins.plugin_loaded?(:i18n)
      plugin = BetterAuth::Plugins.i18n(translations: {"en" => {"INVALID_EMAIL_OR_PASSWORD" => "Invalid"}})
      raise "i18n should be loaded" unless BetterAuth::Plugins.plugin_loaded?(:i18n)
      raise "expected plugin instance" unless plugin.is_a?(BetterAuth::Plugin)
      puts "ok"
    RUBY
    assert_equal "ok\n", output
  end

  def test_oidc_provider_loads_only_when_factory_is_called
    output = run_isolated_script(<<~RUBY)
      require "better_auth"
      raise "oidc_provider should not be loaded at boot" if BetterAuth::Plugins.plugin_loaded?(:oidc_provider)
      BetterAuth::Plugins.oidc_provider(__skip_deprecation_warning: true)
      raise "oidc_provider should be loaded" unless BetterAuth::Plugins.plugin_loaded?(:oidc_provider)
      raise "oauth_protocol should be loaded" unless BetterAuth::Plugins.plugin_loaded?(:oauth_protocol)
      raise "OIDCProvider should be defined" unless BetterAuth::Plugins.const_defined?(:OIDCProvider, false)
      puts "ok"
    RUBY
    assert_equal "ok\n", output
  end

  def test_plugin_factory_method_missing_loads_plugin_file
    output = run_isolated_script(<<~RUBY)
      require "better_auth"
      raise "bearer should not be loaded at boot" if BetterAuth::Plugins.plugin_loaded?(:bearer)
      plugin = BetterAuth::Plugins.bearer
      raise "bearer should be loaded" unless BetterAuth::Plugins.plugin_loaded?(:bearer)
      raise "expected plugin instance" unless plugin.is_a?(BetterAuth::Plugin)
      puts "ok"
    RUBY
    assert_equal "ok\n", output
  end

  private

  def run_isolated_boot_script
    lib_path = File.expand_path("../../lib", __dir__)
    stdout, status = Open3.capture2(RbConfig.ruby, "-e", BOOT_SCRIPT, lib_path)
    assert status.success?, stdout
    parse_output(stdout)
  end

  def run_isolated_script(script)
    lib_path = File.expand_path("../../lib", __dir__)
    full_script = <<~RUBY
      $LOAD_PATH.unshift #{lib_path.inspect}
      #{script}
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-e", full_script)
    assert status.success?, [stdout, stderr].join
    stdout
  end

  def parse_output(stdout)
    stdout.each_line.to_h do |line|
      key, value = line.strip.split("=", 2)
      [key.to_sym, value]
    end
  end
end
