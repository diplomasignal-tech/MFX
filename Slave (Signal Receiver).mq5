//+------------------------------------------------------------------+
//|                                  Slave (Signal Receiver).mq5    |
//|                          Cloud-Based MT5-to-MT5 Trade Copier     |
//|                                          Component 3: Slave EA   |
//+------------------------------------------------------------------+
//  SETUP INSTRUCTIONS:
//  1. In MT5 go to: Tools -> Options -> Expert Advisors
//  2. Enable "Allow WebRequest for listed URL"
//  3. Add your server URL (e.g. http://your-server-ip:8000)
//  4. Attach this EA to any chart (e.g. XAUUSD M1)
//+------------------------------------------------------------------+
#property copyright "Cloud Trade Copier"
#property link      ""
#property version   "2.00"
#property strict
#property description "Slave EA: Polls the cloud server and mirrors master trades"

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Server Settings ==="
input string   ServerURL            = "http://YOUR_SERVER_IP:8000/api/signals"; // FastAPI server endpoint
input int      CheckIntervalSeconds = 1;     // Polling interval in seconds (min 1)
input int      RequestTimeoutMs     = 4000;  // HTTP request timeout in milliseconds

input group "=== Symbol Mapping ==="
input string   SymbolPrefix         = "";    // Prefix to add to received symbol, e.g. "m." -> "m.EURUSD"
input string   SymbolSuffix         = "";    // Suffix to add to received symbol, e.g. ".r" -> "EURUSD.r"

input group "=== Trade Execution ==="
input long     SlaveMagicNumber     = 999999; // Unique magic number for all slave trades
input int      MaxSlippage          = 30;     // Maximum allowed slippage in points
input double   LotMultiplier        = 1.0;    // Multiply master volume by this factor
input bool     MirrorStopLoss       = true;   // Copy Stop Loss from master signal
input bool     MirrorTakeProfit     = true;   // Copy Take Profit from master signal
input bool     CloseOnMasterClose   = true;   // Close slave position when master closes

input group "=== Risk Management ==="
input bool     UseFixedLot          = true;   // If false, override with risk-based lot sizing
input double   FixedLotSize         = 0.0;    // 0.0 = use master volume * LotMultiplier
input bool     UseRiskPercent       = false;  // Calculate lot by risk percentage of balance
input double   RiskPercent          = 1.0;    // Risk % of account balance per trade

//+------------------------------------------------------------------+
//| Structures                                                       |
//+------------------------------------------------------------------+

// Parsed trade signal from JSON
struct TradeSignal
{
   string action;   // "OPEN", "CLOSE", "MODIFY"
   ulong  ticket;   // Master ticket (position ID)
   string symbol;   // Raw symbol from master
   string type;     // "BUY" or "SELL"
   double volume;
   double sl;
   double tp;
   long   magic;
   string comment;
   bool   valid;    // Set to false if parsing fails
};

// Maps master ticket -> slave ticket for CLOSE/MODIFY
struct TicketMap
{
   ulong masterTicket;
   ulong slaveTicket;
};

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade    g_trade;
TicketMap g_ticketMap[];        // Master->Slave ticket mapping

// Tracks master tickets already processed in this session to avoid duplicates
ulong     g_processedTickets[];

