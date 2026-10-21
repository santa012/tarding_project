//+------------------------------------------------------------------+
//|                                            EURUSDFastNoSL.mq5    |
//|  High-frequency M1 scalper for EURUSD, NO BROKER STOP LOSS - MT5 |
//|                                                                  |
//|  Same engine as GoldFastNoSL.mq5, retuned for EURUSD. EURUSD's   |
//|  spread is much tighter relative to a $1-2 TP than gold's (often |
//|  1-2 pips vs gold's $0.50-0.60), so the cost of each trade eats  |
//|  a smaller share of the target here - lower-risk than the gold   |
//|  version of this same NO-SL design, but still NO-SL.             |
//|                                                                  |
//|  Goal this was built for: grow a small account (~$30) toward     |
//|  $1000 by targeting ~$10-15/day net over 4-8 hours of running,   |
//|  one trade at a time, exiting fast (TP $1-2) and re-entering     |
//|  again quickly (max ~2 min idle before trying a looser signal).  |
//|                                                                  |
//|  *** THIS EA OPENS POSITIONS WITH NO STOP LOSS ORDER. ***        |
//|  A position stays open and can float to an UNLIMITED loss until  |
//|  either price recovers to TP or you close it by hand. One sharp  |
//|  move (news, a gap, a flash spike) can wipe the entire account   |
//|  in a single trade. This is explicitly what was asked for - not  |
//|  a recommendation. Use only with money you can afford to lose    |
//|  completely, and only after testing on demo.                     |
//|                                                                  |
//|  The only safety net here is InpEmergencyStopUsd: NOT a broker   |
//|  SL, just a monitor that force-closes the position if floating   |
//|  loss crosses that $ amount. Default is wide on purpose (does    |
//|  not behave like a tight SL) so it only stops true disasters.    |
//|  Set it to 0 to truly have zero protection, exactly as asked.    |
//|                                                                  |
//|  Entry (M1, once per bar): EMA(fast) vs EMA(slow) cross + RSI    |
//|  not at an extreme. If no such signal for InpMaxIdleSec seconds, |
//|  falls back to a looser EMA-only signal so it keeps trading.     |
//+------------------------------------------------------------------+
#property copyright "metee"
#property version   "1.00"
#property description "EURUSD M1 scalper, NO STOP LOSS by design. TP $1-2, fast re-entry. High risk - see header."

#include <Trade\Trade.mqh>

input group "=== General ==="
input long             InpMagic          = 20261006;              // Magic number
input string           InpComment        = "EURUSDFastNoSL";      // Order comment
input int              InpDeviation      = 30;                    // Max slippage (points)

input group "=== Trade ==="
input double           InpLot            = 0.01;                  // Fixed lot
input double           InpTPUsd          = 1.5;                   // Take profit per trade (account currency, 1-2 suggested)
input int              InpMaxSpreadPts   = 20;                    // Max spread (points). EURUSD 5-digit: 20 = 2.0 pips

input group "=== !!! NO STOP LOSS !!! (see file header) ==="
input double           InpEmergencyStopUsd = 5.0;                 // Force-close if floating loss hits this many $ (0 = truly no protection at all)

input group "=== Signal (M1) ==="
input int              InpFastEMA        = 8;                     // Fast EMA period
input int              InpSlowEMA        = 21;                    // Slow EMA period
input int              InpRSIPeriod      = 14;                    // RSI period
input double           InpRSIBuyMax      = 75.0;                  // No BUY if RSI above this
input double           InpRSISellMin     = 25.0;                  // No SELL if RSI below this

input group "=== Fast re-entry ==="
input int              InpMaxIdleSec     = 120;                   // Max seconds with no position before using the looser fallback signal

input group "=== Daily targets ==="
input double           InpDailyProfitTargetUsd = 15.0;            // Stop opening new trades once today's net profit hits this (0 = off)
input double           InpDailyLossStopUsd     = 10.0;            // Stop opening new trades if today's net loss reaches this (0 = off)

input group "=== Session filter (broker SERVER time) ==="
input bool             InpUseSession     = false;                 // Leave off - you control the 4-8h run window by hand
input int              InpStartHour      = 7;                     // Start hour (0-23)
input int              InpEndHour        = 20;                    // End hour (0-23, exclusive)

input group "=== Logging ==="
input bool             InpLogToFile      = true;                  // Write trade log to CSV in MQL5\Files
input string           InpLogFileName    = "EURUSDFastNoSL_log.csv"; // Log file name

CTrade   g_trade;
int      g_hFast = INVALID_HANDLE;
int      g_hSlow = INVALID_HANDLE;
int      g_hRSI  = INVALID_HANDLE;
datetime g_lastBar = 0;
datetime g_lastFlatTime = 0; // time we last had zero open positions
datetime g_lastFallbackAttempt = 0; // throttle: avoid re-firing the fallback every tick

//+------------------------------------------------------------------+
// Persists g_lastFlatTime in a terminal-level global variable so the idle
// clock survives an EA reload, a terminal restart, or a PC reboot.
string GvKey() { return StringFormat("%s_%d_lastFlatTime", _Symbol, (int)InpMagic); }

