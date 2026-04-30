import os
import json
import time
import logging
import threading
import random
from contextlib import contextmanager
from datetime import datetime, timezone
from typing import Optional

import psycopg2
import psycopg2.pool
import psycopg2.extras
import httpx

from fastapi import FastAPI, Query, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pythonjsonlogger import jsonlogger

SERVICE = os.getenv("SERVICE_NAME", "device-api")
ENVIRONMENT = os.getenv("ENVIRONMENT", "demo-ec2")
DATABASE_URL = os.getenv("DATABASE_URL", "")
METRICS_COLLECTOR_URL = os.getenv("METRICS_COLLECTOR_URL", "http://metrics-collector:8000")

logger = logging.getLogger(SERVICE)
_h = logging.StreamHandler()
_h.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(_h)
logger.setLevel(logging.INFO)

app = FastAPI(title="device-api", version="3.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

_chaos = {"slow_query": False, "slow_ms": 3000, "error_rate": 0}
_chaos_lock = threading.Lock()
_pool: Optional[psycopg2.pool.ThreadedConnectionPool] = None

SAMPLE_DEVICES = [
    # Tokyo (10)
    {"device_id": "TKY-CORE-001", "name": "東京コアルーター1",    "type": "core_router",  "area": "tokyo",   "location": "東京DC-A棟",      "ip_address": "10.1.1.1",  "vendor": "Cisco",     "model": "ASR 9922",          "status": "active",      "uptime_days": 342},
    {"device_id": "TKY-CORE-002", "name": "東京コアルーター2",    "type": "core_router",  "area": "tokyo",   "location": "東京DC-B棟",      "ip_address": "10.1.1.2",  "vendor": "Juniper",   "model": "MX480",             "status": "active",      "uptime_days": 189},
    {"device_id": "TKY-EDGE-001", "name": "東京エッジルーター1",  "type": "edge_router",  "area": "tokyo",   "location": "東京DC-A棟",      "ip_address": "10.1.2.1",  "vendor": "Cisco",     "model": "ASR 1001-X",        "status": "warning",     "uptime_days": 45},
    {"device_id": "TKY-L3SW-001", "name": "東京L3スイッチ1",     "type": "l3_switch",    "area": "tokyo",   "location": "東京DC-A棟",      "ip_address": "10.1.3.1",  "vendor": "Cisco",     "model": "Catalyst 9500",     "status": "active",      "uptime_days": 210},
    {"device_id": "TKY-L3SW-002", "name": "東京L3スイッチ2",     "type": "l3_switch",    "area": "tokyo",   "location": "東京DC-B棟",      "ip_address": "10.1.3.2",  "vendor": "Juniper",   "model": "EX9200",            "status": "active",      "uptime_days": 178},
    {"device_id": "TKY-FW-001",   "name": "東京FW1",             "type": "firewall",     "area": "tokyo",   "location": "東京DC-A棟",      "ip_address": "10.1.4.1",  "vendor": "Palo Alto", "model": "PA-5260",           "status": "active",      "uptime_days": 89},
    {"device_id": "TKY-AP-001",   "name": "東京AP-丸の内",       "type": "access_point", "area": "tokyo",   "location": "丸の内ビル5F",    "ip_address": "10.1.5.1",  "vendor": "Cisco",     "model": "C9120AXI",          "status": "active",      "uptime_days": 120},
    {"device_id": "TKY-AP-002",   "name": "東京AP-新宿",         "type": "access_point", "area": "tokyo",   "location": "新宿オフィス3F",  "ip_address": "10.1.5.2",  "vendor": "Cisco",     "model": "C9120AXI",          "status": "offline",     "uptime_days": 0},
    {"device_id": "TKY-L2SW-001", "name": "東京L2スイッチ1",     "type": "l2_switch",    "area": "tokyo",   "location": "東京DC-A棟",      "ip_address": "10.1.6.1",  "vendor": "NEC",       "model": "UNIVERGE QX-S5226G","status": "active",      "uptime_days": 265},
    {"device_id": "TKY-L2SW-002", "name": "東京L2スイッチ2",     "type": "l2_switch",    "area": "tokyo",   "location": "東京DC-B棟",      "ip_address": "10.1.6.2",  "vendor": "Fujitsu",   "model": "SR-X526R1",         "status": "maintenance", "uptime_days": 0},
    # Osaka (8)
    {"device_id": "OSK-CORE-001", "name": "大阪コアルーター1",    "type": "core_router",  "area": "osaka",   "location": "大阪DC-梅田",     "ip_address": "10.2.1.1",  "vendor": "Cisco",     "model": "ASR 9912",          "status": "active",      "uptime_days": 287},
    {"device_id": "OSK-EDGE-001", "name": "大阪エッジルーター1",  "type": "edge_router",  "area": "osaka",   "location": "大阪DC-梅田",     "ip_address": "10.2.2.1",  "vendor": "Juniper",   "model": "MX204",             "status": "active",      "uptime_days": 156},
    {"device_id": "OSK-L3SW-001", "name": "大阪L3スイッチ1",     "type": "l3_switch",    "area": "osaka",   "location": "大阪DC-なんば",   "ip_address": "10.2.3.1",  "vendor": "Cisco",     "model": "Catalyst 9500",     "status": "critical",    "uptime_days": 3},
    {"device_id": "OSK-FW-001",   "name": "大阪FW1",             "type": "firewall",     "area": "osaka",   "location": "大阪DC-梅田",     "ip_address": "10.2.4.1",  "vendor": "Palo Alto", "model": "PA-3260",           "status": "active",      "uptime_days": 201},
    {"device_id": "OSK-AP-001",   "name": "大阪AP-梅田",         "type": "access_point", "area": "osaka",   "location": "梅田オフィス8F",  "ip_address": "10.2.5.1",  "vendor": "Cisco",     "model": "C9115AXI",          "status": "active",      "uptime_days": 88},
    {"device_id": "OSK-AP-002",   "name": "大阪AP-なんば",       "type": "access_point", "area": "osaka",   "location": "なんばオフィス2F","ip_address": "10.2.5.2",  "vendor": "Cisco",     "model": "C9115AXI",          "status": "warning",     "uptime_days": 12},
    {"device_id": "OSK-L2SW-001", "name": "大阪L2スイッチ1",     "type": "l2_switch",    "area": "osaka",   "location": "大阪DC-梅田",     "ip_address": "10.2.6.1",  "vendor": "NEC",       "model": "UNIVERGE QX-S5226G","status": "active",      "uptime_days": 310},
    {"device_id": "OSK-L2SW-002", "name": "大阪L2スイッチ2",     "type": "l2_switch",    "area": "osaka",   "location": "大阪DC-なんば",   "ip_address": "10.2.6.2",  "vendor": "Fujitsu",   "model": "SR-X526R1",         "status": "active",      "uptime_days": 145},
    # Nagoya (5)
    {"device_id": "NGY-CORE-001", "name": "名古屋コアルーター1",  "type": "core_router",  "area": "nagoya",  "location": "名古屋DC-栄",     "ip_address": "10.3.1.1",  "vendor": "Cisco",     "model": "ASR 9010",          "status": "active",      "uptime_days": 420},
    {"device_id": "NGY-EDGE-001", "name": "名古屋エッジルーター1","type": "edge_router",  "area": "nagoya",  "location": "名古屋DC-栄",     "ip_address": "10.3.2.1",  "vendor": "Cisco",     "model": "ASR 1001-X",        "status": "active",      "uptime_days": 98},
    {"device_id": "NGY-L3SW-001", "name": "名古屋L3スイッチ1",   "type": "l3_switch",    "area": "nagoya",  "location": "名古屋DC-栄",     "ip_address": "10.3.3.1",  "vendor": "Cisco",     "model": "Catalyst 9300",     "status": "active",      "uptime_days": 230},
    {"device_id": "NGY-FW-001",   "name": "名古屋FW1",           "type": "firewall",     "area": "nagoya",  "location": "名古屋DC-栄",     "ip_address": "10.3.4.1",  "vendor": "Palo Alto", "model": "PA-1410",           "status": "active",      "uptime_days": 156},
    {"device_id": "NGY-AP-001",   "name": "名古屋AP-名駅",       "type": "access_point", "area": "nagoya",  "location": "名駅オフィス4F",  "ip_address": "10.3.5.1",  "vendor": "Cisco",     "model": "C9115AXI",          "status": "warning",     "uptime_days": 5},
    # Fukuoka (4)
    {"device_id": "FUK-CORE-001", "name": "福岡コアルーター1",    "type": "core_router",  "area": "fukuoka", "location": "福岡DC-博多",     "ip_address": "10.4.1.1",  "vendor": "Juniper",   "model": "MX240",             "status": "active",      "uptime_days": 198},
    {"device_id": "FUK-EDGE-001", "name": "福岡エッジルーター1",  "type": "edge_router",  "area": "fukuoka", "location": "福岡DC-博多",     "ip_address": "10.4.2.1",  "vendor": "Cisco",     "model": "ASR 1001-X",        "status": "offline",     "uptime_days": 0},
    {"device_id": "FUK-L3SW-001", "name": "福岡L3スイッチ1",     "type": "l3_switch",    "area": "fukuoka", "location": "福岡DC-博多",     "ip_address": "10.4.3.1",  "vendor": "Cisco",     "model": "Catalyst 9300",     "status": "active",      "uptime_days": 89},
    {"device_id": "FUK-FW-001",   "name": "福岡FW1",             "type": "firewall",     "area": "fukuoka", "location": "福岡DC-博多",     "ip_address": "10.4.4.1",  "vendor": "Palo Alto", "model": "PA-1410",           "status": "active",      "uptime_days": 245},
    # Sapporo (3)
    {"device_id": "SPR-CORE-001", "name": "札幌コアルーター1",    "type": "core_router",  "area": "sapporo", "location": "札幌DC-大通",     "ip_address": "10.5.1.1",  "vendor": "Cisco",     "model": "ASR 9010",          "status": "active",      "uptime_days": 512},
    {"device_id": "SPR-EDGE-001", "name": "札幌エッジルーター1",  "type": "edge_router",  "area": "sapporo", "location": "札幌DC-大通",     "ip_address": "10.5.2.1",  "vendor": "Juniper",   "model": "MX204",             "status": "active",      "uptime_days": 345},
    {"device_id": "SPR-FW-001",   "name": "札幌FW1",             "type": "firewall",     "area": "sapporo", "location": "札幌DC-大通",     "ip_address": "10.5.4.1",  "vendor": "Palo Alto", "model": "PA-1410",           "status": "maintenance", "uptime_days": 0},
]


@contextmanager
def get_conn():
    conn = _pool.getconn()
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        _pool.putconn(conn)


def _init_db():
    global _pool
    _pool = psycopg2.pool.ThreadedConnectionPool(1, 5, DATABASE_URL)
    with get_conn() as conn:
        with conn.cursor() as cur:
            cur.execute("""
                CREATE TABLE IF NOT EXISTS devices (
                    device_id   TEXT PRIMARY KEY,
                    name        TEXT,
                    type        TEXT,
                    area        TEXT,
                    location    TEXT,
                    ip_address  TEXT,
                    vendor      TEXT,
                    model       TEXT,
                    status      TEXT,
                    uptime_days INTEGER,
                    last_seen   TEXT
                )
            """)
            cur.execute("SELECT COUNT(*) FROM devices")
            count = cur.fetchone()[0]
            if count == 0:
                now = datetime.now(timezone.utc).isoformat()
                for d in SAMPLE_DEVICES:
                    cur.execute(
                        """INSERT INTO devices VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)
                           ON CONFLICT (device_id) DO NOTHING""",
                        (d["device_id"], d["name"], d["type"], d["area"], d["location"],
                         d["ip_address"], d["vendor"], d["model"], d["status"], d["uptime_days"], now)
                    )
    logger.info(json.dumps({"event": "db_initialized", "seeded": count == 0, "service": SERVICE}))


@app.on_event("startup")
async def startup():
    _init_db()
    logger.info(json.dumps({"event": "startup", "service": SERVICE, "environment": ENVIRONMENT}))


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE}


