# Rails App (`apps/rails-application/`)

Service name: `hike-tracker`. Sends all signals via OTLP HTTP to `:14318`. Logs also pushed directly to Loki via a custom async logger.

## Commands

```bash
# App runs in Docker; start with:
docker-compose up -d    # starts web, postgres, redis, rabbitmq

# Tests and linting (run inside the container or with bundle exec)
bin/rspec
bundle exec rspec spec/path/to_spec.rb
bundle exec rubocop --auto-correct
brakeman                               # security scan
```

## Key instrumentation files

### `config/initializers/opentelemetry.rb`
- Sets `OTEL_TRACES_EXPORTER`, `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER` to `otlp`.
- `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:14318` (HTTP).
- `OpenTelemetry::SDK.configure` sets service name `hike-tracker` v1.0.0.
- Globals: `APP_TRACER`, `APP_METER`, `COUNTER` (`activities_completed`).
- `duration_histogram` (`http.server.request.duration`) recorded via `ActiveSupport::Notifications` subscription on `process_action.action_controller`.

### `config/initializers/logger.rb`
- Replaces `Rails.logger` with `Loki::AsyncLogger` (custom, at `lib/loki/`).
- Pushes logs in batches to Loki. Requires env vars: `LOKI_URL`, `LOKI_USERNAME`, `LOKI_PASSWORD`, `LOKI_BATCH_SIZE`, `LOKI_FLUSH_INTERVAL`.
- Labels each log entry with `service` and `env`.
- `.env` is loaded automatically in `development` / `test` via `dotenv-rails`.

## OTel gems

```ruby
gem "opentelemetry-sdk"
gem "opentelemetry-exporter-otlp"
gem "opentelemetry-metrics-sdk"
gem "opentelemetry-exporter-otlp-metrics"
gem "opentelemetry-logs-sdk"
gem "opentelemetry-exporter-otlp-logs"
```
