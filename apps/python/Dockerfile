FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
# Deliberately not running `opentelemetry-bootstrap -a install`: it would also
# pull in opentelemetry-instrumentation-requests (a dependency of the OTLP/HTTP
# exporter), which would then auto-instrument the exporter's own export calls.
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=fastapi

EXPOSE 8080
ENTRYPOINT ["./entrypoint.sh"]
