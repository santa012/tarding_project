//+------------------------------------------------------------------+
//|                       ETHUSDPrecise2x_Lot01_TP1000THB.mq5        |
//|  Same 2-trade "enter together" engine as                        |
//|  ETHUSDFastNoSL_2x_Lot01_TP100THB.mq5, built after that EA got   |
//|  stuck holding a losing position a long time with no SL. Two     |
//|  changes on top, exactly as requested:                           |
//|   1) TP raised from 100 to 1000 THB per trade.                   |
//|   2) Entry filter made more accurate: on top of EMA cross + RSI, |
//|      now also requires ADX trend strength + DI direction         |
//|      agreement (M1) AND an H1 EMA trend confirmation - the same  |
//|      filter stack already proven useful in GoldPreciseM15.mq5 in |
//|      this project. The fallback (idle) signal keeps the ADX/H1   |
//|      checks too - only the RSI check is dropped for fallback, so |
//|      "accurate" is not quietly undone when it's been idle a      |
//|      while.                                                      |
//|                                                                  |
//|  *** STILL NO STOP LOSS - THIS WAS A DELIBERATE CHOICE ***       |
//|  More accurate filters reduce how OFTEN a trade goes the wrong   |
//|  way; they do not eliminate the chance, and when no SL is used a |
//|  wrong trade can still float, uncapped, for as long as price      |
//|  stays away from TP. No time-based exit was added either (also   |
//|  deliberately, per request) - if you want the "stuck losing for  |
//|  a long time" problem actually solved rather than just made less |
//|  frequent, a stop loss or a time-based exit is what does that.   |
//|                                                                  |
//|  The only safety net is InpEmergencyStopThb: NOT a broker SL,    |
//|  just a monitor that force-closes EACH position individually if  |
//|  ITS OWN floating loss crosses that THB amount. Set it to 0 for   |
//|  truly zero protection.                                          |
//+------------------------------------------------------------------+
#property copyright "metee"
#property version   "1.00"
#property description "ETHUSD M1, NO SL, 2 positions enter together, lot 0.1, TP 1000 THB. ADX+H1 filters for accuracy. See header."

#include <Trade\Trade.mqh>

input group "=== General ==="
input long             InpMagic          = 20261015;              // Magic number
input string           InpComment        = "ETHPrecise2xTP1000";  // Order comment
input int              InpDeviation      = 50;                    // Max slippage (points)

input group "=== Trade ==="
input double           InpLot                  = 0.1;             // Fixed lot per position
input int              InpMaxConcurrentTrades  = 2;                // Max positions open at once on this symbol/magic
input double           InpTPThb                = 1000.0;           // Take profit target per trade, in Thai Baht
input int              InpMaxSpreadPts         = 350;               // Max spread (points, ~$3.50). Comfortably small vs a 1000 THB TP.

input group "=== !!! NO STOP LOSS !!! (see file header) ==="
input double           InpEmergencyStopThb = 15000.0;              // Force-close ONE position if ITS floating loss hits this many THB (0 = truly no protection at all). GUESS scaled to the new TP - adjust to your real account size, we don't know your THB balance.

input group "=== Signal (M1) ==="
input int              InpFastEMA        = 8;                     // Fast EMA period
input int              InpSlowEMA        = 21;                    // Slow EMA period
input int              InpRSIPeriod      = 14;                    // RSI period
input double           InpRSIBuyMax      = 75.0;                  // No BUY if RSI above this
input double           InpRSISellMin     = 25.0;                  // No SELL if RSI below this

input group "=== Trend strength (ADX, M1) - for accuracy ==="
input bool             InpUseADX         = true;                  // Require trend strength before entering
input int              InpADXPeriod      = 14;                    // ADX period
input double           InpADXMin         = 20.0;                  // Minimum ADX to allow entry
input bool             InpRequireDI      = true;                  // Require +DI/-DI to agree with signal direction

input group "=== Higher-timeframe confirmation (H1) - for accuracy ==="
input bool             InpUseH1Filter    = true;                  // Require H1 trend to agree with the M1 signal
input int              InpH1EMA          = 50;                    // H1 EMA period used as the trend reference

input group "=== Fast re-entry ==="
input int              InpMaxIdleSec     = 120;                   // Max seconds with a free slot and no entry before using the looser fallback signal (still passes ADX+H1, only RSI is dropped)

input group "=== Daily targets ==="
input double           InpDailyProfitTargetThb = 20000.0;          // Stop opening new trades once today's net profit hits this (THB, 0 = off). GUESS scaled to the new TP - adjust to your real account size.
input double           InpDailyLossStopThb     = 12000.0;          // Stop opening new trades if today's net loss reaches this (THB, 0 = off). GUESS scaled to the new TP - adjust to your real account size.

input group "=== Session filter (broker SERVER time) ==="
input bool             InpUseSession     = false;                 // Leave off - you control the run window by hand
input int              InpStartHour      = 7;                     // Start hour (0-23)
input int              InpEndHour        = 20;                    // End hour (0-23, exclusive)

