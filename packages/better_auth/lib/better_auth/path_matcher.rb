# frozen_string_literal: true

module BetterAuth
  module PathMatcher
    module_function

    def middleware_pattern_matches?(pattern, path)
      return false unless pattern.is_a?(String) && path.is_a?(String)

      pattern_segments = path_segments(pattern)
      path_segments = path_segments(path)
      path_index = 0

      pattern_segments.each_with_index do |segment, pattern_index|
        terminal = pattern_index == pattern_segments.length - 1

        if terminal && segment == "**"
          return true
        elsif segment == "*"
          return path_segments.length - path_index <= 1 if terminal
          return false unless path_segments[path_index]

          path_index += 1
        else
          return false unless segment == path_segments[path_index]

          path_index += 1
        end
      end

      path_index == path_segments.length
    end

    def literal_subtree_matches?(prefix, path)
      return false unless prefix.is_a?(String) && path.is_a?(String)

      prefix_segments = path_segments(prefix)
      path_segments = path_segments(path)
      return false if prefix_segments.length > path_segments.length

      prefix_segments.each_with_index.all? do |segment, index|
        segment == path_segments[index]
      end
    end

    def path_segments(path)
      normalized = path.sub(%r{/+\z}, "")
      normalized.empty? ? [""] : normalized.split("/", -1)
    end
    private_class_method :path_segments
  end
end
