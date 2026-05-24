# Cloud-Based MT5-to-MT5 Trade Copier — Complete Manual

> **Version:** 2.00 &nbsp;|&nbsp; **Components:** `Master (Signal Sender).mq5` · `Slave (Signal Receiver).mq5` · `Server.py`

---

## Table of Contents

1. [System Overview](#1-system-overview)
2. [How It Works](#2-how-it-works)
3. [Requirements](#3-requirements)
4. [Component 1 — Cloud Server Setup](#4-component-1--cloud-server-setup)
5. [Component 2 — Master EA Setup](#5-component-2--master-ea-setup)
6. [Component 3 — Slave EA Setup](#6-component-3--slave-ea-setup)
7. [Input Parameters Reference](#7-input-parameters-reference)
8. [Symbol Mapping (Broker Differences)](#8-symbol-mapping-broker-differences)
9. [How Trades Are Matched (CLOSE & MODIFY)](#9-how-trades-are-matched-close--modify)
10. [Troubleshooting](#10-troubleshooting)
11. [FAQ](#11-faq)

---

## 1. System Overview

This system copies trades in real-time from one MetaTrader 5 account (the **Master**) to one or more MetaTrader 5 accounts (the **Slave**) through a central cloud server.

```
┌─────────────────┐         HTTP POST          ┌──────────────────────┐
│                 │ ─────────────────────────> │                      │
│   MASTER MT5    │                            │   CLOUD SERVER       │
│  (any broker)   │   /api/signals (JSON)      │   (FastAPI + Python) │
│                 │                            │                      │
└─────────────────┘                            └──────────────────────┘
                                                          │
                                                          │  HTTP GET (polling)
                                                          │  every 1 second
                                                          ▼
                                               ┌──────────────────────┐
                                               │                      │
                                               │   SLAVE MT5          │
                                               │  (any broker)        │
                                               │                      │
                                               └──────────────────────┘
```

**Key advantages:**
- Works across **different brokers** and **different geographic locations**
- The Master and Slave never connect to each other directly — all traffic goes through your server
- The server can relay to **multiple Slave accounts** simultaneously
- No need for both terminals to be on the same PC or network

---

## 2. How It Works

### Trade OPEN flow

```
1. Master trader manually opens a trade (BUY/SELL)
2. MT5 fires OnTradeTransaction() event in the Master EA
3. Master EA reads: symbol, type, volume, SL, TP, magic, comment
4. Master EA sends an HTTP POST to the server with a JSON payload
5. Server stores the signal in its pending queue
6. Slave EA polls the server every 1 second (GET request)
7. Server returns the pending signal and marks it as "retrieved"
8. Slave EA parses the JSON and executes the same trade on its account
9. Slave EA logs: master ticket, slave ticket, price, volume
```

### Trade CLOSE flow

```
1. Master trader closes a trade
2. MT5 fires OnTradeTransaction() with DEAL_ENTRY_OUT
3. Master EA detects this via its known-ticket list and sends CLOSE signal
4. Server queues the CLOSE signal
5. Slave EA polls → receives CLOSE signal
6. Slave EA finds the matching position using its ticket map
   (if not found by map, searches by comment tag "MasterT:<ticket>")
7. Slave EA closes the matching position
```

### Trade MODIFY flow (SL/TP change)

```
1. Master trader modifies SL or TP on an open position
2. MT5 fires OnTradeTransaction() with TRADE_TRANSACTION_POSITION
3. Master EA compares new SL/TP against its saved snapshot
4. If changed → sends MODIFY signal to server
5. Server queues the MODIFY signal
6. Slave EA receives it → finds matching position → updates SL/TP
```

### Duplicate-prevention mechanism

- **Master EA** keeps a list of known open tickets (`g_knownTickets[]`). On startup it snapshots all currently-open positions so re-attaching the EA never re-sends old trades.
- **Server** marks each signal as `retrieved=true` the moment the Slave fetches it. The next poll returns an empty array — no duplicate execution.
- **Slave EA** maintains a `g_processedTickets[]` list. Even if the same signal somehow arrives twice, the Slave skips it.

---

## 3. Requirements

### Cloud Server
| Item | Requirement |
|---|---|
| Operating System | Any Linux/Windows VPS or cloud VM |
| Python | 3.9 or newer |
| Python packages | `fastapi`, `uvicorn[standard]`, `pydantic` |
| Open port | **8000** (TCP inbound) must be allowed in firewall |
| Public IP | Required so both MT5 terminals can reach it |

### Master MT5
| Item | Requirement |
|---|---|
| MT5 Build | Any recent build |
| EA file | `Master (Signal Sender).mq5` compiled |
| WebRequest | Must be enabled for your server URL |
| Internet access | Required |

### Slave MT5
| Item | Requirement |
|---|---|
| MT5 Build | Any recent build |
| EA file | `Slave (Signal Receiver).mq5` compiled |
| WebRequest | Must be enabled for your server URL |
| Internet access | Required |

---

## 4. Component 1 — Cloud Server Setup

### Step 1 — Install Python dependencies

Open a terminal/command prompt on your VPS and run:

```bash
pip install fastapi "uvicorn[standard]" pydantic
```

### Step 2 — Upload Server.py

Copy `Server.py` to your VPS. It can go anywhere, for example:

```
/home/user/trade_copier/Server.py
```

### Step 3 — Open firewall port

On your VPS, allow inbound TCP traffic on port **8000**:

```bash
# Ubuntu / Debian (ufw)
sudo ufw allow 8000/tcp

# CentOS / RHEL (firewalld)
sudo firewall-cmd --permanent --add-port=8000/tcp
sudo firewall-cmd --reload

# AWS Security Group / Azure NSG
# Add inbound rule: TCP port 8000, source 0.0.0.0/0
```

### Step 4 — Start the server

```bash
# Standard start (run from the same folder as Server.py)
python Server.py

# OR with uvicorn directly (recommended for production)
uvicorn server:app --host 0.0.0.0 --port 8000

# OR with multiple workers for heavier load
uvicorn server:app --host 0.0.0.0 --port 8000 --workers 4
```

You should see:

```
==================================================
  MT5 Trade Copier Cloud Server — Starting
==================================================
  POST   /api/signals        Master EA → sends signal
  GET    /api/signals        Slave EA  ← polls signals
  ...
INFO:     Uvicorn running on http://0.0.0.0:8000
```

### Step 5 — Verify the server is running

Open a browser or run:

```bash
curl http://YOUR_SERVER_IP:8000/health
```

Expected response:

```json
{"status":"healthy","pending_signals":0,"total_signals":0,"server_time":"..."}
```

You can also view the **interactive API documentation** at:
```
http://YOUR_SERVER_IP:8000/docs
```

### Step 6 — Keep server running (optional but recommended)

Use `systemd` (Linux) to auto-start on reboot:

```ini
# /etc/systemd/system/trade-copier.service
[Unit]
Description=MT5 Trade Copier Server
After=network.target

[Service]
User=ubuntu
WorkingDirectory=/home/ubuntu/trade_copier
ExecStart=/usr/bin/python3 /home/ubuntu/trade_copier/Server.py
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable trade-copier
sudo systemctl start trade-copier
sudo systemctl status trade-copier
```

---

## 5. Component 2 — Master EA Setup

### Step 1 — Compile the EA

1. Open **MetaEditor** (press `F4` in MT5, or go to **Tools → MetaQuotes Language Editor**)
2. Open `Master (Signal Sender).mq5`
3. Press `F7` to compile
4. Confirm: **0 errors, 0 warnings** in the Errors tab

### Step 2 — Allow WebRequest

> [!IMPORTANT]
> This step is mandatory. Without it, the EA cannot send HTTP requests.

1. In MT5, go to **Tools → Options → Expert Advisors**
2. Check **"Allow WebRequest for listed URL"**
3. Click the **`+`** button and add your server URL:
   ```
   http://YOUR_SERVER_IP:8000
   ```
   *(Use the base URL only — no path, no trailing slash)*
4. Click **OK**

### Step 3 — Attach the EA to a chart

1. In MT5, drag `Master (Signal Sender)` from the **Navigator** panel onto **any chart**
   - Recommended: attach to a chart that is always open (e.g., EURUSD M1 or any index)
   - The EA does not need to be on the same chart as the traded instruments — it monitors the whole account
2. A settings dialog will appear

### Step 4 — Configure EA inputs

In the **Inputs** tab of the EA settings:

| Input | What to enter |
|---|---|
| **ServerURL** | `http://YOUR_SERVER_IP:8000/api/signals` *(replace YOUR_SERVER_IP)* |
| **RequestTimeoutMs** | Leave at `5000` (5 seconds) |
| **MasterMagicNumber** | `0` to copy ALL trades, or enter a specific magic number to filter |
| **SkipCommentedTrades** | `false` (set `true` to ignore trades already tagged "CloudCopy") |

### Step 5 — Enable AutoTrading

Click the **AutoTrading** button in the MT5 toolbar (it turns green when active).

### Step 6 — Verify in the Experts tab

Open the **Journal** tab (or **Experts** tab) at the bottom of MT5. You should see:

```
[MASTER] Cloud Trade Copier - Master EA v2.00 starting...
[MASTER] Server URL : http://YOUR_SERVER_IP:8000/api/signals
[MASTER] Magic filter: ALL trades
[MASTER] Initialization complete. Monitoring 2 existing positions.
```

If you see `Initialization complete` — the Master EA is running correctly.

### Step 7 — Test with a trade

Open a small test trade (e.g., 0.01 lot). You should see in the Experts log:

```
[MASTER] ✓ Signal sent | Action:OPEN | Ticket:12345678 | Symbol:EURUSD | Type:BUY | Vol:0.01 | Response:{"status":"success",...}
```

---

## 6. Component 3 — Slave EA Setup

### Step 1 — Compile the EA

1. Open **MetaEditor** in the **Slave** MT5 terminal
2. Open `Slave (Signal Receiver).mq5`
3. Press `F7` to compile
4. Confirm: **0 errors, 0 warnings**

### Step 2 — Allow WebRequest (same as Master)

1. **Tools → Options → Expert Advisors**
2. Check **"Allow WebRequest for listed URL"**
3. Add: `http://YOUR_SERVER_IP:8000`
4. Click **OK**

### Step 3 — Attach the EA to a chart

1. Drag `Slave (Signal Receiver)` onto **any chart** in the Slave MT5 terminal
2. A settings dialog will appear

### Step 4 — Configure EA inputs

| Input | What to enter |
|---|---|
| **ServerURL** | `http://YOUR_SERVER_IP:8000/api/signals` |
| **CheckIntervalSeconds** | `1` (polls every 1 second — recommended) |
| **RequestTimeoutMs** | `4000` (4 seconds — leave default) |
| **SymbolPrefix** | See [Symbol Mapping](#8-symbol-mapping-broker-differences) below |
| **SymbolSuffix** | See [Symbol Mapping](#8-symbol-mapping-broker-differences) below |
| **SlaveMagicNumber** | `999999` — any unique number. Do **not** use the same as the Master |
| **MaxSlippage** | `30` points (increase if you get frequent slippage rejections) |
| **LotMultiplier** | `1.0` = same size as master. `0.5` = half size. `2.0` = double size |
| **MirrorStopLoss** | `true` = copy SL from master |
| **MirrorTakeProfit** | `true` = copy TP from master |
| **CloseOnMasterClose** | `true` = close slave trade when master closes |
| **UseFixedLot** | `true` = use volume from master × LotMultiplier |
| **FixedLotSize** | `0.0` = auto (uses master volume). Set a number to force a fixed lot |
| **UseRiskPercent** | `false` = off. `true` = calculate lot by risk % of account balance |
| **RiskPercent** | Only used if `UseRiskPercent=true`. E.g. `1.0` = risk 1% per trade |

### Step 5 — Enable AutoTrading

Click the **AutoTrading** button (must be green).

### Step 6 — Verify in Experts tab

You should see:

```
[SLAVE] Cloud Trade Copier - Slave EA v2.00 starting...
[SLAVE] Server URL : http://YOUR_SERVER_IP:8000/api/signals
[SLAVE] Poll interval: 1 second(s)
[SLAVE] Symbol mapping: '' + <symbol> + ''
[SLAVE] Slave magic: 999999
[SLAVE] Initialization complete. Timer started.
```

When a Master trade is copied, you will see:

```
[SLAVE] Signal | Action:OPEN | Ticket:12345678 | Symbol:EURUSD | Type:BUY | Vol:0.01
[SLAVE] ✓ OPEN SUCCESS | MasterTicket:12345678 | SlaveOrder:87654321 | Symbol:EURUSD | ...
```

---

## 7. Input Parameters Reference

### Master EA — Full Parameter List

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ServerURL` | string | `http://YOUR_SERVER_IP:8000/api/signals` | Full URL of the FastAPI `/api/signals` endpoint |
| `RequestTimeoutMs` | int | `5000` | Max milliseconds to wait for server response |
| `MasterMagicNumber` | long | `0` | `0` = copy all trades regardless of magic number. Any other value = only copy trades with that exact magic number |
| `SkipCommentedTrades` | bool | `false` | If `true`, trades with "CloudCopy" in their comment are ignored (prevents infinite loop if slave and master are on same terminal) |

### Slave EA — Full Parameter List

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ServerURL` | string | `http://YOUR_SERVER_IP:8000/api/signals` | Full URL of the FastAPI `/api/signals` endpoint |
| `CheckIntervalSeconds` | int | `1` | How often (in seconds) the Slave polls the server |
| `RequestTimeoutMs` | int | `4000` | Max milliseconds to wait for server GET response |
| `SymbolPrefix` | string | `""` | Text prepended to the master symbol. E.g. `"m."` turns `EURUSD` into `m.EURUSD` |
| `SymbolSuffix` | string | `""` | Text appended to the master symbol. E.g. `".r"` turns `EURUSD` into `EURUSD.r` |
| `SlaveMagicNumber` | long | `999999` | Magic number applied to all trades opened by the Slave |
| `MaxSlippage` | int | `30` | Maximum acceptable slippage in **points** |
| `LotMultiplier` | double | `1.0` | Multiply master volume by this. `1.0` = identical size |
| `MirrorStopLoss` | bool | `true` | Copy the master's SL price to the slave trade |
| `MirrorTakeProfit` | bool | `true` | Copy the master's TP price to the slave trade |
| `CloseOnMasterClose` | bool | `true` | Automatically close slave trade when master closes |
| `UseFixedLot` | bool | `true` | If `true` and `FixedLotSize > 0`, use that exact lot size |
| `FixedLotSize` | double | `0.0` | Exact lot size for slave trades. `0.0` = use master volume × `LotMultiplier` |
| `UseRiskPercent` | bool | `false` | If `true`, ignore master volume and calculate lot by risk % |
| `RiskPercent` | double | `1.0` | Percentage of account balance to risk per trade (only when `UseRiskPercent=true`) |

---

## 8. Symbol Mapping (Broker Differences)

Different brokers display the same instrument with different names. Examples:

| Master broker symbol | Slave broker symbol | SymbolPrefix | SymbolSuffix |
|---|---|---|---|
| `EURUSD` | `EURUSD` | *(leave empty)* | *(leave empty)* |
| `EURUSD` | `EURUSD.r` | *(leave empty)* | `.r` |
| `EURUSD` | `EURUSD.m` | *(leave empty)* | `.m` |
| `EURUSD` | `m.EURUSD` | `m.` | *(leave empty)* |
| `XAUUSD` | `GOLD` | *(cannot map — must be identical)* | — |

> [!WARNING]
> Symbol mapping only handles **prefix/suffix**. If the symbol names are completely different (e.g., `XAUUSD` vs `GOLD`), the automated mapping won't work. In that case you must ensure both brokers use the same symbol name, or modify the EA.

**How to find your broker's symbol name:**
1. Open **Market Watch** in MT5 (Ctrl+M)
2. Right-click → **Show All**
3. The symbol name shown is exactly what you need

---

## 9. How Trades Are Matched (CLOSE & MODIFY)

The Slave EA uses a **two-strategy** approach to find which slave position corresponds to a master CLOSE or MODIFY signal:

### Strategy 1: Ticket Map (Primary — most reliable)
When the Slave opens a trade successfully, it stores the mapping:
```
MasterTicket  →  SlaveOrderTicket
  12345678    →    87654321
```
On CLOSE or MODIFY, it looks up this map and acts directly on the slave ticket.

### Strategy 2: Comment Search (Fallback)
Every trade opened by the Slave is tagged with a comment:
```
MasterT:12345678
```
If the ticket map lookup fails (e.g., EA was restarted), the Slave scans all open positions for a matching comment tag.

> [!TIP]
> The ticket map is stored in memory. If the Slave EA is detached and re-attached while positions are open, Strategy 2 (comment search) will handle CLOSE and MODIFY correctly.

---

## 10. Troubleshooting

### ❌ Master EA: "WebRequest error" / HTTP code -1

**Cause:** WebRequest is not allowed for the server URL.

**Fix:**
1. In the **Master** MT5: **Tools → Options → Expert Advisors**
2. Tick **"Allow WebRequest for listed URL"**
3. Add `http://YOUR_SERVER_IP:8000` (no path, no trailing slash)
4. Restart the EA

---

### ❌ Master EA: HTTP code 0 / No response

**Cause:** Server is not reachable (not running, wrong IP, firewall blocking port 8000).

**Fix:**
1. Verify the server is running: `curl http://YOUR_SERVER_IP:8000/health`
2. Check firewall: `sudo ufw status` or cloud security group rules
3. Confirm port 8000 is open inbound
4. Double-check the IP address in `ServerURL`

---

### ❌ Master EA: HTTP code 422

**Cause:** The JSON payload was rejected by the server (validation error). Usually happens with CLOSE signals where `type` is empty.

**Fix:** This is handled internally — CLOSE signals are allowed to have empty `type`. If you see this, check the server log for the detailed validation error message.

---

### ❌ Slave EA: "Symbol 'EURUSD.m' not found"

**Cause:** The mapped symbol doesn't exist on the slave broker.

**Fix:**
1. Open Market Watch on the Slave MT5
2. Find the exact symbol name your broker uses
3. Adjust `SymbolPrefix` / `SymbolSuffix` inputs accordingly
4. Re-attach the Slave EA

---

### ❌ Slave EA: OPEN FAILED — Retcode: 10014 (TRADE_RETCODE_INVALID_FILL)

**Cause:** The order filling mode `ORDER_FILLING_FOK` is not supported by the broker.

**Fix:** The EA uses `FOK` by default. Try changing `trade.SetTypeFilling(ORDER_FILLING_IOC)` or `ORDER_FILLING_RETURN` in the EA code and recompile.

---

### ❌ Slave EA: OPEN FAILED — Retcode: 10019 (TRADE_RETCODE_NO_MONEY)

**Cause:** Insufficient margin on the slave account.

**Fix:**
- Reduce `LotMultiplier` (e.g., `0.1` or `0.01`)
- Or enable `UseFixedLot=true` and set a small `FixedLotSize`
- Or enable `UseRiskPercent=true` with a low `RiskPercent`

---

### ❌ Server.py: "Could not import module 'server'"

**Cause:** Running `python Server.py` from a different directory with the string form in `uvicorn.run()`.

**Fix:** Already corrected in v2.00 — `uvicorn.run(app, ...)` is used instead of the string form.

---

### ❌ Slave copies a trade twice

**Cause:** `g_processedTickets[]` is cleared when the EA is restarted. If the server still has a retrieved signal for the same ticket and somehow returns it again, a duplicate may occur.

**Fix:** The server marks signals as `retrieved` atomically and never returns them again after the first GET. If you see duplicates, check that only **one** Slave EA instance is running for the same account.

---

### ❌ Slave does not close when master closes

**Cause 1:** `CloseOnMasterClose` is set to `false`.  
**Fix:** Set it to `true` in the EA inputs.

**Cause 2:** The Slave EA was restarted and lost its ticket map, AND the trade comment was manually edited (removing the `MasterT:` tag).  
**Fix:** Do not manually edit comments on slave trades. The fallback comment search requires the `MasterT:<ticket>` tag to be intact.

---

## 11. FAQ

**Q: Can I have multiple Slave accounts copying from one Master?**  
A: Yes. Simply attach the Slave EA on as many MT5 terminals as you want. They all poll the same server URL. Each Slave gets its own copy of every signal since the server marks signals retrieved per-request — and each Slave independently tracks its own processed tickets.

**Q: What happens if the server goes down temporarily?**  
A: The Master EA will log HTTP errors but keep running. When the server comes back up, new trades will be sent. Trades that opened during the downtime will **not** be retroactively sent (they were missed). Close and Modify signals for those trades may also be missed.

**Q: Does the Master EA need to be on the same chart as the traded symbol?**  
A: No. Attach it to any chart (e.g., EURUSD M1). It monitors all positions on the account regardless of which chart you attach it to.

**Q: What if my Slave broker has a different number of decimal places?**  
A: The SL and TP values are copied as exact price levels (not pips). The Slave EA normalizes them with `NormalizeDouble()` using the slave symbol's digit count. This works correctly as long as both brokers trade the same underlying instrument.

**Q: Is the communication encrypted?**  
A: The current setup uses plain HTTP. For production use, it is strongly recommended to:  
1. Put the server behind **Nginx** or **Caddy** with an SSL certificate (HTTPS)
2. Add an **API key** header check in `server.py` for authentication
3. Restrict the server firewall to only allow the Master and Slave IP addresses

**Q: How do I run multiple Slave EAs on the same MT5 terminal?**  
A: Attach the Slave EA to **different charts** (different symbols or timeframes). Each instance will independently process signals. Be careful — they will each open a trade for every signal, resulting in doubled positions. Use `SlaveMagicNumber` values to differentiate them, and consider using `FixedLotSize` to control the size.

**Q: What is the minimum latency / copy speed?**  
A: The theoretical minimum is `CheckIntervalSeconds` (default: 1 second) plus network latency. In practice, most trades are copied within **1–3 seconds** of the master opening them.

---

*End of Manual — Cloud Trade Copier v2.00*
