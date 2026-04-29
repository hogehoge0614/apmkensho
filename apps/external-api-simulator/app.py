import os
import json
import time
import uuid
import asyncio
import logging
import random
from datetime import datetime, timezone

from fastapi import FastAPI, Request
from pythonjsonlogger import jsonlogger

SERVICE = os.getenv("SERVICE_NAME", "external-api-simulator")
ENVIRONMENT = os.getenv("ENVIRONMENT", "demo-ec2")

logger = logging.getLogger(SERVICE)
lh = logging.StreamHandler()
lh.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(lh)
logger.setLevel(logging.INFO)

app = FastAPI(title="external-api-simulator", version="1.0.0")


def get_request_id(request: Request) -> str:
    return request.headers.get("X-Request-Id", str(uuid.uuid4()))


def slog(level, endpoint, req_id, status, latency, scenario=None, error=None):
    getattr(logger, level)(json.dumps({
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service_name": SERVICE,
        "environment": ENVIRONMENT,
        "endpoint": endpoint,
        "request_id": req_id,
        "status_code": status,
        "latency_ms": latency,
        "scenario": scenario,
        "downstream_service": "external-saas",
        "error_message": error,
    }))


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE}


@app.get("/external/normal")
async def external_normal(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    await asyncio.sleep(0.15 + random.uniform(0, 0.05))
    latency = int((time.time()-start)*1000)
    slog("info", "/external/normal", req_id, 200, latency, "external-normal")
    return {"provider": "external-saas", "result": "ok", "latency_ms": latency,
            "request_id": req_id}


@app.get("/external/slow")
async def external_slow(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    delay = 3.5 + random.uniform(0, 0.5)
    await asyncio.sleep(delay)
    latency = int((time.time()-start)*1000)
    slog("warning", "/external/slow", req_id, 200, latency, "external-slow")
    return {"provider": "external-saas", "result": "ok_slow", "latency_ms": latency,
            "slow_reason": "external_rate_limit", "request_id": req_id}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
