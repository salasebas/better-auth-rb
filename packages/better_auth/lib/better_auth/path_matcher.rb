# frozen_string_literal: true

module BetterAuth
  module PathMatcher
    module_function

    def middleware_pattern_match(pattern, path)
      return unless pattern.is_a?(String) && path.is_a?(String)

      pattern_segments = middleware_path_segments(pattern, pattern: true)
      path_segments = middleware_path_segments(path)
      params = {}
      path_index = 0
      unnamed_param_index = 0
      pattern_index = 0

      while pattern_index < pattern_segments.length
        segment = pattern_segments[pattern_index]
        terminal = pattern_index == pattern_segments.length - 1

        if segment.start_with?("**")
          name = segment.split(":", 2)[1] || "_"
          params[name.to_sym] = path_segments.drop(path_index).join("/")
          return params
        elsif segment == "*"
          return params if terminal && !path_segments[path_index]
          return nil unless path_segments[path_index]

          params[:"_#{unnamed_param_index}"] = path_segments[path_index]
          unnamed_param_index += 1
          path_index += 1
        elsif parameter_segment?(segment)
          return nil unless path_segments[path_index]

          captures = parameter_captures(segment, path_segments[path_index])
          return nil unless captures

          params.merge!(captures)
          path_index += 1
        else
          return nil unless static_segment(segment) == path_segments[path_index]

          path_index += 1
        end

        pattern_index += 1
      end

      params if path_index == path_segments.length
    end

    def middleware_pattern_matches?(pattern, path)
      !middleware_pattern_match(pattern, path).nil?
    end

    def literal_subtree_matches?(prefix, path)
      return false unless prefix.is_a?(String) && path.is_a?(String)

      prefix_segments = literal_path_segments(prefix)
      path_segments = literal_path_segments(path)
      return false if prefix_segments.length > path_segments.length

      prefix_segments.each_with_index.all? do |segment, index|
        segment == path_segments[index]
      end
    end

    def middleware_path_segments(path, pattern: false)
      normalized = path.start_with?("/") ? path : "/#{path}"
      normalized = normalized.sub(%r{/$}, "") unless pattern
      segments = normalized.split("/", -1).drop(1)
      return segments[0...-1] if segments.last == ""

      segments
    end

    def parameter_segment?(segment)
      segment.gsub("\\:", "").include?(":")
    end

    def parameter_captures(pattern_segment, path_segment)
      if pattern_segment.start_with?(":") && !pattern_segment.index(":", 1)
        return {pattern_segment.delete_prefix(":").to_sym => path_segment}
      end

      source = pattern_segment
        .gsub("\\:", "\0")
        .gsub(/:(\w+)/, '(?<\1>[^/]+)')
        .split(".").join("\\.")
        .tr("\0", ":")
      match = Regexp.new("\\A#{source}\\z").match(path_segment)
      return unless match

      match.named_captures.each_with_object({}) do |(name, value), captures|
        captures[name.to_sym] = value
      end
    end

    def static_segment(segment)
      return "*" if segment == "\\*"
      return "**" if segment == "\\*\\*"

      segment.gsub("\\:", ":")
    end

    def literal_path_segments(path)
      normalized = path.sub(%r{/+\z}, "")
      normalized.empty? ? [""] : normalized.split("/", -1)
    end
    private_class_method :middleware_path_segments,
      :parameter_segment?,
      :parameter_captures,
      :static_segment,
      :literal_path_segments
  end
end