bool      g_initialized = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("============================================================");
   Print("[SLAVE] Cloud Trade Copier - Slave EA v2.00 starting...");
   Print("[SLAVE] Server URL : ", ServerURL);
   Print("[SLAVE] Poll interval: ", CheckIntervalSeconds, " second(s)");
   Print("[SLAVE] Symbol mapping: '", SymbolPrefix, "' + <symbol> + '", SymbolSuffix, "'");
   Print("[SLAVE] Slave magic: ", SlaveMagicNumber);
   Print("============================================================");

   // Validate URL
   if(StringFind(ServerURL, "YOUR_SERVER_IP") >= 0)
   {
      Alert("[SLAVE] ERROR: Please configure the ServerURL input parameter with your actual server IP/domain.");
      Print("[SLAVE] ERROR: ServerURL still contains placeholder 'YOUR_SERVER_IP'. Update it before using.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // Configure CTrade object
   g_trade.SetDeviationInPoints(MaxSlippage);
   g_trade.SetExpertMagicNumber(SlaveMagicNumber);
   g_trade.SetAsyncMode(false);
   g_trade.SetTypeFilling(ORDER_FILLING_FOK);

   // Start polling timer
   int interval = MathMax(1, CheckIntervalSeconds);
   if(!EventSetTimer(interval))
   {
      Print("[SLAVE] ERROR: Failed to start timer. Reason: ", GetLastError());
      return(INIT_FAILED);
   }

   g_initialized = true;
   Print("[SLAVE] Initialization complete. Timer started.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ArrayFree(g_ticketMap);
   ArrayFree(g_processedTickets);
   Print("[SLAVE] EA deinitialized. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| Timer handler — polls server every CheckIntervalSeconds          |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!g_initialized) return;
   PollServer();
}

//+------------------------------------------------------------------+
//| Poll the FastAPI server for pending signals                      |
//+------------------------------------------------------------------+
void PollServer()
{
   char   resultData[];
   string resultHeaders;

   // Send GET request — note: WebRequest GET uses 8-param signature
   // with NULL for post data and empty char array for body
   char   emptyBody[];
   int httpCode = WebRequest(
      "GET",            // Method
      ServerURL,        // URL
      "",               // Additional headers (none needed for GET)
      RequestTimeoutMs, // Timeout
      emptyBody,        // Empty body for GET
      resultData,       // Response body (out)
      resultHeaders     // Response headers (out)
   );

   if(httpCode == 200)
   {
      if(ArraySize(resultData) == 0) return; // Empty body

      string responseBody = CharArrayToString(resultData, 0, WHOLE_ARRAY, CP_UTF8);
      StringTrimRight(responseBody);
      StringTrimLeft(responseBody);

      // Empty array from server — no signals pending
      if(responseBody == "[]" || responseBody == "") return;

      Print("[SLAVE] Received signals. Parsing response...");
      ProcessSignalsJSON(responseBody);
   }
   else if(httpCode == -1)
   {
      Print("[SLAVE] WebRequest error: ", GetLastError(),
            " — Check Tools→Options→Expert Advisors→Allow WebRequest for: ", ServerURL);
   }
   else if(httpCode == 0)
   {
      // Timeout or no connection — don't spam logs, server may be temporarily unavailable
   }
   else if(httpCode == 404)
   {
      Print("[SLAVE] 404 Not Found — Check server URL: ", ServerURL);
   }
   else if(httpCode == 500)
   {
      Print("[SLAVE] 500 Server Internal Error — Check server logs.");
   }
   else
   {
      Print("[SLAVE] Unexpected HTTP code: ", httpCode);
   }
}

//+------------------------------------------------------------------+
//| Parse the JSON array response and process each signal            |
//|                                                                  |
//| The server returns an array of objects:                          |
//| [{"action":"OPEN","ticket":123,...}, {"action":"CLOSE",...}]     |
//|                                                                  |
//| Strategy: split on top-level object boundaries                   |
//+------------------------------------------------------------------+
void ProcessSignalsJSON(string json)
{
   // Strip outer brackets
   StringTrimRight(json);
   StringTrimLeft(json);
   if(StringGetCharacter(json, 0) == '[')
      json = StringSubstr(json, 1);
   int lastIdx = StringLen(json) - 1;
   if(lastIdx >= 0 && StringGetCharacter(json, lastIdx) == ']')
      json = StringSubstr(json, 0, lastIdx);

   StringTrimRight(json);
   StringTrimLeft(json);
   if(StringLen(json) < 5) return;

   // Split into individual JSON objects using a brace-depth counter
   int depth     = 0;
   int objStart  = -1;
   int totalLen  = StringLen(json);
   int processed = 0;

   for(int i = 0; i < totalLen; i++)
   {
      ushort ch = StringGetCharacter(json, i);

      if(ch == '{')
      {
         if(depth == 0) objStart = i;
         depth++;
      }
      else if(ch == '}')
      {
         depth--;
         if(depth == 0 && objStart >= 0)
         {
            string objStr = StringSubstr(json, objStart, i - objStart + 1);
            TradeSignal sig = ParseSignalObject(objStr);
            if(sig.valid)
            {
               DispatchSignal(sig);
               processed++;
            }
            objStart = -1;
         }
      }
   }

   if(processed > 0)
      Print("[SLAVE] Processed ", processed, " signal(s) from server.");
}

//+------------------------------------------------------------------+
//| Parse a single JSON object into a TradeSignal struct             |
//+------------------------------------------------------------------+
TradeSignal ParseSignalObject(string obj)
{
   TradeSignal sig;
   sig.valid = false;

   sig.action  = JSONExtractString(obj, "action");
   sig.ticket  = (ulong)JSONExtractInteger(obj, "ticket");
   sig.symbol  = JSONExtractString(obj, "symbol");
   sig.type    = JSONExtractString(obj, "type");
   sig.volume  = JSONExtractDouble(obj, "volume");
   sig.sl      = JSONExtractDouble(obj, "sl");
   sig.tp      = JSONExtractDouble(obj, "tp");
   sig.magic   = JSONExtractInteger(obj, "magic");
   sig.comment = JSONExtractString(obj, "comment");

   // Minimal validation
   if(sig.ticket == 0) return sig;
   if(sig.action != "OPEN" && sig.action != "CLOSE" && sig.action != "MODIFY") return sig;
   if((sig.action == "OPEN") && (sig.type != "BUY" && sig.type != "SELL")) return sig;

   sig.valid = true;
   return sig;
}

//+------------------------------------------------------------------+
//| Dispatch a parsed signal to the correct handler                  |
//+------------------------------------------------------------------+
void DispatchSignal(TradeSignal &sig)
{
   // Apply symbol mapping
   string mappedSymbol = SymbolPrefix + sig.symbol + SymbolSuffix;

   Print("[SLAVE] Signal | Action:", sig.action,
         " | Ticket:", sig.ticket,
         " | Symbol:", mappedSymbol,
         " | Type:", sig.type,
         " | Vol:", DoubleToString(sig.volume, 2));

   if(sig.action == "OPEN")
   {
      // Deduplicate: skip if we already processed this master ticket as OPEN
      if(IsProcessed(sig.ticket))
      {
         Print("[SLAVE] Skipping duplicate OPEN for master ticket: ", sig.ticket);
         return;
      }
      ExecuteOpen(sig, mappedSymbol);
   }
   else if(sig.action == "CLOSE")
   {
      if(!CloseOnMasterClose)
      {
         Print("[SLAVE] CloseOnMasterClose=false — ignoring CLOSE for ticket: ", sig.ticket);
         return;
      }
      ExecuteClose(sig, mappedSymbol);
      // Remove from processed list so future re-opens can be tracked
      UnmarkProcessed(sig.ticket);
   }
   else if(sig.action == "MODIFY")
   {
      ExecuteModify(sig, mappedSymbol);
   }
}

//+------------------------------------------------------------------+
//| Execute a BUY or SELL trade                                      |
//+------------------------------------------------------------------+
void ExecuteOpen(TradeSignal &sig, string mappedSymbol)
{
   // Ensure symbol is available in Market Watch
   if(!SymbolSelect(mappedSymbol, true))
   {
      Print("[SLAVE] ERROR: Symbol '", mappedSymbol, "' not found. Cannot open trade.");
      return;
   }

   // Allow market data to refresh
   Sleep(100);

   MqlTick tick;
   if(!SymbolInfoTick(mappedSymbol, tick))
   {
      Print("[SLAVE] ERROR: Cannot get current tick for '", mappedSymbol, "'. Error: ", GetLastError());
      return;
   }

   // Determine entry price and direction
   double price   = (sig.type == "BUY") ? tick.ask : tick.bid;
   int    digits  = (int)SymbolInfoInteger(mappedSymbol, SYMBOL_DIGITS);
   double minStop = SymbolInfoInteger(mappedSymbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(mappedSymbol, SYMBOL_POINT);

   // Calculate final SL/TP
   double finalSL = 0.0;
   double finalTP = 0.0;

   if(MirrorStopLoss && sig.sl > 0.0)
   {
      finalSL = NormalizeDouble(sig.sl, digits);
      // Validate SL distance
      double slDist = MathAbs(price - finalSL);
      if(slDist < minStop)
      {
         Print("[SLAVE] WARNING: SL too close (", DoubleToString(slDist, digits), " < min ", DoubleToString(minStop, digits), "). Setting SL=0.");
         finalSL = 0.0;
      }
   }

   if(MirrorTakeProfit && sig.tp > 0.0)
   {
      finalTP = NormalizeDouble(sig.tp, digits);
      double tpDist = MathAbs(price - finalTP);
      if(tpDist < minStop)
      {
         Print("[SLAVE] WARNING: TP too close (", DoubleToString(tpDist, digits), " < min ", DoubleToString(minStop, digits), "). Setting TP=0.");
         finalTP = 0.0;
      }
   }

   // Calculate final volume
   double finalVolume = CalcFinalVolume(mappedSymbol, sig);

   // Append master ticket to comment for tracking
   string tradeComment = "MasterT:" + IntegerToString(sig.ticket);

   // Execute trade
   bool success = false;
   if(sig.type == "BUY")
      success = g_trade.Buy(finalVolume, mappedSymbol, price, finalSL, finalTP, tradeComment);
   else if(sig.type == "SELL")
      success = g_trade.Sell(finalVolume, mappedSymbol, price, finalSL, finalTP, tradeComment);

   if(success)
   {
      ulong slaveTicket = g_trade.ResultOrder(); // Order ticket
      ulong slaveDeal   = g_trade.ResultDeal();  // Deal ticket

      Print("[SLAVE] ✓ OPEN SUCCESS | MasterTicket:", sig.ticket,
            " | SlaveOrder:", slaveTicket,
            " | Symbol:", mappedSymbol,
            " | Type:", sig.type,
            " | Vol:", DoubleToString(finalVolume, 2),
            " | Price:", DoubleToString(price, digits),
            " | SL:", DoubleToString(finalSL, digits),
            " | TP:", DoubleToString(finalTP, digits));

      // Store the ticket mapping (master ticket -> slave position ticket)
      // The slave position ticket == order ticket for market orders
      StoreTicketMap(sig.ticket, slaveTicket);
      MarkProcessed(sig.ticket);
   }
   else
   {
      uint retcode = g_trade.ResultRetcode();
      string retDesc = g_trade.ResultRetcodeDescription();
      Print("[SLAVE] ✗ OPEN FAILED | MasterTicket:", sig.ticket,
            " | Symbol:", mappedSymbol,
            " | Type:", sig.type,
            " | Retcode:", retcode,
            " | Desc:", retDesc);

      if(retcode == TRADE_RETCODE_INVALID_FILL)
         Print("[SLAVE]   → Try changing order filling mode in EA settings.");
      else if(retcode == TRADE_RETCODE_MARKET_CLOSED)
         Print("[SLAVE]   → Market is closed for '", mappedSymbol, "'.");
      else if(retcode == TRADE_RETCODE_NO_MONEY)
         Print("[SLAVE]   → Insufficient funds. Required margin too high.");
   }
}

//+------------------------------------------------------------------+
//| Close slave position corresponding to master ticket              |
//+------------------------------------------------------------------+
void ExecuteClose(TradeSignal &sig, string mappedSymbol)
{
   bool closedAny = false;

   // --- Strategy 1: Use stored ticket map (most reliable) ----------
   ulong slaveTicket = FindSlaveTicket(sig.ticket);
   if(slaveTicket > 0 && PositionSelectByTicket(slaveTicket))
   {
      if(g_trade.PositionClose(slaveTicket, MaxSlippage))
      {
         Print("[SLAVE] ✓ CLOSE SUCCESS (by ticket map) | MasterTicket:", sig.ticket,
               " | SlaveTicket:", slaveTicket);
         RemoveTicketMap(sig.ticket);
         closedAny = true;
      }
      else
      {
         Print("[SLAVE] ✗ CLOSE FAILED (by ticket map) | MasterTicket:", sig.ticket,
               " | Retcode:", g_trade.ResultRetcode(), " | ", g_trade.ResultRetcodeDescription());
      }
   }

   // --- Strategy 2: Search by comment tag (fallback) ---------------
   if(!closedAny)
   {
      string searchTag = "MasterT:" + IntegerToString(sig.ticket);
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(!PositionSelectByTicket(posTicket)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != SlaveMagicNumber) continue;

         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, searchTag) < 0) continue;

         if(g_trade.PositionClose(posTicket, MaxSlippage))
         {
            Print("[SLAVE] ✓ CLOSE SUCCESS (by comment) | MasterTicket:", sig.ticket,
                  " | SlaveTicket:", posTicket);
            closedAny = true;
         }
         else
         {
            Print("[SLAVE] ✗ CLOSE FAILED (by comment) | MasterTicket:", sig.ticket,
                  " | Retcode:", g_trade.ResultRetcode(), " | ", g_trade.ResultRetcodeDescription());
         }
      }
   }

   if(!closedAny)
      Print("[SLAVE] CLOSE: No matching slave position found for master ticket: ", sig.ticket);
}

//+------------------------------------------------------------------+
//| Modify SL/TP of slave position corresponding to master ticket    |
//+------------------------------------------------------------------+
void ExecuteModify(TradeSignal &sig, string mappedSymbol)
{
   int    digits  = (int)SymbolInfoInteger(mappedSymbol, SYMBOL_DIGITS);
   double newSL   = MirrorStopLoss   ? NormalizeDouble(sig.sl, digits) : -1;
   double newTP   = MirrorTakeProfit ? NormalizeDouble(sig.tp, digits) : -1;
   bool   modifiedAny = false;

   // --- Strategy 1: by ticket map ---
   ulong slaveTicket = FindSlaveTicket(sig.ticket);
   if(slaveTicket > 0 && PositionSelectByTicket(slaveTicket))
   {
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      double applySL = (newSL >= 0) ? newSL : currentSL;
      double applyTP = (newTP >= 0) ? newTP : currentTP;

      if(NormalizeDouble(applySL - currentSL, digits) != 0.0 ||
         NormalizeDouble(applyTP - currentTP, digits) != 0.0)
      {
         if(g_trade.PositionModify(slaveTicket, applySL, applyTP))
         {
            Print("[SLAVE] ✓ MODIFY SUCCESS | MasterTicket:", sig.ticket,
                  " | SlaveTicket:", slaveTicket,
                  " | SL:", DoubleToString(applySL, digits),
                  " | TP:", DoubleToString(applyTP, digits));
            modifiedAny = true;
         }
         else
         {
            Print("[SLAVE] ✗ MODIFY FAILED | MasterTicket:", sig.ticket,
                  " | Retcode:", g_trade.ResultRetcode(), " | ", g_trade.ResultRetcodeDescription());
         }
      }
      else
      {
         Print("[SLAVE] MODIFY: SL/TP unchanged for slave ticket: ", slaveTicket);
         modifiedAny = true; // No change needed, consider it handled
      }
   }

   // --- Strategy 2: by comment tag ---
   if(!modifiedAny)
   {
      string searchTag = "MasterT:" + IntegerToString(sig.ticket);
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong posTicket = PositionGetTicket(i);
         if(!PositionSelectByTicket(posTicket)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != SlaveMagicNumber) continue;

         string comment = PositionGetString(POSITION_COMMENT);
         if(StringFind(comment, searchTag) < 0) continue;

         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);
         double applySL   = (newSL >= 0) ? newSL : currentSL;
         double applyTP   = (newTP >= 0) ? newTP : currentTP;

         if(g_trade.PositionModify(posTicket, applySL, applyTP))
         {
            Print("[SLAVE] ✓ MODIFY SUCCESS (by comment) | MasterTicket:", sig.ticket,
                  " | SlaveTicket:", posTicket);
            modifiedAny = true;
         }
         break;
      }
   }

   if(!modifiedAny)
      Print("[SLAVE] MODIFY: No matching slave position for master ticket: ", sig.ticket);
}

