use std::env;
use std::error::Error;

use axum::extract::Request;
use axum::middleware::Next;
use axum::response::Response;
use opentelemetry::propagation::TextMapPropagator;
use opentelemetry::trace::{FutureExt, SpanKind, TraceContextExt, Tracer};
use opentelemetry::{global, Context, KeyValue};
use opentelemetry_http::HeaderExtractor;
use opentelemetry_otlp::{Protocol, SpanExporter, WithExportConfig};
use opentelemetry_sdk::propagation::TraceContextPropagator;
use opentelemetry_sdk::trace::{Sampler, SdkTracerProvider};
use opentelemetry_sdk::Resource;
use redis::aio::ConnectionManager;
use redis::RedisResult;

fn sampler_from_env() -> Sampler {
    let name = env::var("OTEL_TRACES_SAMPLER").unwrap_or_else(|_| "parentbased_always_on".to_string());
    let arg: f64 = env::var("OTEL_TRACES_SAMPLER_ARG")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(1.0);
    match name.as_str() {
        "parentbased_traceidratio" => Sampler::ParentBased(Box::new(Sampler::TraceIdRatioBased(arg))),
        "traceidratio" => Sampler::TraceIdRatioBased(arg),
        "always_off" => Sampler::AlwaysOff,
        _ => Sampler::ParentBased(Box::new(Sampler::AlwaysOn)),
    }
}

// Sets up the SDK: exporter, sampler and propagator come from the standard
// OTEL_* environment variables, read by hand since Rust has no zero-code
// agent to do it for us.
pub fn init() -> Result<SdkTracerProvider, Box<dyn Error>> {
    let service_name = env::var("OTEL_SERVICE_NAME").unwrap_or_else(|_| "bench-rust".to_string());
    let exporter = SpanExporter::builder()
        .with_http()
        .with_protocol(Protocol::HttpBinary)
        .build()?;
    // the batch span processor runs on its own thread with a blocking HTTP client
    let provider = SdkTracerProvider::builder()
        .with_batch_exporter(exporter)
        .with_sampler(sampler_from_env())
        .with_resource(
            Resource::builder()
                .with_attribute(KeyValue::new("service.name", service_name))
                .build(),
        )
        .build();
    global::set_tracer_provider(provider.clone());
    global::set_text_map_propagator(TraceContextPropagator::new());
    Ok(provider)
}

// axum middleware: makes the SERVER span (reading the W3C context from the
// headers, even though nothing upstream sets one in this benchmark).
pub async fn trace_middleware(request: Request, next: Next) -> Response {
    let propagator = TraceContextPropagator::new();
    let parent_cx = propagator.extract(&HeaderExtractor(request.headers()));

    let tracer = global::tracer("bench-rust");
    let span_name = format!("{} {}", request.method(), request.uri().path());
    let span = tracer
        .span_builder(span_name)
        .with_kind(SpanKind::Server)
        .start_with_context(&tracer, &parent_cx);
    let cx = parent_cx.with_span(span);

    next.run(request).with_context(cx).await
}

// Handler-side CLIENT span around the INCR call, under the current context
// (the SERVER span from trace_middleware, when tracing is on).
pub async fn traced_incr(conn: &mut ConnectionManager, redis_host: &str, redis_port: u16) -> RedisResult<i64> {
    let tracer = global::tracer("bench-rust");
    let span = tracer
        .span_builder("INCR")
        .with_kind(SpanKind::Client)
        .with_attributes([
            KeyValue::new("db.system", "redis"),
            KeyValue::new("net.peer.name", redis_host.to_string()),
            KeyValue::new("net.peer.port", redis_port as i64),
        ])
        .start_with_context(&tracer, &Context::current());

    let cx = Context::current_with_span(span);
    redis::cmd("INCR")
        .arg("counter")
        .query_async(conn)
        .with_context(cx)
        .await
}
