# OpenTelemetry overhead benchmark (podman compose)

A repeatable, local environment for measuring the CPU/memory/latency overhead
of the OpenTelemetry SDK, following the methodology from [OpenTelemetry SDK overhead](https://coroot.com/docs/tracing/opentelemetry-overhead)
benchmark: a HTTP service that does one Redis call per request, hit with
a constant request rate, run with tracing off / 100% / 50% / 20% / 0%
sampled.

This stack uses an OpenTelemetry Collector as the trace/metrics
backend and ships to Grafana Cloud, so it works as a self-contained podman
compose project on a laptop.

## Architecture

- **valkey** — the datastore each app does one `INCR counter` against.
- **otelcol** (`otel/opentelemetry-collector-contrib`) — receives traces via
  OTLP from the apps, and polls podman's API (`podman_stats` receiver) for
  per-container CPU/memory. Exposes two local endpoints the
  bench script reads directly, so measurement doesn't depend on a round trip
  through Grafana Cloud's query API:
  - `:8888/metrics` — the collector's own self-telemetry (spans
    accepted/refused — used to confirm nothing was dropped).
  - `:8889/metrics` — a local Prometheus mirror of the `podman_stats`
    container metrics.
  - Traces are *not* currently forwarded anywhere outside the collector
    (`exporters: [debug]` in the traces pipeline) to avoid shipping
    megabytes of per-span data for every benchmark run; only the
    `podman_stats` container metrics go to Grafana Cloud. Point the traces
    pipeline at `otlphttp/grafana_cloud` instead if you want to browse traces
    there.
- **app-python** / **app-nodejs** / **app-ruby** — the app under test, one
  per language, each exposed on its own host port (8081/8082/8083) and each
  built so the exact same image runs with or without tracing depending on
  `ENABLE_OTEL`.
- **k6** — the load generator, invoked on demand with
  `podman compose run --rm k6 ...` (not started by `up`)

## Setup

1. `cp .env.example .env` and fill in `GRAFANA_CLOUD_OTLP_ENDPOINT`,
   `GRAFANA_CLOUD_INSTANCE_ID`, `GRAFANA_CLOUD_API_KEY` (and
   `GRAFANA_CLOUD_TOKEN`, a base64 `instance_id:api_key` pair, used by the
   collector's own self-telemetry exporter — see `otelcol/config.yaml`).
2. `scripts/setup.sh` — checks the podman machine has enough CPU/RAM,
   locates podman's Docker-compatible API socket, verifies it's reachable
   from a container, builds the images, and starts `valkey` + `otelcol`.
3. Bring the app containers up as needed, e.g.
   `podman compose -f podman-compose.yml up -d app-python app-nodejs app-ruby`.

On macOS, the podman machine VM should have at least 4 CPUs and 8GB RAM
(`podman machine set --cpus 6 --memory 8192`, then restart the machine) —
the default 2 CPU / 4GB machine works but every app, valkey, otelcol and the
load generator are all contending for the same 2 cores, so absolute numbers
will be dominated by contention, not by the SDK. All the numbers in
[Results](#results) below were collected on a 2-CPU machine.

## Running the benchmark

```sh
LANGS="python nodejs ruby" ./scripts/run-benchmark.sh
```

Each language runs its own full off/100/50/20/0% x 2-pass sweep with the
*other* languages' containers stopped, to avoid them competing for the same
CPU. Key environment variables (all optional):

| var | default | meaning |
|---|---|---|
| `LANGS` | `python nodejs` | space-separated subset of `python nodejs ruby` |
| `MODES` | `off 100 50 20 0` | sampling modes to run |
| `PASSES` | `2` | repeats per mode |
| `WARMUP_SECONDS` | `90` | load-bearing warmup before measuring, discarded |
| `MEASURE_SECONDS` | `240` | measurement window |
| `LOAD_RATE` | `1000` | requests/second held by k6 |

A full `python nodejs ruby` x 5 modes x 2 passes sweep takes about 165
minutes (90s warmup + 240s measure, per mode, per pass, per language).

Output lands in `results/<timestamp>/`: `summary.csv` (one row per
language/mode/pass), plus per-run raw k6 output, k6 JSON summaries, and
container CPU/mem samples.

## Results

Collected 2026-10-05, `python nodejs ruby` x 5 modes x 2 passes, 1000 req/s,
on a 2-vCPU podman machine (see the CPU caveat above — read this as relative
overhead per language, not absolute cost). CPU overhead is relative to that
language's own `off` baseline.

| lang | mode | CPU cores | vs off | mem MB | p50 ms | p99 ms |
|---|---|---|---|---|---|---|
| python | off | 0.140 | – | 185 | 0.21 | 0.56 |
| python | 100% | 0.322 | **+130%** | 278 | 0.30 | 2.73 |
| python | 50% | 0.275 | +97% | 275 | 0.29 | 1.18 |
| python | 20% | 0.249 | +78% | 274 | 0.27 | 0.82 |
| python | 0% | 0.229 | +64% | 255 | 0.27 | 0.72 |
| nodejs | off | 0.103 | – | 140 | 0.17 | 0.48 |
| nodejs | 100% | 0.177 | **+71%** | 662 | 0.20 | 0.75 |
| nodejs | 50% | 0.159 | +54% | 647 | 0.20 | 0.61 |
| nodejs | 20% | 0.171 | +65% | 621 | 0.22 | 0.55 |
| nodejs | 0% | 0.160 | +55% | 533 | 0.22 | 0.52 |
| ruby | off | 0.145 | – | 171 | 0.22 | 0.85 |
| ruby | 100% | 0.222 | **+53%** | 230 | 0.25 | 2.28 |
| ruby | 50% | 0.204 | +40% | 223 | 0.25 | 1.76 |
| ruby | 20% | 0.184 | +27% | 216 | 0.23 | 1.41 |
| ruby | 0% | 0.172 | +19% | 181 | 0.24 | 0.77 |
