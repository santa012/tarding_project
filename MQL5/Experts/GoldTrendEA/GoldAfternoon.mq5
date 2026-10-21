//+------------------------------------------------------------------+
//|                                             GoldAfternoon.mq5    |
//|  Same engine as GoldFastSafeSL.mq5, restricted to the AFTERNOON  |
//|  session only: 08:00-16:00 broker SERVER time.                   |
//|                                                                  |
//|  Built as one of 3 session-split Gold EAs (Morning/Afternoon/    |
//|  Evening), after analyzing the real GoldFastNoSL.mq5 trade log:  |
//|  in that log, every losing trade (2/2) came from its FALLBACK    |
//|  signal (loosened RSI after an idle timeout); every trade from   |
//|  the strict EMA+RSI(+ADX) signal won (19/19). That's why these   |
//|  3 session EAs use ONLY the strict signal - no fallback - and    |
//|  keep the ATR-based SL from GoldFastSafeSL.mq5 for real downside |
//|  protection.                                                      |
//|                                                                  |
//|  WARNING: "safe" means risk-managed, not guaranteed. The session |
//|  window itself is a round 8h split of the day, not yet verified  |
//|  against real multi-month volatility data for this hour range -  |
//|  see chat for the historical-export script to refine it further. |
//+------------------------------------------------------------------+
#property copyright "metee"
#property version   "1.00"
#property description "XAUUSD M5, afternoon session (08:00-16:00 server time) only. ATR-based SL, strict signal only."

#include <Trade\Trade.mqh>

input group "=== General ==="
input long             InpMagic          = 20261017;              // Magic number
input string           InpComment        = "GoldAfternoon";       // Order comment
input int              InpDeviation      = 30;                    // Max slippage (points)

input group "=== Trade ==="
input double           InpLot            = 0.01;                  // Fixed lot
input double           InpTPUsd          = 1.5;                   // Take profit per trade (account currency)
input int              InpMaxSpreadPts   = 50;                    // Max spread (points). Gold 2-digit: 50 = $0.50

input group "=== Stop loss (ATR-based, capped small for a $30 account) ==="
input int              InpATRPeriod      = 14;                    // ATR period (M5)
input double           InpSLATRMult      = 1.0;                   // SL distance = ATR x this multiplier
input double           InpMinSLUsd       = 1.0;                   // Floor: never risk less than this many $
input double           InpMaxSLUsd       = 2.0;                   // Cap: never risk more than this many $

input group "=== Signal (M5) ==="
input int              InpFastEMA        = 9;                     // Fast EMA period
input int              InpSlowEMA        = 21;                    // Slow EMA period
input int              InpTrendEMA       = 50;                    // Trend filter EMA period

input group "=== Trend strength (ADX) ==="
input bool             InpUseADX         = true;                  // Require trend strength before entering
input int              InpADXPeriod      = 14;                    // ADX period (M5)
input double           InpADXMin         = 18.0;                  // Minimum ADX to allow entry
input bool             InpRequireDI      = true;                  // Require +DI/-DI to agree with signal direction

input group "=== Momentum filter (RSI) ==="
input int              InpRSIPeriod      = 14;                    // RSI period (M5)
input double           InpRSIBuyMax      = 78.0;                  // No BUY if RSI above this (overbought)
input double           InpRSISellMin     = 22.0;                  // No SELL if RSI below this (oversold)

input group "=== Daily targets (protect the small account) ==="
input double           InpDailyProfitTargetUsd = 20.0;            // Stop opening new trades once today's net profit hits this (0 = off)
input double           InpDailyLossStopUsd     = 6.0;             // Stop opening new trades if today's net loss reaches this (0 = off)

input group "=== Session filter (broker SERVER time) ==="
input bool             InpUseSession     = true;                  // ON by design - this EA only trades the afternoon window
input int              InpStartHour      = 8;                     // Start hour (0-23) - afternoon session
input int              InpEndHour        = 16;                    // End hour (0-23, exclusive)