@app.get("/devices")
async def list_devices(
    area: Optional[str] = Query(None),
    type: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
    q: Optional[str] = Query(None),
):
    start = time.time()
    with _chaos_lock:
        slow, slow_ms, err_rate = _chaos["slow_query"], _chaos["slow_ms"], _chaos["error_rate"]

    if err_rate > 0 and random.randint(1, 100) <= err_rate:
        logger.error(json.dumps({"event": "error_injected", "endpoint": "/devices", "error_rate": err_rate}))
        raise HTTPException(status_code=500, detail="Database query failed (chaos: error injection active)")

    if slow:
        logger.warning(json.dumps({"event": "slow_query", "endpoint": "/devices", "sleep_ms": slow_ms}))
        time.sleep(slow_ms / 1000)

    sql = "SELECT * FROM devices WHERE 1=1"
    params: list = []
    if area:
        sql += " AND area = %s"
        params.append(area)
    if type:
        sql += " AND type = %s"
        params.append(type)
    if status:
        sql += " AND status = %s"
        params.append(status)
    if q:
        sql += " AND (name LIKE %s OR device_id LIKE %s OR location LIKE %s)"
        params += [f"%{q}%", f"%{q}%", f"%{q}%"]
    sql += " ORDER BY area, type, device_id"

    with get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(sql, params)
            rows = cur.fetchall()

    devices = [dict(r) for r in rows]
    duration_ms = int((time.time() - start) * 1000)
    logger.info(json.dumps({
        "event": "list_devices", "count": len(devices),
        "filters": {"area": area, "type": type, "status": status, "q": q},
        "duration_ms": duration_ms,
    }))
    return {"devices": devices, "total": len(devices), "duration_ms": duration_ms}