//+------------------------------------------------------------------+
//| Calculate the final trade volume                                 |
//+------------------------------------------------------------------+
double CalcFinalVolume(string symbol, TradeSignal &sig)
{
   double vol = 0.0;

   if(UseRiskPercent && !UseFixedLot)
   {
      // Risk-based lot calculation
      double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
      double riskAmt    = balance * (RiskPercent / 100.0);
      double point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
      double tickVal    = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize   = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      double lotStep    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

      // Use a default 100-pip stop if master SL is 0
      double stopPoints = (sig.sl > 0) ? (MathAbs(sig.tp > 0 ? sig.tp - sig.sl : 100) / point) : 100.0;
      if(stopPoints < 1) stopPoints = 100;

      double valuePerPoint = tickVal * (point / tickSize);
      vol = riskAmt / (stopPoints * valuePerPoint);
      vol = MathFloor(vol / lotStep) * lotStep;
   }
   else if(!UseFixedLot || FixedLotSize <= 0.0)
   {
      vol = sig.volume * LotMultiplier;
   }
   else
   {
      vol = FixedLotSize;
   }

   // Clamp to broker limits
   double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   vol = NormalizeDouble(MathFloor(vol / lotStep) * lotStep, 2);
   if(vol < minLot) vol = minLot;
   if(vol > maxLot) vol = maxLot;

   return vol;
}

