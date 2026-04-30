import os
import json
import time
import uuid
import logging
import threading
import random
from datetime import datetime, timezone, timedelta
from typing import Optional

from fastapi import FastAPI, Query, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pythonjsonlogger import jsonlogger

SERVICE = os.getenv("SERVICE_NAME", "alert-api")
ENVIRONMENT = os.getenv("ENVIRONMENT", "demo-ec2")

logger = logging.getLogger(SERVICE)
_h = logging.StreamHandler()
_h.setFormatter(jsonlogger.JsonFormatter("%(asctime)s %(name)s %(levelname)s %(message)s"))
logger.addHandler(_h)
logger.setLevel(logging.INFO)

app = FastAPI(title="alert-api", version="2.0.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

_alerts_lock = threading.Lock()
_storm_running = False
_storm_thread = None


def _make_initial_alerts():
    now = datetime.now(timezone.utc)
    return [
        {"id": "ALT-001", "device_id": "TKY-EDGE-001", "device_name": "東京エッジルーター1",  "area": "tokyo",   "type": "high_cpu",        "severity": "warning",  "message": "CPU使用率が閾値超過 (現在: 87% / 閾値: 80%)",             "status": "active", "created_at": (now - timedelta(hours=2, minutes=15)).isoformat()},
        {"id": "ALT-002", "device_id": "OSK-L3SW-001", "device_name": "大阪L3スイッチ1",     "area": "osaka",   "type": "high_temperature", "severity": "critical", "message": "筐体温度が閾値超過 (現在: 78°C / 閾値: 70°C)",            "status": "active", "created_at": (now - timedelta(hours=5, minutes=30)).isoformat()},
        {"id": "ALT-003", "device_id": "TKY-AP-002",   "device_name": "東京AP-新宿",         "area": "tokyo",   "type": "unreachable",      "severity": "critical", "message": "PINGに応答なし (タイムアウト: 60秒連続)",                 "status": "active", "created_at": (now - timedelta(hours=1, minutes=45)).isoformat()},
        {"id": "ALT-004", "device_id": "NGY-AP-001",   "device_name": "名古屋AP-名駅",       "area": "nagoya",  "type": "packet_loss",      "severity": "warning",  "message": "パケットロス率が閾値超過 (現在: 12.3% / 閾値: 5%)",        "status": "active", "created_at": (now - timedelta(minutes=45)).isoformat()},
        {"id": "ALT-005", "device_id": "OSK-AP-002",   "device_name": "大阪AP-なんば",       "area": "osaka",   "type": "high_latency",     "severity": "warning",  "message": "レイテンシスパイク検出 (avg: 450ms / 閾値: 100ms)",        "status": "active", "created_at": (now - timedelta(minutes=20)).isoformat()},
        {"id": "ALT-006", "device_id": "FUK-EDGE-001", "device_name": "福岡エッジルーター1",  "area": "fukuoka", "type": "link_down",        "severity": "critical", "message": "インターフェース ge-0/0/0 リンクダウン",                  "status": "active", "created_at": (now - timedelta(hours=3)).isoformat()},
        {"id": "ALT-007", "device_id": "TKY-L2SW-002", "device_name": "東京L2スイッチ2",    "area": "tokyo",   "type": "maintenance",      "severity": "info",     "message": "定期メンテナンス中 (予定: 09:00-11:00 JST)",             "status": "active", "created_at": (now - timedelta(hours=8)).isoformat()},
    ]


_alerts = _make_initial_alerts()

STORM_TYPES = [
    ("high_cpu",        "warning",  "CPU使用率急上昇"),
    ("memory_exhausted","critical", "メモリ枯渇"),
    ("link_flapping",   "warning",  "インターフェースフラッピング"),
    ("bgp_session_down","critical", "BGPセッションダウン"),
    ("packet_loss",     "warning",  "パケットロス増加"),
    ("high_temperature","critical", "温度異常"),
    ("snmp_timeout",    "warning",  "SNMPタイムアウト"),
    ("fan_failure",     "critical", "ファン障害"),
]
STORM_DEVICES = [
    ("TKY-CORE-001", "東京コアルーター1",  "tokyo"),
    ("OSK-CORE-001", "大阪コアルーター1",  "osaka"),
    ("NGY-CORE-001", "名古屋コアルーター1","nagoya"),
    ("FUK-CORE-001", "福岡コアルーター1",  "fukuoka"),
    ("TKY-L3SW-001", "東京L3スイッチ1",   "tokyo"),
]


def _storm_worker():
    global _storm_running
    count = 0
    while _storm_running and count < 60:
        dev = random.choice(STORM_DEVICES)
        t = random.choice(STORM_TYPES)
        alert = {
            "id": f"STM-{str(uuid.uuid4())[:8].upper()}",
            "device_id": dev[0], "device_name": dev[1], "area": dev[2],
            "type": t[0], "severity": t[1],
            "message": f"{t[2]}が発生しました (chaos: alert storm)",
            "status": "active",
            "created_at": datetime.now(timezone.utc).isoformat(),
        }
        with _alerts_lock:
            _alerts.insert(0, alert)
        logger.error(json.dumps({"event": "alert_storm", "alert_id": alert["id"],
                                 "device_id": dev[0], "type": t[0], "severity": t[1]}))
        count += 1
        time.sleep(0.3)
    _storm_running = False


@app.on_event("startup")
async def startup():
    logger.info(json.dumps({"event": "startup", "service": SERVICE, "alerts": len(_alerts)}))


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVICE}