input group "=== Logging ==="
input bool             InpLogToFile      = true;                  // Write trade log to CSV in MQL5\Files
input string           InpLogFileName    = "GoldAfternoon_log.csv"; // Log file name

CTrade   g_trade;
int      g_hFast  = INVALID_HANDLE;
int      g_hSlow  = INVALID_HANDLE;
int      g_hTrend = INVALID_HANDLE;
int      g_hATR   = INVALID_HANDLE;
int      g_hADX   = INVALID_HANDLE;
int      g_hRSI   = INVALID_HANDLE;
datetime g_lastBar = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEMA >= InpSlowEMA || InpSlowEMA >= InpTrendEMA || InpLot <= 0.0 || InpTPUsd <= 0.0 ||
      InpSLATRMult <= 0.0 || InpMinSLUsd <= 0.0 || InpMaxSLUsd < InpMinSLUsd)
   {
      Print("Invalid inputs: need Fast<Slow<Trend EMA, Lot>0, TP>0, SL ATR mult>0, Min SL<=Max SL");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23)
   {
      Print("Invalid inputs: session hours must be 0-23");
      return INIT_PARAMETERS_INCORRECT;
   }

   string up = _Symbol;
   StringToUpper(up);
   if(StringFind(up, "XAU") < 0 && StringFind(up, "GOLD") < 0)
      PrintFormat("WARNING: %s does not look like a gold symbol - check the chart.", _Symbol);

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpDeviation);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   g_hFast  = iMA(_Symbol, PERIOD_M5, InpFastEMA,  0, MODE_EMA, PRICE_CLOSE);
   g_hSlow  = iMA(_Symbol, PERIOD_M5, InpSlowEMA,  0, MODE_EMA, PRICE_CLOSE);
   g_hTrend = iMA(_Symbol, PERIOD_M5, InpTrendEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_hATR   = iATR(_Symbol, PERIOD_M5, InpATRPeriod);
   g_hADX   = iADX(_Symbol, PERIOD_M5, InpADXPeriod);
   g_hRSI   = iRSI(_Symbol, PERIOD_M5, InpRSIPeriod, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE || g_hTrend == INVALID_HANDLE ||
      g_hATR  == INVALID_HANDLE || g_hADX  == INVALID_HANDLE || g_hRSI == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles. Error: ", GetLastError());
      return INIT_FAILED;
   }

   LogInit();

   PrintFormat("GoldAfternoon started on %s, session=%02d:00-%02d:00 server, lot=%.2f, TP=$%.2f, SL=ATR x%.1f (floor $%.2f, cap $%.2f)",
               _Symbol, InpStartHour, InpEndHour, InpLot, InpTPUsd, InpSLATRMult, InpMinSLUsd, InpMaxSLUsd);
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
   if(g_hFast  != INVALID_HANDLE) IndicatorRelease(g_hFast);
   if(g_hSlow  != INVALID_HANDLE) IndicatorRelease(g_hSlow);
   if(g_hTrend != INVALID_HANDLE) IndicatorRelease(g_hTrend);
   if(g_hATR   != INVALID_HANDLE) IndicatorRelease(g_hATR);
   if(g_hADX   != INVALID_HANDLE) IndicatorRelease(g_hADX);
   if(g_hRSI   != INVALID_HANDLE) IndicatorRelease(g_hRSI);
}

//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagic)
         return true;
   }
   return false;
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
double SLDistanceFromATR(const double refPrice)
{
   double atr[1];
   if(CopyBuffer(g_hATR, 0, 1, 1, atr) != 1 || atr[0] <= 0.0)
      return PriceDistanceForUsd(InpMinSLUsd, refPrice);

   double dist    = atr[0] * InpSLATRMult;
   double minDist = PriceDistanceForUsd(InpMinSLUsd, refPrice);
   double maxDist = PriceDistanceForUsd(InpMaxSLUsd, refPrice);
   if(minDist > 0.0 && dist < minDist) dist = minDist;
   if(maxDist > 0.0 && dist > maxDist) dist = maxDist;
   return dist;
}