void SaveLastFlatTime(const datetime t)
{
   GlobalVariableSet(GvKey(), (double)t);
}

datetime LoadLastFlatTime()
{
   if(GlobalVariableCheck(GvKey()))
      return (datetime)GlobalVariableGet(GvKey());
   return TimeCurrent();
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEMA >= InpSlowEMA || InpLot <= 0.0 || InpTPUsd <= 0.0)
   {
      Print("Invalid inputs: need Fast EMA < Slow EMA, Lot > 0, TP > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   string up = _Symbol;
   StringToUpper(up);
   if(StringFind(up, "EURUSD") < 0)
      PrintFormat("WARNING: %s does not look like EURUSD - check the chart.", _Symbol);

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpDeviation);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_hFast = iMA(_Symbol, PERIOD_M1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(_Symbol, PERIOD_M1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI  = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }

   LogInit();
   g_lastFlatTime = LoadLastFlatTime();

   PrintFormat("EURUSDFastNoSL started on %s, lot=%.2f, TP=$%.2f, NO SL (emergency stop=$%.2f), maxIdle=%ds",
               _Symbol, InpLot, InpTPUsd, InpEmergencyStopUsd, InpMaxIdleSec);
   Print("*** Reminder: positions here have NO broker stop loss. See file header for why. ***");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void LogInit()
{
   if(!InpLogToFile) return;
   if(!FileIsExist(InpLogFileName))
   {
      int h = FileOpen(InpLogFileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(h != INVALID_HANDLE)
      {
         FileWrite(h, "Time", "Event", "Ticket", "Type", "Volume", "Price", "SL", "TP", "Profit", "Comment", "Account");
         FileClose(h);
      }
   }
}

void LogRow(const string event, const ulong ticket, const string type, const double volume,
            const double price, const double sl, const double tp, const double profit, const string note)
{
   if(!InpLogToFile) return;
   int h = FileOpen(InpLogFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), event, (long)ticket, type,
              volume, price, sl, tp, profit, note, (long)AccountInfoInteger(ACCOUNT_LOGIN));
   FileClose(h);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_hFast != INVALID_HANDLE) IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE) IndicatorRelease(g_hSlow);
   if(g_hRSI  != INVALID_HANDLE) IndicatorRelease(g_hRSI);
}

//+------------------------------------------------------------------+
ulong GetOpenTicket()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return ticket;
   }
   return 0;
}

//+------------------------------------------------------------------+
bool InSession()
{
   if(!InpUseSession) return true;
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(InpStartHour < InpEndHour)
      return (t.hour >= InpStartHour && t.hour < InpEndHour);
   return (t.hour >= InpStartHour || t.hour < InpEndHour);
}

//+------------------------------------------------------------------+
// Sum of this EA's closed deals since the start of today. Negative = loss.
double TodaysClosedProfit()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0; t.min = 0; t.sec = 0;
   datetime dayStart = StructToTime(t);

   if(!HistorySelect(dayStart, TimeCurrent())) return 0.0;
   double sum = 0.0;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;
      if((long)HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagic) continue;
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      sum += HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_SWAP) +
             HistoryDealGetDouble(ticket, DEAL_COMMISSION);
   }
   return sum;
}

//+------------------------------------------------------------------+
double PriceDistanceForUsd(const double usd, const double refPrice)
{
   double profitPerUnit = 0.0;
   if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, InpLot, refPrice, refPrice + 1.0, profitPerUnit) ||
      profitPerUnit <= 0.0)
      return 0.0;
   return usd / profitPerUnit;
}

//+------------------------------------------------------------------+
// Strict signal: EMA cross + RSI not at an extreme. Uses the last CLOSED bar.
int GetStrictSignal()
{
   double fast[1], slow[1], rsi[1];
   if(CopyBuffer(g_hFast, 0, 1, 1, fast) != 1 ||
      CopyBuffer(g_hSlow, 0, 1, 1, slow) != 1 ||
      CopyBuffer(g_hRSI,  0, 1, 1, rsi)  != 1)
      return 0;

   if(fast[0] > slow[0] && rsi[0] < InpRSIBuyMax)  return +1;
   if(fast[0] < slow[0] && rsi[0] > InpRSISellMin) return -1;
   return 0;
}

//+------------------------------------------------------------------+
// Looser fallback: just the EMA cross direction, no RSI filter.
// Used only after InpMaxIdleSec of no position, to keep turnover going.
int GetFallbackSignal()
{
   double fast[1], slow[1];
   if(CopyBuffer(g_hFast, 0, 1, 1, fast) != 1 || CopyBuffer(g_hSlow, 0, 1, 1, slow) != 1)
      return 0;
   if(fast[0] > slow[0]) return +1;
   if(fast[0] < slow[0]) return -1;
   return 0;
}

