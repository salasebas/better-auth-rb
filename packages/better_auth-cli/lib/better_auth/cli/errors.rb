# frozen_string_literal: true

module BetterAuth
  class CLI
    # Explicit-options contract for config-backed commands (plan 016).
    #
    # Omitting --cwd is always an error. Omitting --config is an error unless
    # --discover-config is passed (implementation in plan 017).
    #
    # | Command         | Required flags                              | Optional flags                          |
    # |-----------------|---------------------------------------------|-----------------------------------------|
    # | generate        | --cwd, --config, --dialect, --output        | --discover-config                       |
    # | migrate         | --cwd, --config, --yes                       | --discover-config                       |
    # | migrate status  | --cwd, --config                             | --discover-config                       |
    # | doctor          | --cwd, --config                             | --json, --discover-config               |
    # | info            | --cwd                                       | --config, --json, --discover-config     |
    # | mongo indexes   | --cwd, --config                             | --discover-config                       |
    # | secret          | none                                        | --raw                                   |
    # | init (plan 017) | --cwd, (--framework XOR --detect-framework) | --force, --secret, --base-url, ...      |
    module Errors
      module_function

      def missing_option(command, flag, hint_lines = [])
        lines = ["#{command} requires #{flag}."]
        lines.concat(hint_lines)
        lines.join("\n")
      end
    end
  end
end
