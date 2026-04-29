import os
import json
import time
import uuid
import asyncio
import logging
import random
from datetime import datetime, timezone

from fastapi import FastAPI, Request, HTTPException
from pythonjsonlogger import jsonlogger

SERVICE = os.getenv("SERVICE_NAME", "payment-api")
ENVIRONMENT = os.getenv("ENVIRONMENT", "demo-ec2")

logger = logging.getLogger(SERVICE)
lh = logging.StreamHandler()
lh.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(lh)
logger.setLevel(logging.INFO)

app = FastAPI(title="payment-api", version="1.0.0")


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


@app.get("/pay/normal")
async def pay_normal(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    await asyncio.sleep(0.05 + random.uniform(0, 0.03))
    tx_id = str(uuid.uuid4())[:12]
    latency = int((time.time()-start)*1000)
    slog("info", "/pay/normal", req_id, 200, latency, "normal")
    return {"tx_id": tx_id, "status": "approved", "amount": round(random.uniform(10, 500), 2),
            "latency_ms": latency}


@app.get("/pay/slow")
async def pay_slow(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    delay = 2.5 + random.uniform(0, 0.5)
    await asyncio.sleep(delay)
    tx_id = str(uuid.uuid4())[:12]
    latency = int((time.time()-start)*1000)
    slog("warning", "/pay/slow", req_id, 200, latency, "slow-payment")
    return {"tx_id": tx_id, "status": "approved", "amount": round(random.uniform(10, 500), 2),
            "latency_ms": latency, "slow_reason": "fraud_check_timeout"}


@app.get("/pay/error")
async def pay_error(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    await asyncio.sleep(0.05)
    error_msg = "Payment gateway rejected: insufficient funds"
    latency = int((time.time()-start)*1000)
    slog("error", "/pay/error", req_id, 500, latency, "payment-error", error=error_msg)
    raise HTTPException(status_code=500, detail=error_msg)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
