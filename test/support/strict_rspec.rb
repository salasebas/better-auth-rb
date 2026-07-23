# frozen_string_literal: true

RSpec.configure do |config|
  config.after(:suite) do
    pending_examples = RSpec.world.all_examples.select do |example|
      example.execution_result.status == :pending
    end
    next if pending_examples.empty?

    descriptions = pending_examples.map(&:full_description).join("\n  ")
    raise "Pending or skipped RSpec examples are forbidden:\n  #{descriptions}"
  end
end
