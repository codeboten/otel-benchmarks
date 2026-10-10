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
- **app-python** / **app-nodejs** / **app-ruby** / **app-rust** / **app-python-hc** —
  the app under test, one per language (plus `app-python-hc`, the same Python
  app instrumented with [honeycomb-pycpp](https://pypi.org/project/honeycomb-pycpp/)'s
  OpenTelemetry C++ SDK bindings instead of the standard pure-Python distro),
  each exposed on its own host port (8081/8082/8083/8084/8085) and each built
  so the exact same image runs with or without tracing depending on
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
   `podman compose -f podman-compose.yml up -d app-python app-nodejs app-ruby app-rust app-python-hc`.

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
LANGS="python nodejs ruby rust python-hc" ./scripts/run-benchmark.sh
```

Each language runs its own full off/100/50/20/0% x 2-pass sweep with the
*other* languages' containers stopped, to avoid them competing for the same
CPU. Key environment variables (all optional):

| var | default | meaning |
|---|---|---|
| `LANGS` | `python nodejs` | space-separated subset of `python nodejs ruby rust python-hc` |
| `MODES` | `off 100 50 20 0` | sampling modes to run |
| `PASSES` | `2` | repeats per mode |
| `WARMUP_SECONDS` | `90` | load-bearing warmup before measuring, discarded |
| `MEASURE_SECONDS` | `240` | measurement window |
| `LOAD_RATE` | `1000` | requests/second held by k6 |

A full `python nodejs ruby rust python-hc` x 5 modes x 2 passes sweep takes
about 275 minutes (90s warmup + 240s measure, per mode, per pass, per
language) — split it into a few `LANGS` subsets run back to back if your
background-task runner caps single-command runtime below that.

Output lands in `results/<timestamp>/`: `summary.csv` (one row per
language/mode/pass), plus per-run raw k6 output, k6 JSON summaries, and
container CPU/mem samples.

## Results

Collected 2026-10-09/10, `python nodejs ruby rust python-hc` x 5 modes x 2
passes (3 for `python`'s 100/50/20/0% modes — an extra pass was re-run
after the original `off` pass hit a one-off anomaly; see below), 1000 req/s,
on a 6-vCPU / 8GB podman machine. CPU overhead is relative to that
implementation's own `off` baseline.

| lang | mode | CPU cores | CPU vs off | mem MB | mem vs off | p50 ms | p99 ms | p99 vs off |
|---|---|---|---|---|---|---|---|---|
| python | off | 0.141 | – | 186 | – | 0.24 | 0.55 | – |
| python | 100% | 0.311 | **+122%** | 293 | +57% | 0.34 | 5.21 | **+857%** |
| python | 50% | 0.280 | +99% | 290 | +56% | 0.33 | 2.94 | +440% |
| python | 20% | 0.265 | +89% | 287 | +54% | 0.31 | 1.37 | +151% |
| python | 0% | 0.237 | +69% | 274 | +47% | 0.29 | 0.56 | +3% |
| nodejs | off | 0.104 | – | 141 | – | 0.19 | 0.41 | – |
| nodejs | 100% | 0.176 | **+69%** | 676 | **+378%** | 0.21 | 0.46 | +11% |
| nodejs | 50% | 0.172 | +65% | 674 | +377% | 0.23 | 0.52 | +25% |
| nodejs | 20% | 0.160 | +53% | 678 | +379% | 0.22 | 0.47 | +14% |
| nodejs | 0% | 0.163 | +56% | 592 | +319% | 0.23 | 0.50 | +21% |
| ruby | off | 0.167 | – | 173 | – | 0.26 | 0.68 | – |
| ruby | 100% | 0.235 | **+41%** | 231 | +33% | 0.28 | 1.85 | +173% |
| ruby | 50% | 0.221 | +32% | 221 | +28% | 0.27 | 1.30 | +92% |
| ruby | 20% | 0.201 | +21% | 216 | +25% | 0.28 | 1.00 | +48% |
| ruby | 0% | 0.193 | +16% | 177 | +3% | 0.29 | 0.75 | +10% |
| rust | off | 0.033 | – | 10 | – | 0.17 | 0.31 | – |
| rust | 100% | 0.035 | **+6%** | 13 | +32% | 0.15 | 0.31 | -2% |
| rust | 50% | 0.034 | +3% | 12 | +27% | 0.16 | 0.25 | -19% |
| rust | 20% | 0.037 | +11% | 12 | +27% | 0.15 | 0.23 | -25% |
| rust | 0% | 0.035 | +5% | 12 | +27% | 0.18 | 0.28 | -9% |
| python-hc | off | 0.137 | – | 180 | – | 0.23 | 0.48 | – |
| python-hc | 100% | 0.307 | **+124%** | 239 | +33% | 0.35 | 0.73 | +54% |
| python-hc | 50% | 0.265 | +93% | 238 | +32% | 0.34 | 0.87 | +82% |
| python-hc | 20% | 0.249 | +82% | 236 | +31% | 0.32 | 0.64 | +33% |
| python-hc | 0% | 0.263 | +92% | 230 | +28% | 0.36 | 0.74 | +54% |
