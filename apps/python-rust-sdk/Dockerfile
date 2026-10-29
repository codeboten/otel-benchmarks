FROM python:3.13-slim

WORKDIR /app

# otel_ffi_sdk isn't published to PyPI: ./build-wheel.sh (run by
# scripts/setup.sh before `podman compose build`) builds a Linux wheel for
# it into dist/, via the official maturin container image so it matches
# this image's glibc/arch regardless of what the wheel was built *on* (a
# wheel built directly on macOS is a Mach-O binary and won't import here
# at all).
COPY dist/*.whl ./
RUN pip install --no-cache-dir ./*.whl && rm -f ./*.whl

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py otel-config.yaml entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=fastapi

EXPOSE 8080
ENTRYPOINT ["./entrypoint.sh"]
