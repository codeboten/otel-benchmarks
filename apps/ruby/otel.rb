require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/rack"
require "opentelemetry/instrumentation/sinatra"
require "opentelemetry/instrumentation/redis"

OpenTelemetry::SDK.configure do |c|
  c.use "OpenTelemetry::Instrumentation::Rack"
  c.use "OpenTelemetry::Instrumentation::Sinatra"
  # don't trace the connection handshakes that happen outside of requests
  c.use "OpenTelemetry::Instrumentation::Redis", { trace_root_spans: false }
end
