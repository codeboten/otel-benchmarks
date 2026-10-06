mod otel;

use std::env;

use axum::extract::State;
use axum::http::StatusCode;
use axum::middleware;
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use axum::Router;
use redis::aio::ConnectionManager;
use redis::RedisResult;

#[derive(Clone)]
struct AppState {
    redis: ConnectionManager,
    traced: bool,
    redis_host: String,
    redis_port: u16,
}

#[tokio::main]
async fn main() {
    let enable_otel = !env::var("ENABLE_OTEL").unwrap_or_default().is_empty();
    let redis_host = env::var("VALKEY_HOST").unwrap_or_else(|_| "valkey".to_string());
    let redis_port: u16 = 6379;

    let client = redis::Client::open(format!("redis://{redis_host}:{redis_port}/")).expect("invalid redis url");
    let conn = ConnectionManager::new(client).await.expect("redis connection failed");

    let state = AppState {
        redis: conn,
        traced: enable_otel,
        redis_host: redis_host.clone(),
        redis_port,
    };

    let mut app = Router::new().route("/", get(incr)).with_state(state);

    // With tracing off, the middleware isn't added at all, and the handler
    // below takes the branch with no span code whatsoever.
    if enable_otel {
        otel::init().expect("otel init failed");
        app = app.layer(middleware::from_fn(otel::trace_middleware));
    }

    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}

async fn incr(State(st): State<AppState>) -> Response {
    let mut conn = st.redis.clone();
    let res: RedisResult<i64> = if st.traced {
        otel::traced_incr(&mut conn, &st.redis_host, st.redis_port).await
    } else {
        redis::cmd("INCR").arg("counter").query_async(&mut conn).await
    };
    match res {
        Ok(v) => v.to_string().into_response(),
        Err(e) => (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()).into_response(),
    }
}
