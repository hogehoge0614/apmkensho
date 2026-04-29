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

SERVICE = os.getenv("SERVICE_NAME", "inventory-api")
ENVIRONMENT = os.getenv("ENVIRONMENT", "demo-ec2")

logger = logging.getLogger(SERVICE)
lh = logging.StreamHandler()
lh.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(lh)
logger.setLevel(logging.INFO)

app = FastAPI(title="inventory-api", version="1.0.0")


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
        "downstream_service": None,
        "error_message": error,
    }))


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE}


@app.get("/check/normal")
async def check_normal(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    await asyncio.sleep(0.02 + random.uniform(0, 0.01))
    items = [
        {"sku": f"SKU-{random.randint(1000,9999)}", "qty": random.randint(1, 100)}
        for _ in range(3)
    ]
    latency = int((time.time()-start)*1000)
    slog("info", "/check/normal", req_id, 200, latency, "normal")
    return {"available": True, "items": items, "latency_ms": latency}


@app.get("/check/slow")
async def check_slow(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    delay = 1.8 + random.uniform(0, 0.4)
    await asyncio.sleep(delay)
    items = [{"sku": f"SKU-{random.randint(1000,9999)}", "qty": random.randint(1, 100)}]
    latency = int((time.time()-start)*1000)
    slog("warning", "/check/slow", req_id, 200, latency, "slow-inventory")
    return {"available": True, "items": items, "latency_ms": latency, "slow_reason": "cache_miss"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
