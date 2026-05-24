//+------------------------------------------------------------------+
//|                                    Master (Signal Sender).mq5    |
//|                          Cloud-Based MT5-to-MT5 Trade Copier     |
//|                                         Component 1: Master EA   |
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
#property description "Master EA: Monitors trades and sends signals to the cloud server"

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input group "=== Server Settings ==="
input string   ServerURL           = "http://YOUR_SERVER_IP:8000/api/signals"; // FastAPI server endpoint
input int      RequestTimeoutMs    = 5000;   // HTTP request timeout in milliseconds

input group "=== Trade Filter ==="
input long     MasterMagicNumber   = 0;      // 0 = mirror ALL trades; set a number to filter by magic
input bool     SkipCommentedTrades = false;  // Skip trades where comment contains "CloudCopy"

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+

// Stores all known open position tickets so we can detect opens/closes
ulong g_knownTickets[];

// Stores SL/TP per ticket to detect modifications
struct PositionSnapshot
{
   ulong  ticket;
   double sl;
   double tp;
};
PositionSnapshot g_snapshots[];

bool g_initialized = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("============================================================");
   Print("[MASTER] Cloud Trade Copier - Master EA v2.00 starting...");
   Print("[MASTER] Server URL : ", ServerURL);
   Print("[MASTER] Magic filter: ", (MasterMagicNumber == 0 ? "ALL trades" : IntegerToString(MasterMagicNumber)));
   Print("============================================================");

   // Validate URL is configured
   if(StringFind(ServerURL, "YOUR_SERVER_IP") >= 0)
   {
      Alert("[MASTER] ERROR: Please configure the ServerURL input parameter with your actual server IP/domain.");
      Print("[MASTER] ERROR: ServerURL still contains placeholder 'YOUR_SERVER_IP'. Update it before using.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   // Pre-load deal history so HistoryDealSelect() works inside OnTradeTransaction
   HistorySelect(0, TimeCurrent());
   // Take a snapshot of currently open positions so we don't re-send them on attach
   BuildInitialSnapshot();

   g_initialized = true;
   Print("[MASTER] Initialization complete. Monitoring ", ArraySize(g_knownTickets), " existing positions.");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ArrayFree(g_knownTickets);
   ArrayFree(g_snapshots);
   Print("[MASTER] EA deinitialized. Reason code: ", reason);
}

//+------------------------------------------------------------------+
//| Build initial snapshot of all open positions on EA attach        |
//| This prevents re-sending signals for trades already open         |
//+------------------------------------------------------------------+
void BuildInitialSnapshot()
{
   int total = PositionsTotal();
   ArrayResize(g_knownTickets, 0);
   ArrayResize(g_snapshots, 0);

   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(!PassesMagicFilter(PositionGetInteger(POSITION_MAGIC))) continue;

      // Add to known tickets
      int sz = ArraySize(g_knownTickets);
      ArrayResize(g_knownTickets, sz + 1);
      g_knownTickets[sz] = ticket;

      // Snapshot SL/TP
      int ssz = ArraySize(g_snapshots);
      ArrayResize(g_snapshots, ssz + 1);
      g_snapshots[ssz].ticket = ticket;
      g_snapshots[ssz].sl     = PositionGetDouble(POSITION_SL);
      g_snapshots[ssz].tp     = PositionGetDouble(POSITION_TP);
   }
}

