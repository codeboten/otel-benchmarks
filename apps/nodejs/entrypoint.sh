#!/bin/sh
set -e

if [ -n "$ENABLE_OTEL" ]; then
    export NODE_OPTIONS="--require @opentelemetry/auto-instrumentations-node/register"
else
    unset NODE_OPTIONS
fi

exec node server.js