//+------------------------------------------------------------------+
//| Ticket map management                                            |
//+------------------------------------------------------------------+
void StoreTicketMap(ulong masterTicket, ulong slaveTicket)
{
   // Update existing entry if found
   for(int i = 0; i < ArraySize(g_ticketMap); i++)
   {
      if(g_ticketMap[i].masterTicket == masterTicket)
      {
         g_ticketMap[i].slaveTicket = slaveTicket;
         return;
      }
   }
   // Add new entry
   int sz = ArraySize(g_ticketMap);
   ArrayResize(g_ticketMap, sz + 1);
   g_ticketMap[sz].masterTicket = masterTicket;
   g_ticketMap[sz].slaveTicket  = slaveTicket;
}

ulong FindSlaveTicket(ulong masterTicket)
{
   for(int i = 0; i < ArraySize(g_ticketMap); i++)
      if(g_ticketMap[i].masterTicket == masterTicket) return g_ticketMap[i].slaveTicket;
   return 0;
}

void RemoveTicketMap(ulong masterTicket)
{
   for(int i = 0; i < ArraySize(g_ticketMap); i++)
   {
      if(g_ticketMap[i].masterTicket == masterTicket)
      {
         ArrayRemove(g_ticketMap, i, 1);
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| Processed ticket tracking (prevent duplicate OPEN execution)     |
//+------------------------------------------------------------------+
bool IsProcessed(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_processedTickets); i++)
      if(g_processedTickets[i] == ticket) return true;
   return false;
}

void MarkProcessed(ulong ticket)
{
   if(IsProcessed(ticket)) return;
   int sz = ArraySize(g_processedTickets);
   ArrayResize(g_processedTickets, sz + 1);
   g_processedTickets[sz] = ticket;

   // Trim oldest entries to cap memory usage
   if(sz > 2000)
      ArrayRemove(g_processedTickets, 0, 1000);
}

void UnmarkProcessed(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_processedTickets); i++)
   {
      if(g_processedTickets[i] == ticket)
      {
         ArrayRemove(g_processedTickets, i, 1);
         return;
      }
   }
}

