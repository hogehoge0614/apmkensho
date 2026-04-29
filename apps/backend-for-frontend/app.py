import os
import json
import time
import uuid
import asyncio
import logging
import random
from datetime import datetime, timezone

import httpx
from fastapi import FastAPI, Request, HTTPException
from fastapi.responses import JSONResponse
from pythonjsonlogger import jsonlogger

SERVICE = os.getenv("SERVICE_NAME", "backend-for-frontend")
ENVIRONMENT = os.getenv("ENVIRONMENT", "demo-ec2")

ORDER_URL = os.getenv("ORDER_URL", "http://order-api:8000")
INVENTORY_URL = os.getenv("INVENTORY_URL", "http://inventory-api:8000")
PAYMENT_URL = os.getenv("PAYMENT_URL", "http://payment-api:8000")

logger = logging.getLogger(SERVICE)
handler = logging.StreamHandler()
handler.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(handler)
logger.setLevel(logging.INFO)

app = FastAPI(title="backend-for-frontend", version="1.0.0")
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


async def call_service(url: str, path: str, req_id: str, service_name: str) -> dict:
    h = {"X-Request-Id": req_id}
    resp = await http_client.get(f"{url}{path}", headers=h)
    resp.raise_for_status()
    return resp.json()


def _ok_response(req_id, scenario, latency, steps):
    return JSONResponse(content={
        "status": "success",
        "scenario": scenario,
        "request_id": req_id,
        "latency_ms": latency,
        "steps": steps,
        "has_error": False,
    })


def _error_response(req_id, scenario, latency, steps, error):
    return {
        "status": "error",
        "scenario": scenario,
        "request_id": req_id,
        "latency_ms": latency,
        "steps": steps,
        "has_error": True,
        "error": error,
    }


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE}


