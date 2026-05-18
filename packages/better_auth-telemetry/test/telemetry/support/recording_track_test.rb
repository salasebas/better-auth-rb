# frozen_string_literal: true

require_relative "../../test_helper"
require_relative "recording_track"

class RecordingTrackTest < Minitest::Test
  RecordingTrack = BetterAuth::Telemetry::Test::RecordingTrack

  def test_call_records_each_event_in_order
    recorder = RecordingTrack.new

    recorder.call(type: :init, payload: {})
    recorder.call(type: :ping, payload: {seq: 1})

    assert_equal [{type: :init, payload: {}}, {type: :ping, payload: {seq: 1}}],
      recorder.events
  end

  def test_call_returns_nil_for_every_invocation
    recorder = RecordingTrack.new

    assert_nil recorder.call(type: :a, payload: {})
    assert_nil recorder.call(type: :b, payload: {})
  end

  def test_events_returns_a_snapshot_copy
    recorder = RecordingTrack.new
    recorder.call(type: :a, payload: {})

    snapshot = recorder.events
    snapshot.clear

    refute_empty recorder.events, "mutating the snapshot must not drain the recorder"
  end

  def test_last_returns_the_most_recent_event
    recorder = RecordingTrack.new
    assert_nil recorder.last

    recorder.call(type: :a, payload: {})
    recorder.call(type: :b, payload: {})

    assert_equal({type: :b, payload: {}}, recorder.last)
  end

  def test_clear_drains_all_recorded_events
    recorder = RecordingTrack.new
    recorder.call(type: :a, payload: {})
    recorder.call(type: :b, payload: {})

    recorder.clear

    assert_empty recorder.events
    assert_nil recorder.last
  end

  def test_call_returns_nil_when_buffer_is_full
    recorder = RecordingTrack.new(max_events: 2)

    recorder.call(type: :a, payload: {})
    recorder.call(type: :b, payload: {})

    assert_nil recorder.call(type: :c, payload: {})
    assert_equal [{type: :b, payload: {}}, {type: :c, payload: {}}], recorder.events
  end

  def test_recorder_is_proc_compatible
    recorder = RecordingTrack.new

    invoke = ->(track) { track.call(type: :ping, payload: {}) }
    invoke.call(recorder)

    assert_equal [{type: :ping, payload: {}}], recorder.events

    yielder = ->(&block) { block.call(type: :pong, payload: {}) }
    yielder.call(&recorder)

    assert_equal :pong, recorder.last.fetch(:type)
  end

  def test_concurrent_calls_record_every_event
    recorder = RecordingTrack.new
    threads = 8
    per_thread = 50

    workers = Array.new(threads) do |t|
      Thread.new do
        per_thread.times { |i| recorder.call(type: :tick, payload: {t: t, i: i}) }
      end
    end
    workers.each(&:join)

    assert_equal threads * per_thread, recorder.events.size
  end

  def test_initializer_rejects_invalid_max_events
    assert_raises(ArgumentError) { RecordingTrack.new(max_events: 0) }
    assert_raises(ArgumentError) { RecordingTrack.new(max_events: -1) }
    assert_raises(ArgumentError) { RecordingTrack.new(max_events: "10") }
  end
end