@app.get("/devices/{device_id}")
async def get_device(device_id: str):
    start = time.time()
    with _chaos_lock:
        err_rate = _chaos["error_rate"]

    if err_rate > 0 and random.randint(1, 100) <= err_rate:
        logger.error(json.dumps({"event": "error_injected", "endpoint": f"/devices/{device_id}", "error_rate": err_rate}))
        raise HTTPException(status_code=500, detail="Device fetch failed (chaos: error injection active)")

    with get_conn() as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT * FROM devices WHERE device_id = %s", (device_id,))
            row = cur.fetchone()

    if not row:
        logger.warning(json.dumps({"event": "device_not_found", "device_id": device_id}))
        raise HTTPException(status_code=404, detail=f"Device not found: {device_id}")

    device = dict(row)

    # Call metrics-collector — creates the 3rd hop in the distributed trace.
    # OTel auto-instrumentation propagates W3C TraceContext through httpx automatically.
    try:
        resp = httpx.get(
            f"{METRICS_COLLECTOR_URL}/metrics/{device_id}",
            params={"status": device["status"]},
            timeout=5.0,
        )
        resp.raise_for_status()
        device["metrics"] = resp.json()["metrics"]
    except Exception as exc:
        logger.warning(json.dumps({
            "event": "metrics_collector_unavailable",
            "device_id": device_id,
            "error": str(exc),
        }))
        device["metrics"] = {
            "cpu_usage": 0, "memory_usage": 0,
            "bandwidth_in": 0, "bandwidth_out": 0,
            "packet_loss": 0, "latency_ms": 0,
        }

    duration_ms = int((time.time() - start) * 1000)
    logger.info(json.dumps({
        "event": "get_device", "device_id": device_id,
        "status": device["status"], "duration_ms": duration_ms,
    }))
    return device