//+------------------------------------------------------------------+
//| Main trade event handler — fires on every trade-related event    |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   if(!g_initialized) return;

   //------------------------------------------------------------------
   // DEAL_ADD fires when a deal is executed (position opened or closed)
   //------------------------------------------------------------------
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      // Select the deal from history
      if(!HistoryDealSelect(trans.deal)) return;

      long dealEntry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      long dealMagic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);

      if(!PassesMagicFilter(dealMagic)) return;

      //--- Position OPENED (deal entry IN) -------------------------
      if(dealEntry == DEAL_ENTRY_IN)
      {
         ulong positionId = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);

         // Wait briefly to ensure position is visible in PositionsTotal()
         Sleep(50);

         if(PositionSelectByTicket(positionId))
         {
            // Guard: skip if we already know this ticket (EA was re-attached mid-trade)
            if(IsKnownTicket(positionId)) return;

            string symbol  = PositionGetString(POSITION_SYMBOL);
            string posType = PositionTypeToStr((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE));
            double volume  = PositionGetDouble(POSITION_VOLUME);
            double sl      = PositionGetDouble(POSITION_SL);
            double tp      = PositionGetDouble(POSITION_TP);
            string comment = PositionGetString(POSITION_COMMENT);

            // Optionally skip trades already tagged as CloudCopy
            if(SkipCommentedTrades && StringFind(comment, "CloudCopy") >= 0) return;

            if(SendSignal("OPEN", positionId, symbol, posType, volume, sl, tp, dealMagic, comment))
            {
               AddKnownTicket(positionId, sl, tp);
            }
         }
         else
         {
            // Position may have already closed (scalp). Try from deal data.
            // For partial fill scenarios we still want to record it.
            string symbol  = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
            double volume  = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
            long   dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
            string posType  = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
            string comment  = HistoryDealGetString(trans.deal, DEAL_COMMENT);

            if(!IsKnownTicket(positionId))
            {
               SendSignal("OPEN", positionId, symbol, posType, volume, 0, 0, dealMagic, comment);
               AddKnownTicket(positionId, 0, 0);
            }
         }
      }

      //--- Position CLOSED (deal entry OUT) ------------------------
      else if(dealEntry == DEAL_ENTRY_OUT || dealEntry == DEAL_ENTRY_INOUT)
      {
         ulong positionId = HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
         string symbol    = HistoryDealGetString(trans.deal, DEAL_SYMBOL);
         string comment   = HistoryDealGetString(trans.deal, DEAL_COMMENT);

         if(IsKnownTicket(positionId))
         {
            SendSignal("CLOSE", positionId, symbol, "", 0, 0, 0, dealMagic, comment);
            RemoveKnownTicket(positionId);
         }
      }
   }

   //------------------------------------------------------------------
   // TRADE_TRANSACTION_POSITION fires when an open position is modified
   //------------------------------------------------------------------
   else if(trans.type == TRADE_TRANSACTION_POSITION)
   {
      ulong positionId = trans.position;
      if(!PositionSelectByTicket(positionId)) return;

      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!PassesMagicFilter(magic)) return;

      double newSL = PositionGetDouble(POSITION_SL);
      double newTP = PositionGetDouble(POSITION_TP);

      // Only send MODIFY if SL or TP actually changed
      int idx = FindSnapshotIndex(positionId);
      if(idx >= 0)
      {
         if(NormalizeDouble(g_snapshots[idx].sl - newSL, 8) != 0.0 ||
            NormalizeDouble(g_snapshots[idx].tp - newTP, 8) != 0.0)
         {
            string symbol  = PositionGetString(POSITION_SYMBOL);
            string posType = PositionTypeToStr((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE));
            double volume  = PositionGetDouble(POSITION_VOLUME);
            string comment = PositionGetString(POSITION_COMMENT);

            if(SendSignal("MODIFY", positionId, symbol, posType, volume, newSL, newTP, magic, comment))
            {
               // Update snapshot
               g_snapshots[idx].sl = newSL;
               g_snapshots[idx].tp = newTP;
            }
         }
      }
      else if(IsKnownTicket(positionId))
      {
         // Snapshot missing but ticket is known — add snapshot
         AddSnapshotEntry(positionId, newSL, newTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Build and send the JSON signal to the FastAPI server             |
//+------------------------------------------------------------------+
bool SendSignal(string action,
                ulong  ticket,
                string symbol,
                string posType,
                double volume,
                double sl,
                double tp,
                long   magic,
                string comment)
{
   // ---- Build JSON payload ----------------------------------------
   string json = "{";
   json += "\"action\":\""  + action                      + "\",";
   json += "\"ticket\":"    + IntegerToString(ticket)     + ",";
   json += "\"symbol\":\""  + symbol                      + "\",";
   json += "\"type\":\""    + posType                     + "\",";
   json += "\"volume\":"    + DoubleToString(volume, 8)   + ",";
   json += "\"sl\":"        + DoubleToString(sl, 8)       + ",";
   json += "\"tp\":"        + DoubleToString(tp, 8)       + ",";
   json += "\"magic\":"     + IntegerToString(magic)      + ",";
   json += "\"comment\":\"" + EscapeJSON(comment)         + "\"";
   json += "}";

   // ---- Prepare WebRequest buffers --------------------------------
   string headers  = "Content-Type: application/json\r\n";
   char   postData[];
   char   resultData[];
   string resultHeaders;

   // StringToCharArray includes null terminator; subtract 1 for actual byte count
   int dataLen = StringToCharArray(json, postData, 0, WHOLE_ARRAY, CP_UTF8) - 1;
   if(dataLen <= 0)
   {
      Print("[MASTER] ERROR: Failed to encode JSON payload for ticket ", ticket);
      return false;
   }
   ArrayResize(postData, dataLen); // Trim null terminator

   // ---- Send HTTP POST request ------------------------------------
   int httpCode = WebRequest(
      "POST",           // Method
      ServerURL,        // URL
      headers,          // Request headers
      RequestTimeoutMs, // Timeout (ms)
      postData,         // POST body
      resultData,       // Response body (out)
      resultHeaders     // Response headers (out)
   );

   string responseBody = (ArraySize(resultData) > 0) ? CharArrayToString(resultData) : "";

   // ---- Evaluate result ------------------------------------------
   if(httpCode == 200 || httpCode == 201)
   {
      Print("[MASTER] ✓ Signal sent | Action:", action,
            " | Ticket:", ticket,
            " | Symbol:", symbol,
            " | Type:", posType,
            " | Vol:", DoubleToString(volume, 2),
            " | Response:", responseBody);
      return true;
   }
   else
   {
      Print("[MASTER] ✗ Send FAILED | HTTP:", httpCode,
            " | Action:", action,
            " | Ticket:", ticket,
            " | Symbol:", symbol);

      if(httpCode == -1)
         Print("[MASTER]   → WebRequest error: ", GetLastError(),
               " — Check Tools→Options→Expert Advisors→Allow WebRequest and add: ", ServerURL);
      else if(httpCode == 0)
         Print("[MASTER]   → No response (timeout or connection refused). Is the server running?");
      else if(httpCode == 404)
         Print("[MASTER]   → 404 Not Found. Verify server URL: ", ServerURL);
      else if(httpCode == 422)
         Print("[MASTER]   → 422 Unprocessable. Payload rejected. Body sent: ", json);
      else if(httpCode == 500)
         Print("[MASTER]   → 500 Internal Server Error. Check server logs.");

      if(StringLen(responseBody) > 0)
         Print("[MASTER]   → Server says: ", responseBody);

      return false;
   }
}

//+------------------------------------------------------------------+
//| Escape special characters in JSON string values                  |
//+------------------------------------------------------------------+
string EscapeJSON(string s)
{
   StringReplace(s, "\\", "\\\\");
   StringReplace(s, "\"", "\\\"");
   StringReplace(s, "\n", "\\n");
   StringReplace(s, "\r", "\\r");
   StringReplace(s, "\t", "\\t");
   return s;
}

//+------------------------------------------------------------------+
//| Convert ENUM_POSITION_TYPE to "BUY" / "SELL"                    |
//+------------------------------------------------------------------+
string PositionTypeToStr(ENUM_POSITION_TYPE t)
{
   if(t == POSITION_TYPE_BUY)  return "BUY";
   if(t == POSITION_TYPE_SELL) return "SELL";
   return "UNKNOWN";
}

//+------------------------------------------------------------------+
//| Check if a magic number passes the filter                        |
//+------------------------------------------------------------------+
bool PassesMagicFilter(long magic)
{
   return (MasterMagicNumber == 0 || magic == MasterMagicNumber);
}

//+------------------------------------------------------------------+
//| Ticket tracking helpers                                          |
//+------------------------------------------------------------------+
bool IsKnownTicket(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_knownTickets); i++)
      if(g_knownTickets[i] == ticket) return true;
   return false;
}