//+------------------------------------------------------------------+
void OpenTrade(const int signal, const bool fallback)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0) return;

   double tick   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

   double tpDist = PriceDistanceForUsd(InpTPUsd, signal > 0 ? ask : bid);
   if(tpDist <= 0.0)
   {
      Print("Cannot convert TP USD to price distance. Error: ", GetLastError());
      return;
   }
   if(tpDist < minDist) tpDist = minDist;
   if(tick > 0.0) tpDist = MathCeil(tpDist / tick) * tick;

   double vol = InpLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0) vol = MathFloor(vol / step + 1e-9) * step;
   vol = MathMax(vmin, MathMin(vmax, vol));

   string comment = fallback ? InpComment + "-FALLBACK" : InpComment;

   bool ok;
   double openPrice, tp;
   string type;
   if(signal > 0)
   {
      tp = NormalizeDouble(ask + tpDist, digits);
      openPrice = ask;
      type = "BUY";
      ok = g_trade.Buy(vol, _Symbol, 0.0, 0.0, tp, comment); // sl = 0.0 -> no stop loss, on purpose
   }
   else
   {
      tp = NormalizeDouble(bid - tpDist, digits);
      openPrice = bid;
      type = "SELL";
      ok = g_trade.Sell(vol, _Symbol, 0.0, 0.0, tp, comment);
   }

   if(!ok)
   {
      PrintFormat("Order failed: retcode=%u (%s)", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      LogRow("OPEN_FAILED", 0, type, vol, openPrice, 0.0, tp, 0.0, comment);
   }
   else
   {
      LogRow("OPEN", g_trade.ResultOrder(), type, vol, openPrice, 0.0, tp, 0.0, comment);
   }
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != _Symbol) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) != DEAL_ENTRY_OUT) return; // only log closes

   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT) + HistoryDealGetDouble(trans.deal, DEAL_SWAP) +
                    HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   double price   = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   double volume  = HistoryDealGetDouble(trans.deal, DEAL_VOLUME);
   ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   long   positionId = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   string type = (dtype == DEAL_TYPE_SELL) ? "CLOSE_BUY" : "CLOSE_SELL";

   // Confirm this position is ours via its OPENING deal's magic - the
   // CLOSING deal's own magic can read 0 when the position was closed by
   // hand from the terminal, which would otherwise make this silently
   // skip logging manual closes.
   if(!PositionBelongsToUs(positionId)) return;

   LogRow("CLOSE", trans.deal, type, volume, price, 0.0, 0.0, profit, "");
   g_lastFlatTime = TimeCurrent(); // flat again - start the idle clock for fast re-entry
   SaveLastFlatTime(g_lastFlatTime);
}

//+------------------------------------------------------------------+
// True if the position's OPENING deal carries our magic number - used to
// attribute a CLOSE to this EA even when the closing deal itself (e.g. a
// manual close from the terminal) doesn't carry the magic.
bool PositionBelongsToUs(const long positionId)
{
   if(!HistorySelectByPosition(positionId)) return false;
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0) continue;
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_IN &&
         (long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == InpMagic)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
// Runs every tick: the emergency-close monitor. Not a broker SL - just
// force-closes if floating loss on the single open position crosses
// InpEmergencyStopUsd. Set that input to 0 to disable entirely.
void CheckEmergencyStop()
{
   if(InpEmergencyStopUsd <= 0.0) return;

   ulong ticket = GetOpenTicket();
   if(ticket == 0) return;

   if(!PositionSelectByTicket(ticket)) return;
   double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(profit <= -MathAbs(InpEmergencyStopUsd))
   {
      PrintFormat("EMERGENCY STOP: floating loss %.2f <= -%.2f. Force-closing (this is NOT the normal exit).",
                  profit, InpEmergencyStopUsd);
      g_trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckEmergencyStop();

   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   bool newBar = (barTime != 0 && barTime != g_lastBar);
   if(newBar) g_lastBar = barTime;

   if(GetOpenTicket() != 0) return; // one trade at a time
   if(!InSession()) return;

   double todays = TodaysClosedProfit();
   if(InpDailyProfitTargetUsd > 0.0 && todays >= InpDailyProfitTargetUsd)
   {
      return; // hit today's profit target - stop opening new trades
   }
   if(InpDailyLossStopUsd > 0.0 && todays <= -MathAbs(InpDailyLossStopUsd))
   {
      return; // hit today's loss stop - stop opening new trades
   }

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts) return;

   int idleSec = (int)(TimeCurrent() - g_lastFlatTime);

   // Only evaluate the strict signal once per new bar, to avoid re-checking
   // the same closed-bar data on every tick.
   if(newBar)
   {
      int signal = GetStrictSignal();
      if(signal != 0)
      {
         OpenTrade(signal, false);
         return;
      }
   }

   // Fast re-entry: if we've been flat too long, use the looser fallback
   // signal right away (checked every tick, not gated by bar close).
   // Throttled to one attempt per 3s so a burst of ticks doesn't fire the
   // same order repeatedly while the first request is still in flight.
   if(idleSec >= InpMaxIdleSec && (TimeCurrent() - g_lastFallbackAttempt) >= 3)
   {
      g_lastFallbackAttempt = TimeCurrent();
      int fallback = GetFallbackSignal();
      if(fallback != 0)
         OpenTrade(fallback, true);
   }
}
//+------------------------------------------------------------------+