input group "=== Logging ==="
input bool             InpLogToFile      = true;                  // Write trade log to CSV in MQL5\Files
input string           InpLogFileName    = "ETHUSDPrecise2x_Lot01_TP1000THB_log.csv"; // Log file name

CTrade   g_trade;
int      g_hFast = INVALID_HANDLE;
int      g_hSlow = INVALID_HANDLE;
int      g_hRSI  = INVALID_HANDLE;
int      g_hADX  = INVALID_HANDLE;
int      g_hH1   = INVALID_HANDLE;
datetime g_lastBar = 0;
datetime g_lastEntryTime = 0;        // time we last opened ANY position
datetime g_lastFallbackAttempt = 0;  // throttle: avoid re-firing the fallback every tick

//+------------------------------------------------------------------+
// Persists g_lastEntryTime in a terminal-level global variable so the idle
// clock survives an EA reload, a terminal restart, or a PC reboot.
string GvKey() { return StringFormat("%s_%d_lastEntryTime", _Symbol, (int)InpMagic); }

void SaveLastEntryTime(const datetime t)
{
   GlobalVariableSet(GvKey(), (double)t);
}

datetime LoadLastEntryTime()
{
   if(GlobalVariableCheck(GvKey()))
      return (datetime)GlobalVariableGet(GvKey());
   return TimeCurrent();
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEMA >= InpSlowEMA || InpLot <= 0.0 || InpTPThb <= 0.0 || InpMaxConcurrentTrades <= 0)
   {
      Print("Invalid inputs: need Fast EMA < Slow EMA, Lot > 0, TP > 0, MaxConcurrentTrades > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   string up = _Symbol;
   StringToUpper(up);
   if(StringFind(up, "ETH") < 0)
      PrintFormat("WARNING: %s does not look like ETHUSD - check the chart.", _Symbol);

   string acctCcy = AccountInfoString(ACCOUNT_CURRENCY);
   if(acctCcy != "THB")
      PrintFormat("WARNING: account currency is '%s', not THB. InpTPThb/InpEmergencyStopThb/daily targets are used AS-IS in whatever currency OrderCalcProfit returns (the account currency) - if that is not THB, these numbers mean %s, not baht.",
                  acctCcy, acctCcy);

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpDeviation);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_hFast = iMA(_Symbol, PERIOD_M1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(_Symbol, PERIOD_M1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hRSI  = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   g_hADX  = iADX(_Symbol, PERIOD_M1, InpADXPeriod);
   g_hH1   = iMA(_Symbol, PERIOD_H1, InpH1EMA, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE || g_hRSI == INVALID_HANDLE ||
      g_hADX == INVALID_HANDLE || g_hH1 == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }

   LogInit();
   g_lastEntryTime = LoadLastEntryTime();

   PrintFormat("ETHUSDPrecise2x_Lot01_TP1000THB started on %s, lot=%.2f, maxConcurrent=%d, TP=%.2f %s, NO SL (emergency=%.2f %s)",
               _Symbol, InpLot, InpMaxConcurrentTrades, InpTPThb, acctCcy, InpEmergencyStopThb, acctCcy);
   long spreadNow = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   PrintFormat("Current spread=%d pts (max allowed=%d). If spread stays above max, this EA will not trade - intentional protection for a small THB TP on ETHUSD.",
               (int)spreadNow, InpMaxSpreadPts);
   Print("*** Reminder: positions here have NO broker stop loss, and up to ", InpMaxConcurrentTrades, " can be open at once. See file header. ***");
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
   if(g_hADX  != INVALID_HANDLE) IndicatorRelease(g_hADX);
   if(g_hH1   != INVALID_HANDLE) IndicatorRelease(g_hH1);
}

//+------------------------------------------------------------------+
// Returns the count of this EA's own open positions on this symbol.
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         count++;
   }
   return count;
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
// Sum of this EA's closed deals since the start of today, in account
// currency (already THB on a THB account). Negative = loss.
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
// Price distance that equals `amount` of profit (in ACCOUNT CURRENCY -
// OrderCalcProfit always returns profit in the account's own currency,
// so no THB/USD conversion is needed here).
double PriceDistanceForAmount(const double amount, const double refPrice)
{
   double profitPerUnit = 0.0;
   if(!OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, InpLot, refPrice, refPrice + 1.0, profitPerUnit) ||
      profitPerUnit <= 0.0)
      return 0.0;
   return amount / profitPerUnit;
}

//+------------------------------------------------------------------+
// True if ADX confirms a strong-enough trend, and (if required) +DI/-DI agree with `signal`.
bool ADXConfirms(const int signal)
{
   if(!InpUseADX) return true;

   double adx[1], plusDI[1], minusDI[1];
   if(CopyBuffer(g_hADX, 0, 1, 1, adx)     != 1 ||
      CopyBuffer(g_hADX, 1, 1, 1, plusDI)  != 1 ||
      CopyBuffer(g_hADX, 2, 1, 1, minusDI) != 1)
      return false;

   if(adx[0] < InpADXMin) return false;
   if(!InpRequireDI) return true;

   if(signal > 0) return plusDI[0]  > minusDI[0];
   return              minusDI[0] > plusDI[0];
}

