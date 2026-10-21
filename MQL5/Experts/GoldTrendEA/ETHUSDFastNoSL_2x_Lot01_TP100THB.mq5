//+------------------------------------------------------------------+
//|                            ETHUSDFastNoSL_2x_Lot01_TP100THB.mq5  |
//|  Same engine, but 2 concurrent positions x lot 0.1 instead of 5  |
//|  x lot 0.04 - same TOTAL max lot exposure (0.2) as the original  |
//|  5x_Lot04 version, just concentrated into fewer/bigger trades so |
//|  each one reaches the 100 THB TP with a smaller price move       |
//|  (faster to resolve, in both directions - see header below).     |
//|                                                                  |
//|  *** ENTERS BOTH POSITIONS TOGETHER, NOT ONE SLOT AT A TIME ***  |
//|  Unlike the 5x/THB versions (which fill slots gradually as       |
//|  signals occur), this one only acts while FULLY FLAT (0 open     |
//|  positions) and, once a signal fires, opens all                 |
//|  InpMaxConcurrentTrades positions back-to-back in the same tick, |
//|  same direction. It will not open a 2nd position on top of 1     |
//|  that's still open from a previous batch - it waits for both to  |
//|  close first, then fires the next batch together again.          |
//|                                                                  |
//|  Same signal engine as ETHUSDFastNoSL.mq5, with two changes      |
//|  requested on top:                                                |
//|   1) The account this runs on is itself denominated in THB, so   |
//|      OrderCalcProfit()/POSITION_PROFIT/DEAL_PROFIT are ALREADY in |
//|      THB automatically - no currency conversion is needed or     |
//|      done here. InpTPThb etc. are used directly as account-      |
//|      currency amounts. (An earlier version of this file wrongly  |
//|      assumed a USD account and divided by a THB/USD rate, which  |
//|      would have made the real TP ~36x smaller than intended on a |
//|      THB account - that conversion has been removed.)            |
//|   2) Up to InpMaxConcurrentTrades (5) independent positions can   |
//|      be open on this symbol/magic at once, each with its own TP   |
//|      and no SL, instead of just one at a time.                    |
//|                                                                  |
//|  *** WHY THIS IS RISKIER THAN THE SINGLE-TRADE NO-SL VERSION ***  |
//|  10 THB is roughly $0.27 at typical rates - SMALLER than the      |
//|  $0.50 target in ETHUSDFastNoSL.mq5, against the same ~$3 (300pt) |
//|  spread ETHUSD often runs. The spread/TP ratio here is worse,     |
//|  not better. On top of that, up to 5 positions can be open at     |
//|  once, all with NO stop loss - if ETH makes one sharp move        |
//|  against the open side, ALL open positions move against you      |
//|  together, multiplying the uncapped loss by however many are      |
//|  open (up to 5x). This is the highest-risk EA in this project.   |
//|  Use only with money you can afford to lose completely, demo     |
//|  first, and watch it closely.                                     |
//|                                                                  |
//|  The spread filter here is kept deliberately TIGHT (see input)   |
//|  so that, mathematically, it only trades when spread cost is a   |
//|  sane fraction of the 10 THB target - which on ETHUSD may mean it|
//|  sits out almost all the time. That is intentional protection,   |
//|  not a bug: loosening it to trade more often means trading at    |
//|  a guaranteed-loss spread-to-TP ratio.                            |
//|                                                                  |
//|  The only safety net is InpEmergencyStopThb: NOT a broker SL,    |
//|  just a monitor that force-closes EACH position individually if  |
//|  ITS OWN floating loss crosses that THB amount. Set it to 0 for   |
//|  truly zero protection.                                          |
//+------------------------------------------------------------------+
#property copyright "metee"
#property version   "1.00"
#property description "ETHUSD M1 scalper, NO SL, up to 2 concurrent positions, lot 0.1, TP 100 THB. Same total exposure as the 5x/lot04 version, faster to resolve."

#include <Trade\Trade.mqh>

input group "=== General ==="
input long             InpMagic          = 20261014;              // Magic number
input string           InpComment        = "ETHNoSL2xL01TP100";   // Order comment
input int              InpDeviation      = 50;                    // Max slippage (points)

input group "=== Trade ==="
input double           InpLot                  = 0.1;             // Fixed lot per position
input int              InpMaxConcurrentTrades  = 2;                // Max positions open at once on this symbol/magic
input double           InpTPThb                = 100.0;            // Take profit target per trade, in Thai Baht
input int              InpMaxSpreadPts         = 350;               // Max spread (points, ~$3.50). Same as the other THB versions - see warning below re: ratio.

input group "=== !!! NO STOP LOSS !!! (see file header) ==="
input double           InpEmergencyStopThb = 1500.0;               // Force-close ONE position if ITS floating loss hits this many THB (0 = truly no protection at all). At lot 0.1 this triggers on a SMALLER price move than the lot 0.04 version - re-check this still matches your real account size.

input group "=== Signal (M1) ==="
input int              InpFastEMA        = 8;                     // Fast EMA period
input int              InpSlowEMA        = 21;                    // Slow EMA period
input int              InpRSIPeriod      = 14;                    // RSI period
input double           InpRSIBuyMax      = 75.0;                  // No BUY if RSI above this
input double           InpRSISellMin     = 25.0;                  // No SELL if RSI below this

input group "=== Fast re-entry ==="
input int              InpMaxIdleSec     = 120;                   // Max seconds with a free slot and no entry before using the looser fallback signal

input group "=== Daily targets ==="
input double           InpDailyProfitTargetThb = 2000.0;           // Stop opening new trades once today's net profit hits this (THB, 0 = off). GUESS - adjust to your real account size.
input double           InpDailyLossStopThb     = 1200.0;           // Stop opening new trades if today's net loss reaches this (THB, 0 = off). GUESS - adjust to your real account size.

input group "=== Session filter (broker SERVER time) ==="
input bool             InpUseSession     = false;                 // Leave off - you control the run window by hand
input int              InpStartHour      = 7;                     // Start hour (0-23)
input int              InpEndHour        = 20;                    // End hour (0-23, exclusive)

input group "=== Logging ==="
input bool             InpLogToFile      = true;                  // Write trade log to CSV in MQL5\Files
input string           InpLogFileName    = "ETHUSDFastNoSL_2x_Lot01_TP100THB_log.csv"; // Log file name

CTrade   g_trade;
int      g_hFast = INVALID_HANDLE;
int      g_hSlow = INVALID_HANDLE;
int      g_hRSI  = INVALID_HANDLE;
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
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }

   LogInit();
   g_lastEntryTime = LoadLastEntryTime();

   PrintFormat("ETHUSDFastNoSL_2x_Lot01_TP100THB started on %s, lot=%.2f, maxConcurrent=%d, TP=%.2f %s, NO SL (emergency=%.2f %s)",
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