@app.get("/api/checkout/normal")
async def checkout_normal(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    steps = []

    try:
        t0 = time.time()
        await call_service(INVENTORY_URL, "/check/normal", req_id, "inventory-api")
        steps.append({"service": "inventory-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

        t0 = time.time()
        await call_service(ORDER_URL, "/order/normal", req_id, "order-api")
        steps.append({"service": "order-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

        t0 = time.time()
        await call_service(PAYMENT_URL, "/pay/normal", req_id, "payment-api")
        steps.append({"service": "payment-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

        latency = int((time.time()-start)*1000)
        slog("info", "/api/checkout/normal", req_id, 200, latency, "normal", "order+inventory+payment")
        return _ok_response(req_id, "normal", latency, steps)

    except Exception as e:
        latency = int((time.time()-start)*1000)
        slog("error", "/api/checkout/normal", req_id, 500, latency, "normal", error=str(e))
        raise HTTPException(status_code=500, detail=str(e))


@app.get("/api/checkout/slow-inventory")
async def checkout_slow_inventory(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    steps = []

    t0 = time.time()
    await call_service(INVENTORY_URL, "/check/slow", req_id, "inventory-api")
    steps.append({"service": "inventory-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(ORDER_URL, "/order/normal", req_id, "order-api")
    steps.append({"service": "order-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(PAYMENT_URL, "/pay/normal", req_id, "payment-api")
    steps.append({"service": "payment-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    latency = int((time.time()-start)*1000)
    slog("info", "/api/checkout/slow-inventory", req_id, 200, latency, "slow-inventory")
    return _ok_response(req_id, "slow-inventory", latency, steps)


@app.get("/api/checkout/slow-payment")
async def checkout_slow_payment(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    steps = []

    t0 = time.time()
    await call_service(INVENTORY_URL, "/check/normal", req_id, "inventory-api")
    steps.append({"service": "inventory-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(ORDER_URL, "/order/normal", req_id, "order-api")
    steps.append({"service": "order-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(PAYMENT_URL, "/pay/slow", req_id, "payment-api")
    steps.append({"service": "payment-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    latency = int((time.time()-start)*1000)
    slog("info", "/api/checkout/slow-payment", req_id, 200, latency, "slow-payment")
    return _ok_response(req_id, "slow-payment", latency, steps)


@app.get("/api/checkout/payment-error")
async def checkout_payment_error(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    steps = []

    t0 = time.time()
    await call_service(INVENTORY_URL, "/check/normal", req_id, "inventory-api")
    steps.append({"service": "inventory-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(ORDER_URL, "/order/normal", req_id, "order-api")
    steps.append({"service": "order-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    try:
        await call_service(PAYMENT_URL, "/pay/error", req_id, "payment-api")
        steps.append({"service": "payment-api", "latency_ms": int((time.time()-t0)*1000), "error": False})
    except httpx.HTTPStatusError as e:
        steps.append({"service": "payment-api", "latency_ms": int((time.time()-t0)*1000), "error": True})
        latency = int((time.time()-start)*1000)
        slog("error", "/api/checkout/payment-error", req_id, 500, latency, "payment-error",
             downstream="payment-api", error=str(e))
        return JSONResponse(
            status_code=500,
            content=_error_response(req_id, "payment-error", latency, steps, "Payment service error")
        )

    latency = int((time.time()-start)*1000)
    return _ok_response(req_id, "payment-error", latency, steps)


@app.get("/api/checkout/external-slow")
async def checkout_external_slow(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    steps = []

    t0 = time.time()
    await call_service(INVENTORY_URL, "/check/normal", req_id, "inventory-api")
    steps.append({"service": "inventory-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(ORDER_URL, "/order/external-slow", req_id, "order-api")
    steps.append({"service": "order-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(PAYMENT_URL, "/pay/normal", req_id, "payment-api")
    steps.append({"service": "payment-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    latency = int((time.time()-start)*1000)
    slog("info", "/api/checkout/external-slow", req_id, 200, latency, "external-slow")
    return _ok_response(req_id, "external-slow", latency, steps)


@app.get("/api/checkout/random")
async def checkout_random(request: Request):
    scenarios = ["normal", "slow-inventory", "slow-payment", "payment-error", "external-slow"]
    chosen = random.choice(scenarios)
    mapping = {
        "normal": checkout_normal,
        "slow-inventory": checkout_slow_inventory,
        "slow-payment": checkout_slow_payment,
        "payment-error": checkout_payment_error,
        "external-slow": checkout_external_slow,
    }
    return await mapping[chosen](request)


@app.get("/api/search")
async def search(request: Request, q: str = "shoes"):
    req_id = get_request_id(request)
    start = time.time()
    await asyncio.sleep(0.02 + random.uniform(0, 0.02))
    products = [
        {"id": f"prod-{i}", "name": f"{q} item {i}", "price": round(random.uniform(10, 500), 2)}
        for i in range(1, random.randint(3, 8))
    ]
    latency = int((time.time()-start)*1000)
    slog("info", "/api/search", req_id, 200, latency, "search")
    return {"query": q, "results": products, "count": len(products), "latency_ms": latency,
            "request_id": req_id}


@app.get("/api/user-journey")
async def user_journey(request: Request):
    req_id = get_request_id(request)
    start = time.time()
    steps = []

    t0 = time.time()
    await asyncio.sleep(0.025)
    steps.append({"service": "search", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(INVENTORY_URL, "/check/normal", req_id, "inventory-api")
    steps.append({"service": "inventory-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(ORDER_URL, "/order/normal", req_id, "order-api")
    steps.append({"service": "order-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    t0 = time.time()
    await call_service(PAYMENT_URL, "/pay/normal", req_id, "payment-api")
    steps.append({"service": "payment-api", "latency_ms": int((time.time()-t0)*1000), "error": False})

    latency = int((time.time()-start)*1000)
    slog("info", "/api/user-journey", req_id, 200, latency, "user-journey")
    return _ok_response(req_id, "user-journey", latency, steps)


@app.on_event("shutdown")
async def shutdown():
    await http_client.aclose()


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
