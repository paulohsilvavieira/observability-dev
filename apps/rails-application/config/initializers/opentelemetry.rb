# Configure the SDK
#
#


ENV["OTEL_METRICS_EXPORTER"] = "otlp"
ENV["OTEL_TRACES_EXPORTER"] = "otlp"
ENV["OTEL_LOGS_EXPORTER"] = "otlp"

ENV["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://localhost:14318"
OpenTelemetry::SDK.configure do |config|
  config.service_name = "hike-tracker"
  config.service_version = "1.0.0"

  # Installs instrumentation for all available libraries
  # config.use_all

  # Can also install instrumentation this library by library, for example:
  # config.use 'OpenTelemetry::Instrumentation::Rack', { allowed_request_hedaers: ['Host', 'Referer']}
  # config.use 'OpenTelemetry::Instrumentation::Rails'
end

APP_TRACER = OpenTelemetry.tracer_provider.tracer("hike-tracker")


APP_METER = OpenTelemetry.meter_provider.meter("hike-tracker")

COUNTER = APP_METER.create_counter("activities_completed", unit: "activity", description: "Number of activities completed")








# # Save the counter as a constant to access it outside the initializer
# HIKE_COUNTER = meter.create_counter("activities.completed", unit: "activity", description: "Number of activities completed")

# # Create a histogram with a view
# explicit_boundaries = [ 0.005, 0.01, 0.025, 0.05, 0.075, 0.1, 0.25, 0.5, 0.75, 1, 2.5, 5, 7.5, 10 ]

# OpenTelemetry.meter_provider.add_view("http.server.request.duration",
#   type: :histogram,
#   aggregation: OpenTelemetry::SDK::Metrics::Aggregation::ExplicitBucketHistogram.new(
#     boundaries: explicit_boundaries
#   )
# )

# duration_histogram = meter.create_histogram("http.server.request.duration", unit: "s", description: "Duration of HTTP server requests. RAILS")

# # Subscribe to an ActiveSupport notification to add a metric defined by Semantic Conventions that's not recorded by instrumentation yet
# ActiveSupport::Notifications.subscribe "process_action.action_controller" do |event|
#   Rails.logger.info ">>> RECORDING DURATION: #{event.duration}"
#   duration_histogram.record(event.duration, attributes: { "test" => "ok" })
# end
#

duration_histogram = APP_METER.create_histogram(
  "http.server.request.duration",
  unit: "s",
  description: "Duration of HTTP server requests"
)

ActiveSupport::Notifications.subscribe "process_action.action_controller" do |event|
  attributes = {
    "http.request.method" => event.payload[:method],
    "http.response.status.code" => event.payload[:status],
    "http.route" => event.payload[:path]
  }

  duration_histogram.record(event.duration, attributes: attributes)
end
