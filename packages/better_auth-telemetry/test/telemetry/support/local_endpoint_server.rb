# frozen_string_literal: true

require "socket"

module BetterAuth
  module Telemetry
    module Test
      # Short-lived HTTP server used by Telemetry tests to capture a single
      # outgoing `POST /telemetry` request without resorting to HTTP
      # mocking. Boots a `TCPServer` bound to an ephemeral port on
      # `127.0.0.1` in a background thread that accepts connections,
      # parses the request line/headers/body, stores the parsed request,
      # and replies with `HTTP/1.1 204 No Content` (matching the upstream
      # ingest contract) before closing the socket.
      #
      # The server keeps accepting connections until {#stop} is called,
      # but only the first `POST` is retained as {#captured}; later
      # requests still receive a 204 response. This matches the
      # "accepts a single HTTP POST" requirement while remaining tolerant
      # of clients that establish a TCP connection without sending the
      # captured request first (for example a connectivity probe).
      #
      # Usage:
      #
      #     server = BetterAuth::Telemetry::Test::LocalEndpointServer.new
      #     begin
      #       Net::HTTP.post(URI(server.url), '{"a":1}',
      #                      "Content-Type" => "application/json")
      #       captured = server.captured
      #       captured.path    # => "/telemetry"
      #       captured.headers # => {"content-type"=>"application/json", ...}
      #       captured.body    # => '{"a":1}'
      #     ensure
      #       server.stop
      #     end
      #
      # The class only ever raises `ArgumentError`-style errors out of its
      # public API; transport-level exceptions raised inside the
      # background acceptor thread are swallowed so the helper cannot
      # destabilize the suite.
      class LocalEndpointServer
        # Captured HTTP request, exposed as the value of {#captured}.
        #
        # @!attribute [r] url
        #   @return [String] the absolute request URL the client posted to,
        #     e.g. `"http://127.0.0.1:54321/telemetry"`.
        # @!attribute [r] path
        #   @return [String] the request path, always `"/telemetry"` for a
        #     normal Telemetry post.
        # @!attribute [r] headers
        #   @return [Hash{String=>String}] downcased header names mapped to
        #     their stripped string values.
        # @!attribute [r] body
        #   @return [String] the raw request body (already read from the
        #     socket using `Content-Length`).
        CapturedRequest = Struct.new(:url, :path, :headers, :body, keyword_init: true)

        # Path the helper advertises for posts. The captured `path` will
        # equal whatever the client actually requested, but {#url} always
        # uses this constant suffix.
        PATH = "/telemetry"

        # @return [Integer] the ephemeral port the server is listening on.
        attr_reader :port

        # Boot the server. Returns immediately once the listening socket
        # is bound and the acceptor thread is running.
        def initialize(status: 204, body: "")
          @status = status
          @response_body = body.to_s
          @server = TCPServer.new("127.0.0.1", 0)
          @port = @server.addr[1]
          @mutex = Mutex.new
          @captured = nil
          @captures = []
          @stopped = false
          @thread = Thread.new { accept_loop }
          @thread.report_on_exception = false if @thread.respond_to?(:report_on_exception=)
        end

        # @return [String] the full URL clients should `POST` to, of the
        #   form `"http://127.0.0.1:<port>/telemetry"`.
        def url
          "http://127.0.0.1:#{@port}#{PATH}"
        end

        # @return [CapturedRequest, nil] the first captured `POST`
        #   request, or `nil` if no POST has been received yet.
        def captured
          @mutex.synchronize { @captured }
        end

        def captures
          @mutex.synchronize { @captures.dup }
        end

        # Stop the server: close the listening socket and join (or kill)
        # the acceptor thread so the helper does not leak threads across
        # test runs. Idempotent and safe to call multiple times.
        #
        # @return [void]
        def stop
          @mutex.synchronize do
            return if @stopped
            @stopped = true
          end

          begin
            @server.close unless @server.closed?
          rescue IOError, Errno::EBADF, Errno::ENOTCONN
            # Socket already closed; ignore.
          end

          thread = @thread
          @thread = nil
          if thread && thread != Thread.current
            unless thread.join(1)
              thread.kill
              thread.join(1)
            end
          end

          nil
        end

        private

        def accept_loop
          loop do
            break if @stopped

            socket =
              begin
                @server.accept
              rescue IOError, Errno::EBADF, Errno::ECONNABORTED
                break
              end

            begin
              handle(socket)
            rescue
              # Never let a malformed request take down the test thread.
              nil
            ensure
              begin
                socket.close unless socket.closed?
              rescue IOError, Errno::EBADF
                # ignore
              end
            end
          end
        end

        def handle(socket)
          request_line = socket.gets
          return if request_line.nil?

          method, target, _http_version = request_line.to_s.split
          target = target.to_s
          target = "/" if target.empty?

          headers = {}
          while (line = socket.gets)
            line = line.chomp
            break if line.empty?

            key, value = line.split(":", 2)
            next if key.nil?
            headers[key.downcase.strip] = value.to_s.strip
          end

          content_length = headers["content-length"].to_i
          body = (content_length > 0) ? socket.read(content_length).to_s : ""

          if method == "POST"
            captured = CapturedRequest.new(
              url: "http://127.0.0.1:#{@port}#{target}",
              path: target,
              headers: headers,
              body: body
            )
            @mutex.synchronize do
              @captured ||= captured
              @captures << captured
            end
          end

          status_text = (@status.to_i == 204) ? "No Content" : "Error"
          socket.write(
            "HTTP/1.1 #{@status.to_i} #{status_text}\r\n" \
            "Content-Length: #{@response_body.bytesize}\r\n" \
            "Connection: close\r\n" \
            "\r\n" \
            "#{@response_body}"
          )
        end
      end
    end
  end
end