//+------------------------------------------------------------------+
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
// +1 = BUY, -1 = SELL, 0 = no signal. Uses the last CLOSED M5 bar.
int GetSignal()
{
   double fast[1], slow[1], trend[1], rsi[1];
   if(CopyBuffer(g_hFast,  0, 1, 1, fast)  != 1 ||
      CopyBuffer(g_hSlow,  0, 1, 1, slow)  != 1 ||
      CopyBuffer(g_hTrend, 0, 1, 1, trend) != 1 ||
      CopyBuffer(g_hRSI,   0, 1, 1, rsi)   != 1)
      return 0;

   double close1 = iClose(_Symbol, PERIOD_M5, 1);
   if(close1 <= 0.0) return 0;

   int signal = 0;
   bool trendUp   = (fast[0] > slow[0] && close1 > trend[0]);
   bool trendDown = (fast[0] < slow[0] && close1 < trend[0]);

   if(trendUp   && rsi[0] < InpRSIBuyMax)  signal = +1;
   if(trendDown && rsi[0] > InpRSISellMin) signal = -1;

   if(signal != 0 && !ADXConfirms(signal)) return 0;
   return signal;
}

//+------------------------------------------------------------------+
void OpenTrade(const int signal)
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
   double slDist = SLDistanceFromATR(signal > 0 ? ask : bid);

   if(tpDist < minDist) tpDist = minDist;
   if(slDist > 0.0 && slDist < minDist) slDist = minDist;
   if(tick > 0.0)
   {
      tpDist = MathCeil(tpDist / tick) * tick;
      if(slDist > 0.0) slDist = MathCeil(slDist / tick) * tick;
   }

   double vol = InpLot;
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0.0) vol = MathFloor(vol / step + 1e-9) * step;
   vol = MathMax(vmin, MathMin(vmax, vol));

   bool ok;
   double openPrice, sl, tp;
   string type;
   if(signal > 0)
   {
      tp = NormalizeDouble(ask + tpDist, digits);
      sl = (slDist > 0.0) ? NormalizeDouble(ask - slDist, digits) : 0.0;
      openPrice = ask;
      type = "BUY";
      ok = g_trade.Buy(vol, _Symbol, 0.0, sl, tp, InpComment);
   }
   else
   {
      tp = NormalizeDouble(bid - tpDist, digits);
      sl = (slDist > 0.0) ? NormalizeDouble(bid + slDist, digits) : 0.0;
      openPrice = bid;
      type = "SELL";
      ok = g_trade.Sell(vol, _Symbol, 0.0, sl, tp, InpComment);
   }

   if(!ok)
   {
      PrintFormat("Order failed: retcode=%u (%s)", g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
      LogRow("OPEN_FAILED", 0, type, vol, openPrice, sl, tp, 0.0, g_trade.ResultRetcodeDescription());
   }
   else
   {
      LogRow("OPEN", g_trade.ResultOrder(), type, vol, openPrice, sl, tp, 0.0, "");
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
void OnTick()
{
   datetime barTime = iTime(_Symbol, PERIOD_M5, 0);
   if(barTime == 0 || barTime == g_lastBar) return;   // at most one decision per M5 bar
   g_lastBar = barTime;

   if(HasOpenPosition()) return;
   if(!InSession()) return;

   double todays = TodaysClosedProfit();
   if(InpDailyProfitTargetUsd > 0.0 && todays >= InpDailyProfitTargetUsd)
   {
      PrintFormat("Skip: daily profit target reached (%.2f)", todays);
      return;
   }
   if(InpDailyLossStopUsd > 0.0 && todays <= -MathAbs(InpDailyLossStopUsd))
   {
      PrintFormat("Skip: daily loss stop reached (%.2f)", todays);
      return;
   }

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpreadPts)
   {
      PrintFormat("Skip: spread %d > max %d points", (int)spread, InpMaxSpreadPts);
      return;
   }

   int signal = GetSignal();
   if(signal != 0)
      OpenTrade(signal);
}
//+------------------------------------------------------------------+
