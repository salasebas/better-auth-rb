# frozen_string_literal: true

module StrictMinitestSkipFailure
  def skip(message = nil, *)
    flunk("Skipped test: #{message || "no reason provided"}")
  end
end

module StrictMinitestLoader
  def require(feature)
    loaded = super
    StrictMinitestLoader.install!
    loaded
  end
  private :require

  def self.install!
    return unless defined?(Minitest::Test)
    return if Minitest::Test < StrictMinitestSkipFailure

    Minitest::Test.prepend(StrictMinitestSkipFailure)
  end
end

Kernel.prepend(StrictMinitestLoader)
StrictMinitestLoader.install!
