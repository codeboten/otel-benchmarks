FROM python:3.13-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py otel-config.yaml entrypoint.sh ./
RUN chmod +x entrypoint.sh

ENV OTEL_PYTHON_DISABLED_INSTRUMENTATIONS=fastapi

EXPOSE 8080
ENTRYPOINT ["./entrypoint.sh"]
