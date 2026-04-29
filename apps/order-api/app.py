import os
import json
import time
import uuid
import asyncio
import logging
import random
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, Request
from pythonjsonlogger import jsonlogger

SERVICE = os.getenv("SERVICE_NAME", "order-api")
ENVIRONMENT = os.getenv("ENVIRONMENT", "demo-ec2")
EXTERNAL_URL = os.getenv("EXTERNAL_URL", "http://external-api-simulator:8000")

logger = logging.getLogger(SERVICE)
h = logging.StreamHandler()
h.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(h)
logger.setLevel(logging.INFO)

app = FastAPI(title="order-api", version="1.0.0")
http_client = httpx.AsyncClient(timeout=30.0)


def get_request_id(request: Request) -> str:
    return request.headers.get("X-Request-Id", str(uuid.uuid4()))


def slog(level, endpoint, req_id, status, latency, scenario=None, downstream=None, error=None):
    getattr(logger, level)(json.dumps({
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "service_name": SERVICE,
        "environment": ENVIRONMENT,
        "endpoint": endpoint,
        "request_id": req_id,
        "status_code": status,
        "latency_ms": latency,
        "scenario": scenario,
        "downstream_service": downstream,
        "error_message": error,
    }))


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE}


@app.get("/order/normal")
async def order_normal(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    await asyncio.sleep(0.03 + random.uniform(0, 0.02))
    order_id = str(uuid.uuid4())[:8]
    latency = int((time.time()-start)*1000)
    slog("info", "/order/normal", req_id, 200, latency, "normal")
    return {"order_id": order_id, "status": "created", "latency_ms": latency}


@app.get("/order/external-slow")
async def order_external_slow(request: Request):
    req_id = get_request_id(request)
    start = time.time()

    t0 = time.time()
    resp = await http_client.get(
        f"{EXTERNAL_URL}/external/slow",
        headers={"X-Request-Id": req_id}
    )
    ext_latency = int((time.time()-t0)*1000)
    slog("info", "/order/external-slow", req_id, 200, ext_latency,
         "external-slow", "external-api-simulator")

    order_id = str(uuid.uuid4())[:8]
    latency = int((time.time()-start)*1000)
    return {"order_id": order_id, "status": "created", "latency_ms": latency,
            "external_call_ms": ext_latency}


@app.on_event("shutdown")
async def shutdown():
    await http_client.aclose()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
