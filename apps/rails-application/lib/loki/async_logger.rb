# lib/loki/async_logger.rb
require "logger"
require "thread"
require "securerandom"
require "time"
require_relative "helpers"

module Loki
  class AsyncLogger < Logger
    def initialize(loki_client:, labels:, context: "RailsApp", batch_size: 50, flush_interval: 2)
      super($stdout)
      @loki_client = loki_client
      @labels = labels
      @context = context
      @batch_size = batch_size
      @queue = Queue.new

      # thread de flush periódico
      Thread.new do
        loop do
          sleep flush_interval
          flush
        end
      end
    end

    def add(severity, message = nil, progname = nil, &block)
      # Pega traceId e spanId do OpenTelemetry, se existir
      span = OpenTelemetry::Trace.current_span
      trace_id = span&.context&.hex_trace_id
      span_id  = span&.context&.hex_span_id
      extract_log_message= Loki::Helpers.extract_log_message(message, progname, block)
      clean_msg = Loki::Helpers.strip_ansi(extract_log_message)

      log_json = {
        context: @context,
        level: severity.to_s.downcase,
        severity: format_severity(severity),
        message: clean_msg,
        timestamp: Time.now.utc.iso8601(3),
        traceId: trace_id,
        spanId: span_id
      }.to_json

      @queue << log_json
      flush if @queue.size >= @batch_size

      super(severity, extract_log_message, &block)
    end

    def flush
      batch = []
      until @queue.empty? || batch.size >= @batch_size
        batch << @queue.pop(true) rescue nil
      end
      return if batch.empty?

      Thread.new do
        begin
          @loki_client.push(batch, @labels)
        rescue => e
          warn "Falha ao enviar batch para Loki: #{e.message}"
        end
      end
    end
  end
end
