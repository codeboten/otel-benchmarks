#!/usr/bin/env bash
# Drives the 5 sampling modes x N passes x N languages sweep described in
# https://docs.coroot.com/tracing/opentelemetry-overhead/
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
source scripts/lib.sh

set -a
source .env
set +a

LANGS=(${LANGS:-python nodejs})
MODES=(${MODES:-off 100 50 20 0})
PASSES="${PASSES:-2}"
WARMUP_SECONDS="${WARMUP_SECONDS:-90}"
MEASURE_SECONDS="${MEASURE_SECONDS:-240}"
LOAD_RATE="${LOAD_RATE:-1000}"
K6_PREALLOCATED_VUS="${K6_PREALLOCATED_VUS:-100}"
K6_MAX_VUS="${K6_MAX_VUS:-400}"

# macOS ships bash 3.2 (no associative arrays), so these are plain functions.
lang_port() {
    case "$1" in
    python) echo 8081 ;;
    nodejs) echo 8082 ;;
    ruby) echo 8083 ;;
    rust) echo 8084 ;;
    esac
}

lang_container() {
    case "$1" in
    python) echo "otel-overhead-bench-app-python-1" ;;
    nodejs) echo "otel-overhead-bench-app-nodejs-1" ;;
    ruby) echo "otel-overhead-bench-app-ruby-1" ;;
    rust) echo "otel-overhead-bench-app-rust-1" ;;
    esac
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="results/${TIMESTAMP}"
mkdir -p "$OUT_DIR"
SUMMARY_CSV="${OUT_DIR}/summary.csv"
echo "lang,mode,pass,requests_total,measure_s,throughput_rps,latency_p50_ms,latency_p99_ms,http_failed_ratio,cpu_cores_avg,mem_mb_avg,spans_accepted,spans_refused" >"$SUMMARY_CSV"

# `set -a; source .env` above already exported ENABLE_OTEL/OTEL_TRACES_SAMPLER*
# into this script's own environment. docker-compose's variable interpolation
# gives an already-exported shell var precedence over the .env FILE, so
# rewriting the file (as this used to do) had no effect on any `podman
# compose` call made for the rest of the script's life: every mode after the
# first silently reused whatever was in .env when the script started.
# Exporting directly, instead of rewriting the file, is both simpler and
# actually takes effect.
set_mode_env() {
    case "$1" in
    off) export ENABLE_OTEL= ;;
    100) export ENABLE_OTEL=1 OTEL_TRACES_SAMPLER=parentbased_always_on OTEL_TRACES_SAMPLER_ARG=1 ;;
    50) export ENABLE_OTEL=1 OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.5 ;;
    20) export ENABLE_OTEL=1 OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0.2 ;;
    0) export ENABLE_OTEL=1 OTEL_TRACES_SAMPLER=parentbased_traceidratio OTEL_TRACES_SAMPLER_ARG=0 ;;
    esac
}

# Polls the collector's local podman_stats mirror (:8889) every 2s for the
# given duration, writing "cpu_percent,mem_bytes" lines to out_file.
#
# Matches on container_id, not container_name: the prometheus exporter keeps
# a dead container's last-known series around for a while after it's
# replaced (same container_name, stale container_id), and since every mode
# does a --force-recreate, matching by name alone can silently and
# deterministically pick up the previous container generation's frozen
# values for the entire run.
sample_container_metrics() {
    local container="$1" dur="$2" out="$3"
    local cid
    cid="$(podman inspect "$container" --format '{{.Id}}' 2>/dev/null || true)"
    : >"$out"
    local end=$((SECONDS + dur))
    while [ "$SECONDS" -lt "$end" ]; do
        curl -fsS http://localhost:8889/metrics 2>/dev/null | awk -v id="$cid" -v OFS=',' '
            $0 ~ ("^container_cpu_percent_ratio\\{.*container_id=\"" id "\"") { cpu = $NF }
            $0 ~ ("^container_memory_usage_total_bytes\\{.*container_id=\"" id "\"") { mem = $NF }
            END { if (cpu != "") print cpu, mem }
        ' >>"$out"
        sleep 2
    done
}

avg_col() {
    awk -F',' -v col="$2" '{ v=$col; if (v!="") { sum+=v; n++ } } END { if (n>0) printf "%.4f", sum/n; else print "" }' "$1"
}

