# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry/logger_adapter"

class LoggerAdapterTest < Minitest::Test
  LoggerAdapter = BetterAuth::Telemetry::LoggerAdapter

  # A minimal logger that records `info` / `error` calls.
  class RecordingLogger
    attr_reader :calls

    def initialize
      @calls = []
    end

    def info(message)
      @calls << [:info, message]
    end

    def error(message)
      @calls << [:error, message]
    end
  end

  # A logger-shaped object that raises on every dispatch.
  class RaisingLogger
    def info(_message)
      raise StandardError, "info exploded"
    end

    def error(_message)
      raise StandardError, "error exploded"
    end
  end

  # An object that has neither `info`/`error` nor `:call`. Dispatches via
  # this logger fall through to `Kernel.warn`.
  class BareObject
  end

  # ---------------------------------------------------------------------
  # Selection rule (per-dispatch)
  # ---------------------------------------------------------------------

  def test_info_dispatches_to_logger_info_when_present
    logger = RecordingLogger.new
    adapter = LoggerAdapter.new(logger)

    assert_nil adapter.info("hello")
    assert_equal [[:info, "hello"]], logger.calls
  end

  def test_error_dispatches_to_logger_error_when_present
    logger = RecordingLogger.new
    adapter = LoggerAdapter.new(logger)

    assert_nil adapter.error("kaboom")
    assert_equal [[:error, "kaboom"]], logger.calls
  end

  def test_callable_logger_receives_level_and_message
    captured = []
    callable = ->(level, message) { captured << [level, message] }
    adapter = LoggerAdapter.new(callable)

    assert_nil adapter.info("info-line")
    assert_nil adapter.error("error-line")

    assert_equal [[:info, "info-line"], [:error, "error-line"]], captured
  end

  def test_bare_object_falls_back_to_kernel_warn
    adapter = LoggerAdapter.new(BareObject.new)

    captured = capture_warn do
      assert_nil adapter.info("warn-info")
      assert_nil adapter.error("warn-error")
    end

    assert_includes captured, "warn-info"
    assert_includes captured, "warn-error"
  end

  # ---------------------------------------------------------------------
  # Rescue behavior — Requirement 21.3
  # ---------------------------------------------------------------------

  def test_logger_that_raises_does_not_propagate
    adapter = LoggerAdapter.new(RaisingLogger.new)

    assert_nil adapter.info("boom")
    assert_nil adapter.error("boom")
  end

  def test_callable_logger_that_raises_does_not_propagate
    adapter = LoggerAdapter.new(->(_level, _message) { raise StandardError, "callable boom" })

    assert_nil adapter.info("x")
    assert_nil adapter.error("x")
  end

  # ---------------------------------------------------------------------
  # `LoggerAdapter.from` factory
  # ---------------------------------------------------------------------

  def test_from_wraps_logger_responding_to_info_and_error
    logger = RecordingLogger.new
    adapter = LoggerAdapter.from(logger)

    adapter.info("ping")
    adapter.error("pong")

    assert_equal [[:info, "ping"], [:error, "pong"]], logger.calls
  end

  def test_from_wraps_callable_when_logger_lacks_levels
    captured = []
    callable = ->(level, message) { captured << [level, message] }
    adapter = LoggerAdapter.from(callable)

    adapter.info("hi")
    adapter.error("bye")

    assert_equal [[:info, "hi"], [:error, "bye"]], captured
  end

  def test_from_falls_back_to_default_better_auth_logger_when_nil
    adapter = LoggerAdapter.from(nil)

    # The default `BetterAuth::Logger.create` is at level :warn with no
    # handler, so info is silenced and error routes to Kernel.warn.
    assert_silent { assert_nil adapter.info("info-via-default") }

    captured = capture_warn { assert_nil adapter.error("error-via-default") }
    assert_includes captured, "error-via-default"
  end

  def test_from_falls_back_to_default_when_logger_responds_to_neither_levels_nor_call
    adapter = LoggerAdapter.from(BareObject.new)

    captured = capture_warn { assert_nil adapter.error("bare-fallback") }
    assert_includes captured, "bare-fallback"
  end

  def test_from_returns_an_adapter_that_does_not_raise_for_default_path
    adapter = LoggerAdapter.from(nil)

    # All four entry points must be safe to call. Stderr is redirected so
    # the default Kernel.warn fallback does not pollute test output.
    capture_warn do
      assert_nil adapter.info("a")
      assert_nil adapter.error("b")
    end
  end

  private

  def capture_warn
    original_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original_stderr
  end
end
