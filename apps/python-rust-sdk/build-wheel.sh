#!/usr/bin/env bash
# Builds a Linux wheel for otel_ffi_sdk (not published to PyPI) into this
# app's dist/, via the official maturin container image -- so the wheel
# matches the runtime container's glibc/arch regardless of what OS/arch
# this script runs on. A wheel built directly on macOS is a Mach-O binary
# and cannot be installed in the Linux app container at all; see
# Dockerfile.
set -euo pipefail
cd "$(dirname "$0")"

SRC_DIR="${OTEL_FFI_SDK_SRC:-../../../../scratch/otel-ffi-sdk}"
if [ ! -f "$SRC_DIR/Cargo.toml" ]; then
    echo "otel_ffi_sdk source not found at $SRC_DIR (set OTEL_FFI_SDK_SRC to override)" >&2
    exit 1
fi
SRC_DIR="$(cd "$SRC_DIR" && pwd)"

rm -rf dist "$SRC_DIR/target/wheels-linux"
mkdir -p dist

echo "building otel_ffi_sdk from $SRC_DIR via ghcr.io/pyo3/maturin..."
podman run --rm \
    -v "$SRC_DIR:/io" \
    ghcr.io/pyo3/maturin build --release --out /io/target/wheels-linux

cp "$SRC_DIR"/target/wheels-linux/*.whl dist/
echo "built $(ls dist)"