run_one() {
    local lang="$1" mode="$2" pass="$3"
    local service="app-${lang}" port="$(lang_port "$lang")" container="$(lang_container "$lang")"
    local tag="${lang}-${mode}-pass${pass}"

    echo "=== ${tag} ==="
    set_mode_env "$mode"
    podman compose -f podman-compose.yml up -d --force-recreate "$service"
    wait_for_http "http://localhost:${port}/" 60

    echo "warming up under load for ${WARMUP_SECONDS}s..."
    podman compose -f podman-compose.yml run --rm \
        -e TARGET_URL="http://${service}:8080/" \
        -e RATE="$LOAD_RATE" \
        -e DURATION="${WARMUP_SECONDS}s" \
        -e PREALLOCATED_VUS="$K6_PREALLOCATED_VUS" \
        -e MAX_VUS="$K6_MAX_VUS" \
        k6 run /scripts/script.js >"${OUT_DIR}/${tag}-warmup-k6.txt" 2>&1 || true

    echo "measuring for ${MEASURE_SECONDS}s..."
    local stats_file="${OUT_DIR}/${tag}-container-metrics.csv"
    local k6_out="${OUT_DIR}/${tag}-k6.txt"
    local k6_summary_rel="${OUT_DIR}/${tag}-k6-summary.json"
    local k6_summary_in_container="/results/${TIMESTAMP}/${tag}-k6-summary.json"

    local accepted_before refused_before accepted_after refused_after
    accepted_before="$(otelcol_metric_sum otelcol_receiver_accepted_spans)"
    refused_before="$(otelcol_metric_sum otelcol_receiver_refused_spans)"

    sample_container_metrics "$container" "$MEASURE_SECONDS" "$stats_file" &
    local stats_pid=$!

    podman compose -f podman-compose.yml run --rm \
        -e TARGET_URL="http://${service}:8080/" \
        -e RATE="$LOAD_RATE" \
        -e DURATION="${MEASURE_SECONDS}s" \
        -e PREALLOCATED_VUS="$K6_PREALLOCATED_VUS" \
        -e MAX_VUS="$K6_MAX_VUS" \
        k6 run --summary-export="$k6_summary_in_container" /scripts/script.js >"$k6_out" 2>&1 || true

    wait "$stats_pid"

    accepted_after="$(otelcol_metric_sum otelcol_receiver_accepted_spans)"
    refused_after="$(otelcol_metric_sum otelcol_receiver_refused_spans)"
    local spans_accepted=$((accepted_after - accepted_before))
    local spans_refused=$((refused_after - refused_before))

    local total_req rps p50 p99 failed_ratio cpu_avg mem_avg
    if [ -f "$k6_summary_rel" ]; then
        total_req="$(python3 -c "import json;print(json.load(open('$k6_summary_rel'))['metrics']['http_reqs']['count'])" 2>/dev/null || echo "")"
        rps="$(python3 -c "import json;print(round(json.load(open('$k6_summary_rel'))['metrics']['http_reqs']['rate'],2))" 2>/dev/null || echo "")"
        p50="$(python3 -c "import json;print(json.load(open('$k6_summary_rel'))['metrics']['http_req_duration']['p(50)'])" 2>/dev/null || echo "")"
        p99="$(python3 -c "import json;print(json.load(open('$k6_summary_rel'))['metrics']['http_req_duration']['p(99)'])" 2>/dev/null || echo "")"
        failed_ratio="$(python3 -c "import json;print(json.load(open('$k6_summary_rel'))['metrics']['http_req_failed']['value'])" 2>/dev/null || echo "")"
    else
        echo "warning: k6 summary not found at ${k6_summary_rel}; see ${k6_out}" >&2
        total_req="" rps="" p50="" p99="" failed_ratio=""
    fi

    cpu_avg="$(avg_col "$stats_file" 1)"
    mem_bytes_avg="$(avg_col "$stats_file" 2)"
    mem_avg=""
    [ -n "$mem_bytes_avg" ] && mem_avg="$(awk -v b="$mem_bytes_avg" 'BEGIN{printf "%.1f", b/1048576}')"
    [ -n "$cpu_avg" ] && cpu_avg="$(awk -v c="$cpu_avg" 'BEGIN{printf "%.3f", c/100}')"

    echo "${lang},${mode},${pass},${total_req},${MEASURE_SECONDS},${rps},${p50},${p99},${failed_ratio},${cpu_avg},${mem_avg},${spans_accepted},${spans_refused}" >>"$SUMMARY_CSV"
}

for lang in "${LANGS[@]}"; do
    other_services=()
    for other in "${LANGS[@]}"; do
        [ "$other" != "$lang" ] && other_services+=("app-${other}")
    done
    if [ "${#other_services[@]}" -gt 0 ]; then
        echo "stopping ${other_services[*]} to avoid contention while testing ${lang}"
        podman compose -f podman-compose.yml stop "${other_services[@]}" >/dev/null 2>&1 || true
    fi

    for pass in $(seq 1 "$PASSES"); do
        for mode in "${MODES[@]}"; do
            run_one "$lang" "$mode" "$pass"
        done
    done

    if [ "${#other_services[@]}" -gt 0 ]; then
        podman compose -f podman-compose.yml start "${other_services[@]}" >/dev/null 2>&1 || true
    fi
done

echo
echo "done. summary: ${SUMMARY_CSV}"
echo "raw k6 output, k6 JSON summaries, and container-metric samples are alongside it in ${OUT_DIR}/"
