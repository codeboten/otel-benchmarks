import os
from contextlib import asynccontextmanager

import redis.asyncio as redis
from fastapi import FastAPI
from fastapi.responses import PlainTextResponse


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.rdb = redis.Redis(host=os.environ.get("VALKEY_HOST", "valkey"), port=6379)
    yield
    await app.state.rdb.aclose()


app = FastAPI(lifespan=lifespan)


@app.get("/", response_class=PlainTextResponse)
async def index():
    value = await app.state.rdb.execute_command("INCR", "counter")
    return PlainTextResponse(str(value))


if os.environ.get("ENABLE_OTEL"):
    # exclude_spans is the only way to drop the ASGI "http send"/"http receive"
    # INTERNAL spans; there's no OTEL_* env var for it.
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    FastAPIInstrumentor.instrument_app(app, exclude_spans=["receive", "send"])
