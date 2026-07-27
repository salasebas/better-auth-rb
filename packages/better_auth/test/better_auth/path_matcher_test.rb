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
end
