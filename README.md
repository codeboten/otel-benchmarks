# OpenTelemetry overhead benchmark (podman compose)

A repeatable, local environment for measuring the CPU/memory/latency overhead
of the OpenTelemetry SDK, following the methodology from [OpenTelemetry SDK overhead](https://docs.coroot.com/tracing/opentelemetry-overhead/)
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
- **app-python** / **app-nodejs** / **app-ruby** / **app-rust** / **app-python-cpp** /
  **app-python-rust** — the app under test, one per language, plus two
  variants of the same Python app wired to an alternative SDK binding
  instead of the standard pure-Python distro: `app-python-cpp` uses
  [honeycomb-pycpp](https://pypi.org/project/honeycomb-pycpp/) (pybind11
  bindings over `opentelemetry-cpp`), and `app-python-rust` uses
  `otel_ffi_sdk` (PyO3 bindings over `opentelemetry-rust` — see
  `apps/python-rust-sdk/`), each exposed on its own host port
  (8081/8082/8083/8084/8085/8086) and each built so the exact same image
  runs with or without tracing depending on `ENABLE_OTEL`.
- **k6** — the load generator, invoked on demand with
  `podman compose run --rm k6 ...` (not started by `up`)

## Setup

1. `cp .env.example .env` and fill in `GRAFANA_CLOUD_OTLP_ENDPOINT`,
   `GRAFANA_CLOUD_INSTANCE_ID`, `GRAFANA_CLOUD_API_KEY` (and
   `GRAFANA_CLOUD_TOKEN`, a base64 `instance_id:api_key` pair, used by the
   collector's own self-telemetry exporter — see `otelcol/config.yaml`).
2. `scripts/setup.sh` — checks the podman machine has enough CPU/RAM,
   locates podman's Docker-compatible API socket, verifies it's reachable
   from a container, builds any app-local wheels not published anywhere
   (currently just `otel_ffi_sdk`, via `apps/python-rust-sdk/
   build-wheel.sh`), builds the images, and starts `valkey` + `otelcol`.
3. Bring the app containers up as needed, e.g.
   `podman compose -f podman-compose.yml up -d app-python app-nodejs app-ruby app-rust app-python-cpp app-python-rust`.

If `rust-sdk`'s own source changes later, re-run
`apps/python-rust-sdk/build-wheel.sh` (or all of `scripts/setup.sh`)
before rebuilding `app-python-rust` — the wheel in `dist/` isn't rebuilt
automatically by `podman compose build`.

On macOS, give the podman machine VM at least 4 CPUs and 8GB RAM
(`podman machine set --cpus 6 --memory 8192`, then restart the machine). The
default 2 CPU / 4GB machine *works*, but every app, valkey, otelcol and the
load generator are all contending for the same 2 cores, which shows up as
occasional multi-second latency spikes and dropped/short-counted k6
iterations unrelated to the SDK under test — we saw exactly this on a 2-CPU
machine (one run even silently undercounted spans by ~25% under sustained
100% sampling) and it disappeared entirely after moving to 6 CPUs / 8GB. The
numbers in [Results](#results) below are from the 6-CPU run.

## Running the benchmark

```sh
LANGS="python nodejs ruby rust python-cpp python-rust" ./scripts/run-benchmark.sh
```

Each language runs its own full off/100/50/20/0% x 2-pass sweep with the
*other* languages' containers stopped, to avoid them competing for the same
CPU. Key environment variables (all optional):

| var | default | meaning |
|---|---|---|
| `LANGS` | `python nodejs` | space-separated subset of `python nodejs ruby rust python-cpp python-rust` |
| `MODES` | `off 100 50 20 0` | sampling modes to run |
| `PASSES` | `2` | repeats per mode |
| `WARMUP_SECONDS` | `90` | load-bearing warmup before measuring, discarded |
| `MEASURE_SECONDS` | `240` | measurement window |
| `LOAD_RATE` | `1000` | requests/second held by k6 |

A full `python nodejs ruby rust python-cpp python-rust` x 5 modes x 2 passes
sweep takes about 330 minutes (90s warmup + 240s measure, per mode, per pass,
per language) — split it into a few `LANGS` subsets run back to back if your
background-task runner caps single-command runtime below that.

Output lands in `results/<timestamp>/`: `summary.csv` (one row per
language/mode/pass), plus per-run raw k6 output, k6 JSON summaries, and
container CPU/mem samples.

## Results

Collected 2026-10-28/29, `python nodejs ruby rust python-cpp python-rust` x
5 modes x 2 passes, plus one extra clean pass for `python-cpp` and
`python-rust`, 1000 req/s, on a 6-vCPU / 8GB podman machine. CPU overhead is
relative to that implementation's own `off` baseline.

Four passes hit isolated contention/measurement spikes unrelated to the SDK
under test (throughput and/or CPU dropping sharply for the whole window) and
were excluded entirely rather than averaged in, same as the earlier
`python`/`off` anomaly: `nodejs`/`0%`/pass 2 (throughput fell to 635 rps),
`ruby`/`100%`/pass 2 and `ruby`/`50%`/pass 2 (throughput and CPU both
dropped), and `python-rust`/`100%`/pass 2 (throughput collapsed to ~5 rps).
Every other cell below is the straight average of its (2-3) remaining
passes.

| lang | mode | CPU cores | CPU vs off | mem MB | mem vs off | p50 ms | p99 ms | p99 vs off |
|---|---|---|---|---|---|---|---|---|
| python | off | 0.225 | – | 187 | – | 0.35 | 0.81 | – |
| python | 100% | 0.335 | **+49%** | 294 | +57% | 0.36 | 6.39 | **+692%** |
| python | 50% | 0.329 | +46% | 291 | +56% | 0.38 | 5.60 | +594% |
| python | 20% | 0.311 | +38% | 287 | +54% | 0.38 | 1.39 | +73% |
| python | 0% | 0.295 | +31% | 274 | +47% | 0.40 | 0.92 | +14% |
| nodejs | off | 0.170 | – | 140 | – | 0.32 | 0.71 | – |
| nodejs | 100% | 0.247 | **+46%** | 676 | **+383%** | 0.32 | 0.84 | +18% |
| nodejs | 50% | 0.263 | +55% | 679 | +386% | 0.36 | 1.09 | +53% |
| nodejs | 20% | 0.266 | +56% | 650 | +365% | 0.36 | 0.94 | +33% |
| nodejs | 0% | 0.214 | +26% | 617 | +342% | 0.33 | 0.93 | +31% |
| ruby | off | 0.220 | – | 172 | – | 0.32 | 1.35 | – |
| ruby | 100% | 0.248 | **+13%** | 243 | +41% | 0.27 | 2.40 | +78% |
| ruby | 50% | 0.243 | +11% | 232 | +35% | 0.33 | 1.92 | +43% |
| ruby | 20% | 0.238 | +8% | 220 | +28% | 0.31 | 1.78 | +32% |
| ruby | 0% | 0.217 | -1% | 177 | +3% | 0.36 | 1.16 | -14% |
| rust | off | 0.058 | – | 10 | – | 0.24 | 0.59 | – |
| rust | 100% | 0.072 | **+22%** | 13 | +29% | 0.29 | 0.56 | -5% |
| rust | 50% | 0.069 | +17% | 13 | +28% | 0.31 | 0.56 | -5% |
| rust | 20% | 0.069 | +17% | 13 | +27% | 0.31 | 0.59 | -1% |
| rust | 0% | 0.067 | +15% | 12 | +13% | 0.27 | 0.51 | -15% |
| python-cpp | off | 0.241 | – | 181 | – | 0.40 | 0.93 | – |
| python-cpp | 100% | 0.334 | **+39%** | 239 | +32% | 0.40 | 0.77 | -17% |
| python-cpp | 50% | 0.304 | +26% | 242 | +34% | 0.38 | 0.76 | -19% |
| python-cpp | 20% | 0.303 | +26% | 240 | +33% | 0.35 | 0.64 | -31% |
| python-cpp | 0% | 0.315 | +31% | 233 | +29% | 0.40 | 0.73 | -22% |
| python-rust | off | 0.218 | – | 185 | – | 0.39 | 0.93 | – |
| python-rust | 100% | 0.333 | **+53%** | 245 | +33% | 0.40 | 0.73 | -21% |
| python-rust | 50% | 0.317 | +45% | 242 | +31% | 0.42 | 0.77 | -17% |
| python-rust | 20% | 0.297 | +36% | 238 | +29% | 0.35 | 0.63 | -32% |
| python-rust | 0% | 0.294 | +35% | 226 | +22% | 0.37 | 0.67 | -28% |