# ── Chaos control ────────────────────────────────────────────

@app.post("/chaos/slow-query")
async def chaos_slow_query(enable: bool = True, duration_ms: int = 3000):
    with _chaos_lock:
        _chaos["slow_query"] = enable
        _chaos["slow_ms"] = duration_ms
    level = "warning" if enable else "info"
    getattr(logger, level)(json.dumps({"event": "chaos_slow_query", "enabled": enable, "duration_ms": duration_ms}))
    return {"chaos": "slow_query", "enabled": enable, "duration_ms": duration_ms}


@app.post("/chaos/error-inject")
async def chaos_error_inject(rate: int = 30):
    with _chaos_lock:
        _chaos["error_rate"] = max(0, min(100, rate))
    level = "warning" if rate > 0 else "info"
    getattr(logger, level)(json.dumps({"event": "chaos_error_inject", "rate": rate}))
    return {"chaos": "error_inject", "rate": rate}


@app.post("/chaos/reset")
async def chaos_reset():
    with _chaos_lock:
        _chaos["slow_query"] = False
        _chaos["slow_ms"] = 3000
        _chaos["error_rate"] = 0
    logger.info(json.dumps({"event": "chaos_reset"}))
    return {"chaos": "reset", "state": dict(_chaos)}


@app.get("/chaos/state")
async def chaos_state():
    with _chaos_lock:
        return dict(_chaos)


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
