# frozen_string_literal: true

require_relative "../test_helper"

class BetterAuthPathMatcherTest < Minitest::Test
  MIDDLEWARE_PATTERN_CASES = [
    ["/foo", "/foo", true],
    ["/foo", "/foo/", true],
    ["/foo/", "/foo", true],
    ["/foo/", "/foo/", true],
    ["/foo", "/foo/child", false],
    ["/foo", "/foobar", false],
    ["/foo", "/foo-bar", false],
    ["/foo", "/", false],
    ["/foo/*", "/foo", true],
    ["/foo/*", "/foo/", true],
    ["/foo/*", "/foo/child", true],
    ["/foo/*", "/foo/child/", true],
    ["/foo/*", "/foo/child/grandchild", false],
    ["/foo/*", "/foobar", false],
    ["/foo/*", "/foobar/child", false],
    ["/foo/*", "/foo-bar", false],
    ["/foo/**", "/foo", true],
    ["/foo/**", "/foo/", true],
    ["/foo/**", "/foo/child", true],
    ["/foo/**", "/foo/child/grandchild", true],
    ["/foo/**", "/foobar", false],
    ["/foo/**", "/foobar/child", false],
    ["/foo/**", "/foo-bar", false],
    ["/**", "/", true],
    ["/**", "/foo", true],
    ["/**", "/foo/child", true]
  ].freeze

  ORIGIN_SUBTREE_CASES = [
    ["/foo", "/foo", true],
    ["/foo", "/foo/", true],
    ["/foo/", "/foo", true],
    ["/foo/", "/foo/child", true],
    ["/foo", "/foo/child/grandchild", true],
    ["/foo", "/foobar", false],
    ["/foo", "/foobar/child", false],
    ["/foo", "/foo-bar", false],
    ["/foo", "/", false],
    ["/foo/**", "/foo", false],
    ["/foo/**", "/foo/child", false],
    ["/foo/**", "/foo/**", true],
    ["/foo/**", "/foo/**/child", true]
  ].freeze

  MIDDLEWARE_PARAM_CASES = [
    ["/tenant/:tenant_id/callback", "/tenant/acme/callback", {tenant_id: "acme"}],
    ["/files/**:rest", "/files", {rest: ""}],
    ["/files/**:rest", "/files/a/b", {rest: "a/b"}],
    ["/assets/:name.:extension", "/assets/avatar.png", {name: "avatar", extension: "png"}],
    ["/foo/*/bar", "/foo/child/bar", {_0: "child"}],
    ["/foo/*", "/foo", {}],
    ["/foo/**/ignored", "/foo/child/grandchild", {_: "child/grandchild"}],
    ["/tenant/:tenant_id/callback", "/tenant/acme/other", nil]
  ].freeze

  def test_middleware_patterns_match_path_segments
    MIDDLEWARE_PATTERN_CASES.each do |pattern, path, expected|
      assert_equal expected,
        BetterAuth::PathMatcher.middleware_pattern_matches?(pattern, path),
        "expected #{pattern.inspect} #{expected ? "to match" : "not to match"} #{path.inspect}"
    end
  end

  def test_origin_prefixes_match_literal_subtrees
    ORIGIN_SUBTREE_CASES.each do |prefix, path, expected|
      assert_equal expected,
        BetterAuth::PathMatcher.literal_subtree_matches?(prefix, path),
        "expected #{prefix.inspect} #{expected ? "to cover" : "not to cover"} #{path.inspect}"
    end
  end

  def test_middleware_patterns_return_better_call_route_params
    MIDDLEWARE_PARAM_CASES.each do |pattern, path, expected|
      actual = BetterAuth::PathMatcher.middleware_pattern_match(pattern, path)
      message = "expected #{pattern.inspect} to capture #{expected.inspect} from #{path.inspect}"
      expected.nil? ? assert_nil(actual, message) : assert_equal(expected, actual, message)
    end
  end
end
