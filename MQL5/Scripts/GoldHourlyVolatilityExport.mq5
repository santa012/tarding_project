//+------------------------------------------------------------------+
//|                              GoldHourlyVolatilityExport.mq5      |
//|  One-shot SCRIPT (not an EA) - run it once from the Scripts      |
//|  folder on a GOLD chart. Walks back through the last             |
//|  InpDaysBack days of M15 bars and buckets the average bar range  |
//|  (High-Low) by broker SERVER hour, writing the result to a CSV   |
//|  in MQL5\Files. Lets us see which hours of the day actually      |
//|  move the most on real historical data, instead of guessing.     |
//+------------------------------------------------------------------+
#property copyright "metee"
#property version   "1.00"
#property script_show_inputs

input int InpDaysBack = 90; // How many days of history to scan

void OnStart()
{
   double sumRange[24];
   long   countBars[24];
   ArrayInitialize(sumRange, 0.0);
   ArrayInitialize(countBars, 0);

   datetime fromTime = TimeCurrent() - InpDaysBack * 24 * 60 * 60;

   MqlRates rates[];
   int copied = CopyRates(_Symbol, PERIOD_M15, fromTime, TimeCurrent(), rates);
   if(copied <= 0)
   {
      PrintFormat("No history copied (error %d). Make sure the chart has downloaded enough history (scroll left) and try again.", GetLastError());
      return;
   }

   for(int i = 0; i < copied; i++)
   {
      MqlDateTime t;
      TimeToStruct(rates[i].time, t);
      int h = t.hour;
      double range = rates[i].high - rates[i].low;
      sumRange[h] += range;
      countBars[h]++;
   }

   string fileName = "GoldHourlyVolatility_" + _Symbol + ".csv";
   int fh = FileOpen(fileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(fh == INVALID_HANDLE)
   {
      PrintFormat("Failed to open %s for writing. Error: %d", fileName, GetLastError());
      return;
   }

   FileWrite(fh, "ServerHour", "BarCount", "AvgRange", "TotalRange");
   for(int h = 0; h < 24; h++)
   {
      double avgRange = (countBars[h] > 0) ? (sumRange[h] / countBars[h]) : 0.0;
      FileWrite(fh, h, countBars[h], DoubleToString(avgRange, 3), DoubleToString(sumRange[h], 2));
   }
   FileClose(fh);

   PrintFormat("Done. Scanned %d M15 bars over ~%d days. Wrote %s to MQL5\\Files.", copied, InpDaysBack, fileName);
   Print("Columns: ServerHour (0-23), BarCount (how many M15 bars seen at that hour), AvgRange (avg High-Low per bar, $), TotalRange (sum, a rough proxy for total movement at that hour).");
}
//+------------------------------------------------------------------+