//+------------------------------------------------------------------+
// True if the H1 trend (price vs H1 EMA) agrees with `signal`.
bool H1Confirms(const int signal)
{
   if(!InpUseH1Filter) return true;

   double h1ema[1];
   if(CopyBuffer(g_hH1, 0, 1, 1, h1ema) != 1) return false;

   double h1Close = iClose(_Symbol, PERIOD_H1, 1);
   if(h1Close <= 0.0) return false;

   if(signal > 0) return h1Close > h1ema[0];
   return              h1Close < h1ema[0];
}

//+------------------------------------------------------------------+
// Strict signal: EMA cross + RSI not at an extreme + ADX trend strength +
// H1 confirmation. Uses the last CLOSED M1 bar. Every check must pass.
int GetStrictSignal()
{
   double fast[1], slow[1], rsi[1];
   if(CopyBuffer(g_hFast, 0, 1, 1, fast) != 1 ||
      CopyBuffer(g_hSlow, 0, 1, 1, slow) != 1 ||
      CopyBuffer(g_hRSI,  0, 1, 1, rsi)  != 1)
      return 0;

   int signal = 0;
   if(fast[0] > slow[0] && rsi[0] < InpRSIBuyMax)  signal = +1;
   if(fast[0] < slow[0] && rsi[0] > InpRSISellMin) signal = -1;

   if(signal != 0 && !ADXConfirms(signal)) return 0;
   if(signal != 0 && !H1Confirms(signal))  return 0;
   return signal;
}

//+------------------------------------------------------------------+
// Looser fallback: EMA cross direction, RSI dropped, but ADX+H1 are KEPT -
// those are the "accuracy" filters and stay required even when idle.
int GetFallbackSignal()
{
   double fast[1], slow[1];
   if(CopyBuffer(g_hFast, 0, 1, 1, fast) != 1 || CopyBuffer(g_hSlow, 0, 1, 1, slow) != 1)
      return 0;

   int signal = 0;
   if(fast[0] > slow[0]) signal = +1;
   if(fast[0] < slow[0]) signal = -1;

   if(signal != 0 && !ADXConfirms(signal)) return 0;
   if(signal != 0 && !H1Confirms(signal))  return 0;
   return signal;
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

   double tpDist = PriceDistanceForAmount(InpTPThb, signal > 0 ? ask : bid);
   if(tpDist <= 0.0)
   {
      Print("Cannot convert TP to price distance. Error: ", GetLastError());
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
      g_lastEntryTime = TimeCurrent();
      SaveLastEntryTime(g_lastEntryTime);
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
// force-closes EACH open position individually if ITS OWN floating loss
// (already in account currency) crosses InpEmergencyStopThb. Set that
// input to 0 to disable entirely.
void CheckEmergencyStop()
{
   if(InpEmergencyStopThb <= 0.0) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(profit <= -MathAbs(InpEmergencyStopThb))
      {
         PrintFormat("EMERGENCY STOP on ticket %I64u: floating loss %.2f <= -%.2f. Force-closing.",
                     ticket, profit, InpEmergencyStopThb);
         g_trade.PositionClose(ticket);
      }
   }
}

//+------------------------------------------------------------------+
// Opens InpMaxConcurrentTrades positions back-to-back, same direction,
// in the same tick - "enter together", not one-at-a-time slot filling.
void OpenBatch(const int signal, const bool fallback)
{
   for(int i = 0; i < InpMaxConcurrentTrades; i++)
      OpenTrade(signal, fallback);
}

//+------------------------------------------------------------------+
void OnTick()
{
   CheckEmergencyStop();

   datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
   bool newBar = (barTime != 0 && barTime != g_lastBar);
   if(newBar) g_lastBar = barTime;

   int openCount = CountOpenPositions();
   if(openCount > 0) return; // wait until fully flat before firing the next batch together
   if(!InSession()) return;

   double todays = TodaysClosedProfit();
   if(InpDailyProfitTargetThb > 0.0 && todays >= InpDailyProfitTargetThb)
   {
      return; // hit today's profit target - stop opening new trades
   }
   if(InpDailyLossStopThb > 0.0 && todays <= -MathAbs(InpDailyLossStopThb))
   {
      return; // hit today's loss stop - stop opening new trades
   }

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts) return;

   int idleSec = (int)(TimeCurrent() - g_lastEntryTime);

   // Only evaluate the strict signal once per new bar, to avoid re-checking
   // the same closed-bar data on every tick.
   if(newBar)
   {
      int signal = GetStrictSignal();
      if(signal != 0)
      {
         OpenBatch(signal, false);
         return;
      }
   }

   // Fast re-entry: if we've been flat too long, use the looser
   // fallback signal right away. Throttled to one attempt per 3s.
   if(idleSec >= InpMaxIdleSec && (TimeCurrent() - g_lastFallbackAttempt) >= 3)
   {
      g_lastFallbackAttempt = TimeCurrent();
      int fallback = GetFallbackSignal();
      if(fallback != 0)
         OpenBatch(fallback, true);
   }
}
//+------------------------------------------------------------------+
