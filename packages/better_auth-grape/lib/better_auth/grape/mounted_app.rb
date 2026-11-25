# frozen_string_literal: true

module BetterAuth
  module Grape
    class MountedApp
      def initialize(auth, mount_path:)
        @auth = auth
        @mount_path = normalize_path(mount_path)
      end

      def call(env)
        rewritten_path = mounted_path_info(env)
        next_env = env.merge("PATH_INFO" => rewritten_path)
        next_env["SCRIPT_NAME"] = "" if shared_mount_rewrite?(env, rewritten_path)
        @auth.call(next_env)
      end

      private

      def mounted_path_info(env)
        path_info = normalize_path(env["PATH_INFO"], trim: false)
        comparable_path = normalize_path(env["PATH_INFO"], trim: true)
        return path_info if comparable_path == @mount_path || comparable_path.start_with?("#{@mount_path}/")

        script_name = normalize_path(env["SCRIPT_NAME"], trim: true)
        return normalize_path("#{@mount_path}/#{path_info.delete_prefix("/")}", trim: false) if script_mount_matches?(script_name)

        prefix = (script_name == "/") ? @mount_path : script_name
        return path_info if comparable_path == prefix || comparable_path.start_with?("#{prefix}/")

        normalize_path("#{prefix}/#{path_info.delete_prefix("/")}", trim: false)
      end

      def script_mount_matches?(script_name)
        script_name == @mount_path || script_name.end_with?(@mount_path.to_s)
      end

      def shared_mount_rewrite?(env, rewritten_path)
        script_name = normalize_path(env["SCRIPT_NAME"], trim: true)
        original_path = normalize_path(env["PATH_INFO"], trim: true)
        script_name != "/" &&
          !original_path.start_with?("#{@mount_path}/") &&
          rewritten_path.start_with?("#{@mount_path}/")
      end

      def normalize_path(path, trim: true)
        normalized = path.to_s
        normalized = "/#{normalized}" unless normalized.start_with?("/")
        normalized = normalized.squeeze("/")
        normalized = normalized.delete_suffix("/") if trim && normalized != "/"
        normalized.empty? ? "/" : normalized
      end
    end
  end
end
