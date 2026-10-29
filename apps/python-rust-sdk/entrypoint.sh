#!/bin/sh
set -e

if [ -n "$ENABLE_OTEL" ]; then
    export OTEL_CONFIG_FILE=/app/otel-config.yaml
    exec opentelemetry-instrument uvicorn app:app --host 0.0.0.0 --port 8080 --workers 4 --no-access-log
else
    exec uvicorn app:app --host 0.0.0.0 --port 8080 --workers 4 --no-access-log
fi