void AddKnownTicket(ulong ticket, double sl, double tp)
{
   if(IsKnownTicket(ticket)) return;

   int sz = ArraySize(g_knownTickets);
   ArrayResize(g_knownTickets, sz + 1);
   g_knownTickets[sz] = ticket;

   AddSnapshotEntry(ticket, sl, tp);
}

void AddSnapshotEntry(ulong ticket, double sl, double tp)
{
   int sz = ArraySize(g_snapshots);
   ArrayResize(g_snapshots, sz + 1);
   g_snapshots[sz].ticket = ticket;
   g_snapshots[sz].sl     = sl;
   g_snapshots[sz].tp     = tp;
}

void RemoveKnownTicket(ulong ticket)
{
   // Remove from g_knownTickets
   for(int i = 0; i < ArraySize(g_knownTickets); i++)
   {
      if(g_knownTickets[i] == ticket)
      {
         ArrayRemove(g_knownTickets, i, 1);
         break;
      }
   }
   // Remove from g_snapshots
   for(int i = 0; i < ArraySize(g_snapshots); i++)
   {
      if(g_snapshots[i].ticket == ticket)
      {
         ArrayRemove(g_snapshots, i, 1);
         break;
      }
   }
}

int FindSnapshotIndex(ulong ticket)
{
   for(int i = 0; i < ArraySize(g_snapshots); i++)
      if(g_snapshots[i].ticket == ticket) return i;
   return -1;
}

//+------------------------------------------------------------------+
//| Dummy OnTick — needed for EA to run on chart                     |
//+------------------------------------------------------------------+
void OnTick() { }
//+------------------------------------------------------------------+