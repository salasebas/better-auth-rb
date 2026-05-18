# frozen_string_literal: true

require_relative "../test_helper"
require "better_auth/telemetry/noop_publisher"

class NoopPublisherTest < Minitest::Test
  NoopPublisher = BetterAuth::Telemetry::NoopPublisher

  def test_publish_returns_nil
    assert_nil NoopPublisher.new.publish(type: "init", payload: {})
  end

  def test_publish_returns_nil_for_empty_event_hash
    assert_nil NoopPublisher.new.publish({})
  end

  def test_publish_accepts_event_with_string_keys
    assert_nil NoopPublisher.new.publish("type" => "ping", "payload" => {"k" => "v"})
  end

  def test_publish_accepts_event_with_symbol_keys
    assert_nil NoopPublisher.new.publish(type: :ping, payload: {k: :v})
  end

  def test_publish_accepts_arbitrary_payload_shapes
    publisher = NoopPublisher.new

    assert_nil publisher.publish(type: "deeply_nested", payload: {a: {b: [1, 2, {c: "d"}]}})
    assert_nil publisher.publish(type: "with_nil_payload", payload: nil)
  end

  def test_publish_accepts_non_hash_event
    publisher = NoopPublisher.new

    assert_nil publisher.publish(nil)
    assert_nil publisher.publish("a string event")
    assert_nil publisher.publish(42)
    assert_nil publisher.publish(:symbol_event)
  end

  def test_publish_can_be_called_repeatedly_without_side_effects
    publisher = NoopPublisher.new

    10.times { |i| assert_nil publisher.publish(type: "tick", payload: {i: i}) }
  end

  def test_enabled_returns_false
    refute_predicate NoopPublisher.new, :enabled?
    assert_equal false, NoopPublisher.new.enabled?
  end

  def test_distinct_instances_each_report_disabled
    a = NoopPublisher.new
    b = NoopPublisher.new

    refute a.enabled?
    refute b.enabled?
  end
end
