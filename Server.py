#+------------------------------------------------------------------+
#|  server.py                                                       |
#|  FastAPI Cloud Server for MT5-to-MT5 Trade Copier               |
#|  Component 2: Cloud Relay Server                                 |
#+------------------------------------------------------------------+
#
# REQUIREMENTS:
#   pip install fastapi uvicorn[standard] pydantic
#
# RUN (development):
#   uvicorn server:app --host 0.0.0.0 --port 8000 --reload
#
# RUN (production, multi-worker):
#   uvicorn server:app --host 0.0.0.0 --port 8000 --workers 4
#
# API ENDPOINTS:
#   POST   /api/signals        - Master EA sends a new trade signal
#   GET    /api/signals        - Slave EA polls for pending signals
#   DELETE /api/signals        - Admin: clear all queued signals
#   GET    /api/signals/{id}   - Admin: get a specific signal by ID
#   GET    /health             - Health check
#   GET    /stats              - Queue statistics
#+------------------------------------------------------------------+

from __future__ import annotations

import asyncio
import logging
import sys
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Dict, List, Optional

from fastapi import FastAPI, HTTPException, Path, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(name)s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
    ],
)
logger = logging.getLogger("trade_copier")


# ---------------------------------------------------------------------------
# Pydantic data models
# ---------------------------------------------------------------------------

