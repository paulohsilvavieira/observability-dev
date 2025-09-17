require Rails.root.join("lib/loki/client")
require Rails.root.join("lib/loki/async_logger")
if Rails.env.development? || Rails.env.test?
  require 'dotenv/load'  # só carrega o .env em dev/test
end
loki_client = Loki::Client.new(
  url: ENV.fetch("LOKI_URL"),
  username: ENV.fetch("LOKI_USERNAME"),
  password: ENV.fetch("LOKI_PASSWORD")
)

Rails.logger = Loki::AsyncLogger.new(
  loki_client: loki_client,
  labels: { service: ENV.fetch("OTEL_SERVICE_NAME"), env: Rails.env },
  context: ENV.fetch("OTEL_SERVICE_NAME"),
  batch_size: ENV.fetch("LOKI_BATCH_SIZE").to_i,
  flush_interval: ENV.fetch("LOKI_FLUSH_INTERVAL").to_f
)