//+------------------------------------------------------------------+
//| JSON Parsing Utilities                                           |
//|                                                                  |
//| These handle standard JSON output from FastAPI / Python's json   |
//| encoder, including null values and nested-safe extraction.       |
//+------------------------------------------------------------------+

// Extract a string value: "key":"value"
string JSONExtractString(string json, string key)
{
   string searchPattern = "\"" + key + "\":\"";
   int start = StringFind(json, searchPattern);
   if(start < 0) return "";

   start += StringLen(searchPattern);
   int end = start;
   int len = StringLen(json);

   // Scan for closing quote, respecting escape sequences
   while(end < len)
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch == '\\') { end += 2; continue; } // skip escaped char
      if(ch == '"')  break;
      end++;
   }

   return StringSubstr(json, start, end - start);
}

// Extract a long integer value: "key":12345
long JSONExtractInteger(string json, string key)
{
   string searchPattern = "\"" + key + "\":";
   int start = StringFind(json, searchPattern);
   if(start < 0) return 0;

   start += StringLen(searchPattern);
   int end = start;
   int len = StringLen(json);

   // Skip optional leading minus sign
   if(end < len && StringGetCharacter(json, end) == '-') end++;

   // Read digits
   while(end < len)
   {
      ushort ch = StringGetCharacter(json, end);
      if(ch >= '0' && ch <= '9') end++;
      else break;
   }

   if(end == start) return 0;
   return StringToInteger(StringSubstr(json, start, end - start));
}

// Extract a double value: "key":1.09500
double JSONExtractDouble(string json, string key)
{
   string searchPattern = "\"" + key + "\":";
   int start = StringFind(json, searchPattern);
   if(start < 0) return 0.0;

   start += StringLen(searchPattern);
   int end = start;
   int len = StringLen(json);

   // Skip optional leading minus
   if(end < len && StringGetCharacter(json, end) == '-') end++;

   // Read digits, dot, and exponent
   while(end < len)
   {
      ushort ch = StringGetCharacter(json, end);
      if((ch >= '0' && ch <= '9') || ch == '.' || ch == 'e' || ch == 'E' || ch == '+' || ch == '-')
         end++;
      else
         break;
   }

   if(end == start) return 0.0;
   return StringToDouble(StringSubstr(json, start, end - start));
}

//+------------------------------------------------------------------+
//| Dummy OnTick — required for EA to run on chart                   |
//+------------------------------------------------------------------+
void OnTick() { }
//+------------------------------------------------------------------+