class TradeSignal(BaseModel):
    """Trade signal sent by the Master EA and consumed by the Slave EA."""

    action:  str   = Field(...,  description="OPEN | CLOSE | MODIFY")
    ticket:  int   = Field(...,  description="Master position ticket/ID", gt=0)
    symbol:  str   = Field(...,  description="Trading symbol, e.g. EURUSD")
    type:    Optional[str] = Field(None, description="BUY | SELL (required for OPEN/MODIFY)")
    volume:  float = Field(0.0,  description="Trade volume in lots", ge=0.0)
    sl:      float = Field(0.0,  description="Stop Loss price")
    tp:      float = Field(0.0,  description="Take Profit price")
    magic:   int   = Field(0,    description="EA magic number")
    comment: str   = Field("",   description="Trade comment")

    @field_validator("action")
    @classmethod
    def validate_action(cls, v: str) -> str:
        v = v.upper().strip()
        if v not in ("OPEN", "CLOSE", "MODIFY"):
            raise ValueError(f"action must be OPEN, CLOSE, or MODIFY — got '{v}'")
        return v

    @field_validator("type")
    @classmethod
    def validate_type(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return v
        v = v.upper().strip()
        if v not in ("BUY", "SELL"):
            raise ValueError(f"type must be BUY or SELL — got '{v}'")
        return v

    @field_validator("symbol")
    @classmethod
    def validate_symbol(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("symbol cannot be empty")
        return v


class StoredSignal(TradeSignal):
    """Internal model with server-assigned metadata."""

    id:         int      = Field(..., description="Server-assigned sequential ID")
    received_at: datetime = Field(..., description="UTC timestamp when signal arrived")
    retrieved:  bool     = Field(False, description="Whether the Slave EA has fetched this signal")


class PostResponse(BaseModel):
    status:    str
    message:   str
    signal_id: int


class HealthResponse(BaseModel):
    status:         str
    pending_signals: int
    total_signals:  int
    server_time:    str


class StatsResponse(BaseModel):
    total_signals:     int
    pending_signals:   int
    retrieved_signals: int
    oldest_pending_age_s: Optional[float]


# ---------------------------------------------------------------------------
# Thread-safe (asyncio-safe) signal storage
# ---------------------------------------------------------------------------

class SignalStore:
    """
    In-memory signal queue protected by an asyncio.Lock.

    Design decisions:
    - Uses a dict keyed by signal ID for O(1) lookups.
    - The lock is an asyncio.Lock (not threading.Lock) because FastAPI runs
      in an asyncio event loop. threading.Lock would block the event loop.
    - Signals are marked 'retrieved' (not deleted) on first GET, so admin
      endpoints can inspect them. A background cleanup task removes old ones.
    """

    def __init__(self) -> None:
        self._store: Dict[int, StoredSignal] = {}
        self._lock  = asyncio.Lock()
        self._next_id = 1

    # ------------------------------------------------------------------
    # Write operations
    # ------------------------------------------------------------------

    async def add(self, signal: TradeSignal) -> StoredSignal:
        async with self._lock:
            sig_id = self._next_id
            self._next_id += 1
            stored = StoredSignal(
                id          = sig_id,
                received_at = datetime.now(timezone.utc),
                retrieved   = False,
                **signal.model_dump(),
            )
            self._store[sig_id] = stored
            logger.info(
                "[STORE]  id=%-5d  action=%-6s  symbol=%-10s  ticket=%s",
                sig_id, stored.action, stored.symbol, stored.ticket,
            )
            return stored

    async def mark_retrieved(self, sig_id: int) -> None:
        async with self._lock:
            if sig_id in self._store:
                self._store[sig_id].retrieved = True

    async def clear_all(self) -> int:
        async with self._lock:
            count = len(self._store)
            self._store.clear()
            return count

    async def delete_one(self, sig_id: int) -> bool:
        async with self._lock:
            if sig_id in self._store:
                del self._store[sig_id]
                return True
            return False

    # ------------------------------------------------------------------
    # Read operations
    # ------------------------------------------------------------------

    async def get_pending(self) -> List[StoredSignal]:
        """Return all un-retrieved signals and mark them as retrieved atomically."""
        async with self._lock:
            pending = [s for s in self._store.values() if not s.retrieved]
            for s in pending:
                s.retrieved = True
                logger.info(
                    "[DISPATCH] id=%-5d  action=%-6s  symbol=%-10s  ticket=%s",
                    s.id, s.action, s.symbol, s.ticket,
                )
            return list(pending)

    async def get_by_id(self, sig_id: int) -> Optional[StoredSignal]:
        async with self._lock:
            return self._store.get(sig_id)

    async def stats(self) -> dict:
        async with self._lock:
            total     = len(self._store)
            pending   = sum(1 for s in self._store.values() if not s.retrieved)
            retrieved = total - pending
            oldest_age: Optional[float] = None
            if pending > 0:
                now = datetime.now(timezone.utc)
                ages = [
                    (now - s.received_at).total_seconds()
                    for s in self._store.values()
                    if not s.retrieved
                ]
                oldest_age = max(ages)
            return {
                "total":    total,
                "pending":  pending,
                "retrieved": retrieved,
                "oldest_pending_age_s": oldest_age,
            }

    # ------------------------------------------------------------------
    # Maintenance
    # ------------------------------------------------------------------

    async def cleanup_expired(self, max_age_seconds: int = 3600) -> int:
        """Remove signals older than max_age_seconds that have been retrieved."""
        now = datetime.now(timezone.utc)
        async with self._lock:
            expired_ids = [
                sig_id for sig_id, s in self._store.items()
                if s.retrieved and (now - s.received_at).total_seconds() > max_age_seconds
            ]
            for sig_id in expired_ids:
                del self._store[sig_id]
            if expired_ids:
                logger.info("[CLEANUP] Removed %d expired signal(s).", len(expired_ids))
            return len(expired_ids)


# Singleton store instance
store = SignalStore()


# ---------------------------------------------------------------------------
# Background cleanup task
# ---------------------------------------------------------------------------

async def periodic_cleanup(interval_seconds: int = 300, max_age_seconds: int = 3600) -> None:
    """Runs every `interval_seconds` to purge old retrieved signals."""
    while True:
        await asyncio.sleep(interval_seconds)
        try:
            removed = await store.cleanup_expired(max_age_seconds)
            if removed:
                logger.info("[CLEANUP] Periodic cleanup removed %d signal(s).", removed)
        except Exception as exc:
            logger.error("[CLEANUP] Error during cleanup: %s", exc)


# ---------------------------------------------------------------------------
# FastAPI app lifecycle (replaces deprecated @app.on_event)
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: startup and shutdown logic."""
    logger.info("=" * 60)
    logger.info("  MT5 Trade Copier Cloud Server — Starting")
    logger.info("=" * 60)
    logger.info("  POST   /api/signals        Master EA → sends signal")
    logger.info("  GET    /api/signals        Slave EA  ← polls signals")
    logger.info("  DELETE /api/signals        Admin: clear all signals")
    logger.info("  GET    /api/signals/{id}   Admin: inspect a signal")
    logger.info("  GET    /health             Health check")
    logger.info("  GET    /stats              Queue statistics")
    logger.info("  GET    /docs               Swagger UI (auto-generated)")
    logger.info("=" * 60)

    # Start background cleanup task
    cleanup_task = asyncio.create_task(periodic_cleanup(interval_seconds=300, max_age_seconds=3600))

    yield  # Application is running

    # Shutdown
    cleanup_task.cancel()
    try:
        await cleanup_task
    except asyncio.CancelledError:
        pass
    logger.info("MT5 Trade Copier Cloud Server — Shut down cleanly.")


# ---------------------------------------------------------------------------
# FastAPI application
# ---------------------------------------------------------------------------

app = FastAPI(
    title       = "MT5 Trade Copier Cloud Server",
    description = "Relay server for cloud-based MT5-to-MT5 trade copying.\n\n"
                  "**Master EA** sends signals via POST.\n"
                  "**Slave EA** polls signals via GET.\n\n"
                  "Signals are marked as retrieved after the first GET and "
                  "cleaned up automatically after 1 hour.",
    version     = "2.0.0",
    lifespan    = lifespan,
)

# Allow cross-origin requests (useful if you ever add a web dashboard)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["GET", "POST", "DELETE"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get(
    "/",
    response_model=HealthResponse,
    summary="Root / Health Check",
    tags=["Monitoring"],
)
async def root() -> HealthResponse:
    """Quick health check. Returns server status and pending signal count."""
    s = await store.stats()
    return HealthResponse(
        status          = "running",
        pending_signals  = s["pending"],
        total_signals   = s["total"],
        server_time     = datetime.now(timezone.utc).isoformat(),
    )


@app.get(
    "/health",
    response_model=HealthResponse,
    summary="Health Check",
    tags=["Monitoring"],
)
async def health() -> HealthResponse:
    """Detailed health endpoint for uptime monitors."""
    s = await store.stats()
    return HealthResponse(
        status          = "healthy",
        pending_signals  = s["pending"],
        total_signals   = s["total"],
        server_time     = datetime.now(timezone.utc).isoformat(),
    )


@app.get(
    "/stats",
    response_model=StatsResponse,
    summary="Queue Statistics",
    tags=["Monitoring"],
)
async def get_stats() -> StatsResponse:
    """Returns detailed statistics about the signal queue."""
    s = await store.stats()
    return StatsResponse(
        total_signals         = s["total"],
        pending_signals       = s["pending"],
        retrieved_signals     = s["retrieved"],
        oldest_pending_age_s  = s["oldest_pending_age_s"],
    )


@app.post(
    "/api/signals",
    response_model = PostResponse,
    status_code    = status.HTTP_201_CREATED,
    summary        = "Receive signal from Master EA",
    tags           = ["Signals"],
)
async def receive_signal(signal: TradeSignal) -> PostResponse:
    """
    **Master EA → Server**

    Accepts a trade signal and stores it in the pending queue.

    - `action`: OPEN, CLOSE, or MODIFY
    - `ticket`: Master position ticket ID (must be > 0)
    - `symbol`: Trading symbol as it appears on the master broker
    - `type`:   BUY or SELL (required for OPEN/MODIFY; ignored for CLOSE)
    - `volume`: Lot size (required for OPEN)
    - `sl`:     Stop Loss price (0 = no SL)
    - `tp`:     Take Profit price (0 = no TP)
    - `magic`:  EA magic number
    - `comment`:Trade comment
    """
    # Cross-field validation
    if signal.action in ("OPEN", "MODIFY") and not signal.type:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail=f"'type' (BUY/SELL) is required when action='{signal.action}'",
        )
    if signal.action == "OPEN" and signal.volume <= 0:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="'volume' must be > 0 for action='OPEN'",
        )

    stored = await store.add(signal)

    logger.info(
        "[RECEIVED] id=%-5d  ticket=%-10s  action=%-6s  symbol=%-10s  type=%-4s  vol=%.2f",
        stored.id, stored.ticket, stored.action, stored.symbol,
        stored.type or "N/A", stored.volume,
    )

    return PostResponse(
        status    = "success",
        message   = "Signal received and queued",
        signal_id = stored.id,
    )


@app.get(
    "/api/signals",
    summary = "Fetch pending signals (Slave EA polling)",
    tags    = ["Signals"],
)
async def fetch_signals() -> list:
    """
    **Slave EA → Server**

    Returns all pending (not-yet-retrieved) signals as a JSON array.
    Signals are atomically marked as retrieved immediately — so the next
    poll will NOT return the same signals again.

    Returns an empty array `[]` when no signals are pending.
    """
    pending = await store.get_pending()

    if not pending:
        return []

    # Build response — only expose fields the Slave EA needs
    result = [
        {
            "action":  s.action,
            "ticket":  s.ticket,
            "symbol":  s.symbol,
            "type":    s.type,
            "volume":  s.volume,
            "sl":      s.sl,
            "tp":      s.tp,
            "magic":   s.magic,
            "comment": s.comment,
        }
        for s in pending
    ]

    logger.info("[DISPATCH] Sent %d signal(s) to Slave EA.", len(result))
    return result


@app.get(
    "/api/signals/{signal_id}",
    summary = "Inspect a specific signal by ID (admin)",
    tags    = ["Admin"],
)
async def get_signal_by_id(
    signal_id: int = Path(..., gt=0, description="Server-assigned signal ID"),
) -> dict:
    """Admin endpoint to inspect any signal (including retrieved ones) by its server ID."""
    sig = await store.get_by_id(signal_id)
    if sig is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"Signal with id={signal_id} not found (may have been cleaned up).",
        )
    return sig.model_dump(mode="json")


@app.delete(
    "/api/signals",
    summary = "Clear all signals (admin)",
    tags    = ["Admin"],
)
async def clear_signals() -> dict:
    """
    **Admin endpoint** — clears all signals from the queue (retrieved or not).
    Use this to reset state without restarting the server.
    """
    count = await store.clear_all()
    logger.warning("[ADMIN] All %d signal(s) cleared from queue.", count)
    return {"status": "success", "cleared_count": count}


# ---------------------------------------------------------------------------
# Entry point (for running directly: python server.py)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,                     # Pass the app object directly (avoids module-import lookup)
        host      = "0.0.0.0",
        port      = 8000,
        log_level = "info",
        reload    = False,       # Note: reload=True requires the string form "server:app"
    )