@app.get("/alerts")
async def list_alerts(
    severity: Optional[str] = Query(None),
    area: Optional[str] = Query(None),
    status: Optional[str] = Query(None),
):
    start = time.time()
    with _alerts_lock:
        result = list(_alerts)

    if severity: result = [a for a in result if a["severity"] == severity]
    if area:     result = [a for a in result if a.get("area") == area]
    if status:   result = [a for a in result if a["status"] == status]
    result.sort(key=lambda x: x["created_at"], reverse=True)

    duration_ms = int((time.time() - start) * 1000)
    logger.info(json.dumps({"event": "list_alerts", "count": len(result),
                            "filters": {"severity": severity, "area": area, "status": status},
                            "duration_ms": duration_ms}))
    return {"alerts": result, "total": len(result)}


@app.get("/alerts/summary")
async def alert_summary():
    with _alerts_lock:
        active = [a for a in _alerts if a["status"] == "active"]
    return {
        "total_active": len(active),
        "critical": sum(1 for a in active if a["severity"] == "critical"),
        "warning":  sum(1 for a in active if a["severity"] == "warning"),
        "info":     sum(1 for a in active if a["severity"] == "info"),
    }


@app.post("/alerts/{alert_id}/resolve")
async def resolve_alert(alert_id: str):
    with _alerts_lock:
        for a in _alerts:
            if a["id"] == alert_id:
                a["status"] = "resolved"
                a["resolved_at"] = datetime.now(timezone.utc).isoformat()
                logger.info(json.dumps({"event": "alert_resolved", "alert_id": alert_id, "device_id": a["device_id"]}))
                return {"status": "resolved", "alert": a}
    raise HTTPException(status_code=404, detail="Alert not found")


# ── Chaos control ────────────────────────────────────────────

@app.post("/chaos/alert-storm")
async def chaos_alert_storm(enable: bool = True):
    global _storm_running, _storm_thread
    if enable and not _storm_running:
        _storm_running = True
        _storm_thread = threading.Thread(target=_storm_worker, daemon=True)
        _storm_thread.start()
        logger.warning(json.dumps({"event": "chaos_alert_storm_start"}))
        return {"chaos": "alert_storm", "enabled": True}
    elif not enable:
        _storm_running = False
        logger.info(json.dumps({"event": "chaos_alert_storm_stop"}))
        return {"chaos": "alert_storm", "enabled": False}
    return {"chaos": "alert_storm", "already_running": True}


@app.post("/chaos/reset")
async def chaos_reset():
    global _storm_running
    _storm_running = False
    with _alerts_lock:
        _alerts.clear()
        _alerts.extend(_make_initial_alerts())
    logger.info(json.dumps({"event": "chaos_reset", "alerts_restored": len(_alerts)}))
    return {"chaos": "reset"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
