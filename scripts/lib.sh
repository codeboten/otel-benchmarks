#!/usr/bin/env bash
# Shared helpers for setup.sh and run-benchmark.sh. Source, don't execute.

wait_for_http() {
    local url="$1" tries="${2:-60}" i=0
    until curl -fsS "$url" >/dev/null 2>&1; do
        i=$((i + 1))
        if [ "$i" -ge "$tries" ]; then
            echo "timed out waiting for $url" >&2
            return 1
        fi
        sleep 1
    done
}

# Sums every sample of a Prometheus counter/gauge scraped from the
# collector's self-telemetry endpoint, across all its label combinations.
otelcol_metric_sum() {
    local metric="$1"
    curl -fsS http://localhost:8888/metrics 2>/dev/null |
        awk -v m="$metric" '
            $0 ~ "^"m"(\\{|[ \t])" {
                v = $NF
                if (v ~ /^[-0-9.eE+]+$/) sum += v
            }
            END { printf "%.0f", sum+0 }
        '
}
