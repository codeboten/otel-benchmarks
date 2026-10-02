#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
source scripts/lib.sh

if [ ! -f .env ]; then
    cp .env.example .env
    echo "Created .env from .env.example." >&2
    echo "Fill in GRAFANA_CLOUD_OTLP_ENDPOINT / GRAFANA_CLOUD_INSTANCE_ID / GRAFANA_CLOUD_API_KEY, then re-run this script." >&2
    exit 1
fi

set -a
source .env
set +a

: "${GRAFANA_CLOUD_OTLP_ENDPOINT:?set this in .env}"
: "${GRAFANA_CLOUD_INSTANCE_ID:?set this in .env}"
: "${GRAFANA_CLOUD_API_KEY:?set this in .env}"

if [[ "$GRAFANA_CLOUD_OTLP_ENDPOINT" == *"<region>"* ]]; then
    echo "GRAFANA_CLOUD_OTLP_ENDPOINT in .env still has the <region> placeholder." >&2
    exit 1
fi

echo "== podman machine resources =="
if command -v podman >/dev/null && podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
    machine_json="$(podman machine inspect 2>/dev/null || true)"
    cpus="$(echo "$machine_json" | grep -m1 '"CPUs"' | grep -o '[0-9]\+' || true)"
    mem_mb="$(echo "$machine_json" | grep -m1 '"Memory"' | grep -o '[0-9]\+' || true)"
    echo "podman machine: ${cpus:-?} CPUs, ${mem_mb:-?} MiB RAM"
    if [ -n "${cpus:-}" ] && [ "$cpus" -lt 4 ]; then
        cat >&2 <<EOF

WARNING: the podman machine has only ${cpus} vCPU(s). Results on an undersized VM will be
dominated by contention, not by the OpenTelemetry SDK. Consider:

  podman machine stop
  podman machine set --cpus 6 --memory 8192
  podman machine start

EOF
    fi
fi

echo "== locating podman's Docker-compatible API socket =="
sock_uri="$(podman info --format '{{.Host.RemoteSocket.Path}}' 2>/dev/null || true)"
sock_path="${sock_uri#unix://}"
if [ -z "$sock_path" ]; then
    echo "Could not determine the podman socket path via 'podman info'; leaving PODMAN_SOCK_PATH as-is in .env." >&2
else
    echo "Found: $sock_path"
    if podman machine list --format '{{.Name}}' 2>/dev/null | grep -q .; then
        if ! podman machine ssh -- "test -S '$sock_path'" 2>/dev/null; then
            echo "warning: $sock_path doesn't look like a socket inside the podman machine VM." >&2
        fi
    fi
    if grep -q '^PODMAN_SOCK_PATH=' .env; then
        sed -i.bak "s#^PODMAN_SOCK_PATH=.*#PODMAN_SOCK_PATH=${sock_path}#" .env && rm -f .env.bak
    else
        echo "PODMAN_SOCK_PATH=${sock_path}" >>.env
    fi
fi

echo "== verifying the socket is reachable from a container =="
if ! podman run --rm --user root --security-opt label=disable \
    -v "${sock_path:-/run/podman/podman.sock}:/var/run/docker.sock:ro" \
    docker.io/library/alpine:3.20 \
    sh -c "apk add --no-cache curl >/dev/null 2>&1 && curl -fsS --unix-socket /var/run/docker.sock http://localhost/_ping"; then
    cat >&2 <<EOF

Could not reach the Docker-compatible API through ${sock_path:-/run/podman/podman.sock}.
The docker_stats receiver in otelcol won't be able to collect container
CPU/memory metrics until this works. See README.md for troubleshooting.
EOF
    exit 1
fi
echo "ok"

echo "== building images =="
podman compose -f podman-compose.yml build

echo "== starting valkey + otelcol =="
podman compose -f podman-compose.yml up -d valkey otelcol

wait_for_http "http://localhost:8888/metrics" 60
echo
echo "otelcol is up."
echo "  self-telemetry (accepted/sent/dropped spans): http://localhost:8888/metrics"
echo "  local container-metrics mirror:               http://localhost:8889/metrics"
echo
echo "Next: scripts/run-benchmark.sh"
