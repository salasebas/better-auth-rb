# frozen_string_literal: true

module BetterAuth
  module Telemetry
    class HttpDispatcher
      DEFAULT_QUEUE_SIZE = 100
      IDLE_TIMEOUT_SECONDS = 1.0
      EMPTY_SLEEP_SECONDS = 0.01

      def initialize(endpoint:, logger:, queue_size: DEFAULT_QUEUE_SIZE)
        @endpoint = endpoint
        @logger = logger
        @queue = SizedQueue.new(queue_size)
        @mutex = Mutex.new
        @worker = nil
      end

      def call(event)
        enqueue(event)
        start_worker
        nil
      rescue => e
        @logger.error("[better-auth.telemetry] http dispatch failed: #{e.class}: #{e.message}")
        nil
      end

      private

      def enqueue(event)
        @queue.push(event, true)
      rescue ThreadError
        @logger.error("[better-auth.telemetry] http dispatch dropped: queue full")
      end

      def start_worker
        @mutex.synchronize do
          return if @worker&.alive?

          @worker = Thread.new { worker_loop }
          @worker.report_on_exception = false if @worker.respond_to?(:report_on_exception=)
        end
      end

      def worker_loop
        idle_deadline = monotonic_now + IDLE_TIMEOUT_SECONDS

        loop do
          event = pop_nonblocking
          if event
            idle_deadline = monotonic_now + IDLE_TIMEOUT_SECONDS
            deliver(event)
          elsif monotonic_now >= idle_deadline
            break
          else
            sleep EMPTY_SLEEP_SECONDS
          end
        end
      ensure
        restart = false
        @mutex.synchronize do
          @worker = nil if @worker == Thread.current
          restart = !@queue.empty?
        end
        start_worker if restart
      end

      def pop_nonblocking
        @queue.pop(true)
      rescue ThreadError
        nil
      end

      def deliver(event)
        HttpClient.post_json(@endpoint, event, logger: @logger)
      rescue => e
        @logger.error("[better-auth.telemetry] http dispatch failed: #{e.class}: #{e.message}")
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
