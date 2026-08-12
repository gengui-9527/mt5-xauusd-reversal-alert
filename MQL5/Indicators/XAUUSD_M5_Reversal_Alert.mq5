#property copyright "Codex"
#property version   "1.00"
#property description "Monitors an XAUUSD-family M5 symbol and alerts on sustained intrabar reversals."
#property indicator_chart_window
#property indicator_plots 0

enum SignalDirection
  {
   DIR_SHORT = -1,
   DIR_NONE  = 0,
   DIR_LONG  = 1
  };

input string           InpSymbol                    = "XAUUSD";
input int              InpFastEmaPeriod             = 9;
input int              InpSlowEmaPeriod             = 21;
input int              InpAtrPeriod                 = 10;
input double           InpSupertrendMultiplier      = 3.0;
input int              InpRsiPeriod                 = 14;
input double           InpRsiMidpoint               = 50.0;
input int              InpHoldSeconds               = 10;
input int              InpTimerMilliseconds         = 100;
input int              InpMaximumActiveTickGapMs    = 1000;
input int              InpReconnectResetSeconds     = 60;
input bool             InpEnableSound               = true;
input string           InpLongSound                 = "alert.wav";
input string           InpShortSound                = "timeout.wav";
input bool             InpEnablePopup               = true;
input ENUM_BASE_CORNER InpPanelCorner               = CORNER_LEFT_UPPER;
input int              InpPanelX                    = 12;
input int              InpPanelY                    = 18;
input color            InpLongColor                 = clrLimeGreen;
input color            InpShortColor                = clrTomato;
input color            InpNeutralColor              = clrSilver;
input color            InpErrorColor                = clrOrangeRed;

struct SignalSnapshot
  {
   int      ema_vote;
   int      supertrend_vote;
   int      rsi_vote;
   int      candidate;
   double   fast_ema;
   double   slow_ema;
   double   supertrend_line;
   double   rsi;
   double   close;
   long     tick_time_msc;
   datetime server_time;
  };

const string PANEL_PREFIX = "XAU_M5_RA_";
const int    COPY_BARS    = 200;

string g_symbol = "";
string g_status = "正在初始化";
int    g_fast_ema_handle = INVALID_HANDLE;
int    g_slow_ema_handle = INVALID_HANDLE;
int    g_atr_handle      = INVALID_HANDLE;
int    g_rsi_handle      = INVALID_HANDLE;

int   g_confirmed_direction = DIR_NONE;
int   g_pending_direction   = DIR_NONE;
ulong g_pending_elapsed_ms  = 0;
ulong g_last_pending_tick_ms = 0;

long   g_last_tick_time_msc = 0;
double g_last_tick_bid      = 0.0;
double g_last_tick_ask      = 0.0;
long   g_previous_server_tick_msc = 0;
bool   g_has_snapshot = false;
SignalSnapshot g_snapshot;

string DirectionText(const int direction)
  {
   if(direction == DIR_LONG)
      return "多";
   if(direction == DIR_SHORT)
      return "空";
   return "中性";
  }

color DirectionColor(const int direction)
  {
   if(direction == DIR_LONG)
      return InpLongColor;
   if(direction == DIR_SHORT)
      return InpShortColor;
   return InpNeutralColor;
  }

bool ValidateInputs()
  {
   if(StringLen(InpSymbol) == 0)
     {
      g_status = "参数错误：品种名不能为空";
      return false;
     }
   if(InpFastEmaPeriod <= 0 || InpSlowEmaPeriod <= InpFastEmaPeriod)
     {
      g_status = "参数错误：EMA周期必须满足 0 < 快线 < 慢线";
      return false;
     }
   if(InpAtrPeriod <= 0 || InpSupertrendMultiplier <= 0.0)
     {
      g_status = "参数错误：ATR周期和Supertrend倍数必须为正";
      return false;
     }
   if(InpRsiPeriod <= 0 || InpRsiMidpoint <= 0.0 || InpRsiMidpoint >= 100.0)
     {
      g_status = "参数错误：RSI周期或中轴无效";
      return false;
     }
   if(InpHoldSeconds <= 0 || InpTimerMilliseconds < 50 ||
      InpMaximumActiveTickGapMs <= 0 || InpReconnectResetSeconds <= 0)
     {
      g_status = "参数错误：计时参数无效";
      return false;
     }
   return true;
  }

bool ResolveTargetSymbol()
  {
   if(SymbolSelect(InpSymbol,true))
     {
      g_symbol = InpSymbol;
      return true;
     }

   string needle = InpSymbol;
   StringToUpper(needle);
   int total = SymbolsTotal(false);
   for(int index=0; index<total; index++)
     {
      string candidate = SymbolName(index,false);
      string upper_candidate = candidate;
      StringToUpper(upper_candidate);
      if(StringFind(upper_candidate,needle) >= 0 && SymbolSelect(candidate,true))
        {
         g_symbol = candidate;
         return true;
        }
     }

   g_status = "找不到品种：" + InpSymbol;
   return false;
  }

bool CreateIndicatorHandles()
  {
   g_fast_ema_handle = iMA(g_symbol,PERIOD_M5,InpFastEmaPeriod,0,MODE_EMA,PRICE_CLOSE);
   g_slow_ema_handle = iMA(g_symbol,PERIOD_M5,InpSlowEmaPeriod,0,MODE_EMA,PRICE_CLOSE);
   g_atr_handle      = iATR(g_symbol,PERIOD_M5,InpAtrPeriod);
   g_rsi_handle      = iRSI(g_symbol,PERIOD_M5,InpRsiPeriod,PRICE_CLOSE);

   if(g_fast_ema_handle == INVALID_HANDLE ||
      g_slow_ema_handle == INVALID_HANDLE ||
      g_atr_handle == INVALID_HANDLE ||
      g_rsi_handle == INVALID_HANDLE)
     {
      g_status = "指标句柄创建失败，错误码 " + IntegerToString(GetLastError());
      return false;
     }
   return true;
  }

void DeletePanel()
  {
   ObjectsDeleteAll(0,PANEL_PREFIX);
  }

void ReleaseResources()
  {
   EventKillTimer();
   if(g_fast_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_fast_ema_handle);
   if(g_slow_ema_handle != INVALID_HANDLE)
      IndicatorRelease(g_slow_ema_handle);
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
   if(g_rsi_handle != INVALID_HANDLE)
      IndicatorRelease(g_rsi_handle);
   g_fast_ema_handle = INVALID_HANDLE;
   g_slow_ema_handle = INVALID_HANDLE;
   g_atr_handle      = INVALID_HANDLE;
   g_rsi_handle      = INVALID_HANDLE;
   DeletePanel();
  }

int MajorityVote(const int ema_vote,const int supertrend_vote,const int rsi_vote)
  {
   int long_votes = 0;
   int short_votes = 0;
   if(ema_vote == DIR_LONG) long_votes++;
   if(supertrend_vote == DIR_LONG) long_votes++;
   if(rsi_vote == DIR_LONG) long_votes++;
   if(ema_vote == DIR_SHORT) short_votes++;
   if(supertrend_vote == DIR_SHORT) short_votes++;
   if(rsi_vote == DIR_SHORT) short_votes++;
   if(long_votes >= 2) return DIR_LONG;
   if(short_votes >= 2) return DIR_SHORT;
   return DIR_NONE;
  }

int CompareValues(const double left,const double right)
  {
   if(left > right) return DIR_LONG;
   if(left < right) return DIR_SHORT;
   return DIR_NONE;
  }

bool CalculateSupertrendVote(const MqlRates &rates[],
                             const double &atr[],
                             const int count,
                             int &vote,
                             double &line)
  {
   if(count < 3)
      return false;

   double previous_mid = (rates[0].high + rates[0].low) * 0.5;
   double previous_upper = previous_mid + InpSupertrendMultiplier * atr[0];
   double previous_lower = previous_mid - InpSupertrendMultiplier * atr[0];
   bool long_trend = (rates[0].close >= previous_mid);

   for(int index=1; index<count; index++)
     {
      double mid = (rates[index].high + rates[index].low) * 0.5;
      double basic_upper = mid + InpSupertrendMultiplier * atr[index];
      double basic_lower = mid - InpSupertrendMultiplier * atr[index];

      double final_upper = basic_upper;
      if(basic_upper >= previous_upper && rates[index-1].close <= previous_upper)
         final_upper = previous_upper;

      double final_lower = basic_lower;
      if(basic_lower <= previous_lower && rates[index-1].close >= previous_lower)
         final_lower = previous_lower;

      if(long_trend)
        {
         if(rates[index].close < final_lower)
            long_trend = false;
        }
      else
        {
         if(rates[index].close > final_upper)
            long_trend = true;
        }

      previous_upper = final_upper;
      previous_lower = final_lower;
     }

   line = long_trend ? previous_lower : previous_upper;
   vote = CompareValues(rates[count-1].close,line);
   return true;
  }

bool ReadLiveSignal(SignalSnapshot &snapshot)
  {
   if(BarsCalculated(g_fast_ema_handle) < COPY_BARS ||
      BarsCalculated(g_slow_ema_handle) < COPY_BARS ||
      BarsCalculated(g_atr_handle) < COPY_BARS ||
      BarsCalculated(g_rsi_handle) < COPY_BARS)
     {
      g_status = "等待M5历史数据";
      return false;
     }

   MqlRates rates[];
   double atr[];
   double fast_ema[];
   double slow_ema[];
   double rsi[];
   ArraySetAsSeries(rates,false);
   ArraySetAsSeries(atr,false);
   ArraySetAsSeries(fast_ema,false);
   ArraySetAsSeries(slow_ema,false);
   ArraySetAsSeries(rsi,false);

   int rate_count = CopyRates(g_symbol,PERIOD_M5,0,COPY_BARS,rates);
   int atr_count = CopyBuffer(g_atr_handle,0,0,COPY_BARS,atr);
   int fast_count = CopyBuffer(g_fast_ema_handle,0,0,1,fast_ema);
   int slow_count = CopyBuffer(g_slow_ema_handle,0,0,1,slow_ema);
   int rsi_count = CopyBuffer(g_rsi_handle,0,0,1,rsi);

   if(rate_count != COPY_BARS || atr_count != COPY_BARS ||
      fast_count != 1 || slow_count != 1 || rsi_count != 1)
     {
      g_status = "M5数据复制未完成";
      return false;
     }

   int supertrend_vote = DIR_NONE;
   double supertrend_line = 0.0;
   if(!CalculateSupertrendVote(rates,atr,COPY_BARS,supertrend_vote,supertrend_line))
     {
      g_status = "Supertrend计算失败";
      return false;
     }

   MqlTick tick;
   if(!SymbolInfoTick(g_symbol,tick))
     {
      g_status = "无法读取最新报价";
      return false;
     }

   snapshot.fast_ema = fast_ema[0];
   snapshot.slow_ema = slow_ema[0];
   snapshot.rsi = rsi[0];
   snapshot.close = rates[COPY_BARS-1].close;
   snapshot.supertrend_line = supertrend_line;
   snapshot.ema_vote = CompareValues(snapshot.fast_ema,snapshot.slow_ema);
   snapshot.supertrend_vote = supertrend_vote;
   snapshot.rsi_vote = CompareValues(snapshot.rsi,InpRsiMidpoint);
   snapshot.candidate = MajorityVote(snapshot.ema_vote,
                                     snapshot.supertrend_vote,
                                     snapshot.rsi_vote);
   snapshot.tick_time_msc = tick.time_msc;
   snapshot.server_time = (datetime)tick.time;
   return true;
  }

void ResetSignalState()
  {
   g_confirmed_direction = DIR_NONE;
   g_pending_direction = DIR_NONE;
   g_pending_elapsed_ms = 0;
   g_last_pending_tick_ms = 0;
  }

bool AdvanceReversalState(const int candidate,const ulong now_ms)
  {
   if(g_confirmed_direction == DIR_NONE)
     {
      if(candidate != DIR_NONE)
         g_confirmed_direction = candidate;
      return false;
     }

   if(candidate == DIR_NONE || candidate == g_confirmed_direction)
     {
      g_pending_direction = DIR_NONE;
      g_pending_elapsed_ms = 0;
      g_last_pending_tick_ms = 0;
      return false;
     }

   if(g_pending_direction != candidate)
     {
      g_pending_direction = candidate;
      g_pending_elapsed_ms = 0;
      g_last_pending_tick_ms = now_ms;
      return false;
     }

   ulong delta_ms = now_ms >= g_last_pending_tick_ms
                    ? now_ms - g_last_pending_tick_ms
                    : 0;
   if(delta_ms <= (ulong)InpMaximumActiveTickGapMs)
      g_pending_elapsed_ms += delta_ms;
   g_last_pending_tick_ms = now_ms;

   if(g_pending_elapsed_ms < (ulong)InpHoldSeconds * 1000)
      return false;

   g_confirmed_direction = candidate;
   g_pending_direction = DIR_NONE;
   g_pending_elapsed_ms = 0;
   g_last_pending_tick_ms = 0;
   return true;
  }

void EmitReversalAlert(const int direction,const datetime server_time)
  {
   if(InpEnableSound)
     {
      string sound_file = direction == DIR_LONG ? InpLongSound : InpShortSound;
      ResetLastError();
      if(!PlaySound(sound_file))
         g_status = "声音播放失败：" + sound_file +
                    "（错误码 " + IntegerToString(GetLastError()) + "）";
     }

   if(InpEnablePopup)
      Alert(g_symbol," M5 多空转换：",DirectionText(direction),
            " @ ",TimeToString(server_time,TIME_DATE|TIME_SECONDS));
  }

void EnsureLabel(const string suffix,const int row)
  {
   string name = PANEL_PREFIX + suffix;
   if(ObjectFind(0,name) >= 0)
      return;
   ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpPanelX);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,InpPanelY + row*18);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
   ObjectSetString(0,name,OBJPROP_FONT,"Microsoft YaHei");
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
  }

void SetLabel(const string suffix,const int row,const string text,const color text_color)
  {
   EnsureLabel(suffix,row);
   string name = PANEL_PREFIX + suffix;
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetInteger(0,name,OBJPROP_COLOR,text_color);
  }

void RenderPanel()
  {
   string shown_symbol = g_symbol == "" ? InpSymbol : g_symbol;
   SetLabel("TITLE",0,shown_symbol + " · M5 多空转换监控",clrWhite);
   SetLabel("CONFIRMED",1,"已确认方向：" + DirectionText(g_confirmed_direction),
            DirectionColor(g_confirmed_direction));

   if(g_has_snapshot)
     {
      SetLabel("VOTES",2,
               "EMA " + DirectionText(g_snapshot.ema_vote) +
               " | Supertrend " + DirectionText(g_snapshot.supertrend_vote) +
               " | RSI " + DirectionText(g_snapshot.rsi_vote),
               InpNeutralColor);

      if(g_pending_direction != DIR_NONE)
        {
         double elapsed = (double)g_pending_elapsed_ms / 1000.0;
         double remaining = MathMax(0.0,(double)InpHoldSeconds-elapsed);
         SetLabel("PENDING",3,
                  "候选：" + DirectionText(g_pending_direction) +
                  "  已保持 " + DoubleToString(elapsed,1) +
                  " 秒，剩余 " + DoubleToString(remaining,1) + " 秒",
                  DirectionColor(g_pending_direction));
        }
      else
         SetLabel("PENDING",3,"候选：无",InpNeutralColor);
     }
   else
     {
      SetLabel("VOTES",2,"EMA - | Supertrend - | RSI -",InpNeutralColor);
      SetLabel("PENDING",3,"候选：无",InpNeutralColor);
     }

   bool is_error = StringFind(g_status,"失败") >= 0 ||
                   StringFind(g_status,"错误") >= 0 ||
                   StringFind(g_status,"找不到") >= 0;
   SetLabel("STATUS",4,"状态：" + g_status,is_error ? InpErrorColor : InpNeutralColor);
   ChartRedraw(0);
  }

bool IsNewTargetTick(MqlTick &tick)
  {
   if(!SymbolInfoTick(g_symbol,tick))
     {
      g_status = "无法读取最新报价";
      return false;
     }

   if(tick.time_msc == g_last_tick_time_msc &&
      tick.bid == g_last_tick_bid &&
      tick.ask == g_last_tick_ask)
      return false;

   g_last_tick_time_msc = tick.time_msc;
   g_last_tick_bid = tick.bid;
   g_last_tick_ask = tick.ask;
   return true;
  }

int OnInit()
  {
   if(!ValidateInputs())
     {
      RenderPanel();
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!ResolveTargetSymbol())
     {
      RenderPanel();
      return INIT_FAILED;
     }
   if(!CreateIndicatorHandles())
     {
      ReleaseResources();
      RenderPanel();
      return INIT_FAILED;
     }
   if(!EventSetMillisecondTimer(InpTimerMilliseconds))
     {
      g_status = "定时器创建失败，错误码 " + IntegerToString(GetLastError());
      ReleaseResources();
      RenderPanel();
      return INIT_FAILED;
     }

   IndicatorSetString(INDICATOR_SHORTNAME,"XAUUSD M5 Reversal Alert");
   g_status = "等待首个有效M5信号";
   RenderPanel();
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   ReleaseResources();
  }

int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
   return rates_total;
  }

void OnTimer()
  {
   if(g_symbol == "")
     {
      RenderPanel();
      return;
     }

   MqlTick target_tick;
   if(!IsNewTargetTick(target_tick))
      return;

   if(g_previous_server_tick_msc > 0 &&
      target_tick.time_msc - g_previous_server_tick_msc >
      (long)InpReconnectResetSeconds * 1000)
     {
      ResetSignalState();
      g_status = "报价恢复，正在静默重建基准";
     }
   g_previous_server_tick_msc = target_tick.time_msc;

   SignalSnapshot snapshot;
   if(!ReadLiveSignal(snapshot))
     {
      RenderPanel();
      return;
     }

   g_snapshot = snapshot;
   g_has_snapshot = true;
   bool confirmed = AdvanceReversalState(snapshot.candidate,GetTickCount64());
   if(confirmed)
     {
      g_status = "已确认" + DirectionText(g_confirmed_direction) + "头转换";
      EmitReversalAlert(g_confirmed_direction,snapshot.server_time);
     }
   else if(g_confirmed_direction == DIR_NONE)
      g_status = "等待至少两项指标同向";
   else if(g_pending_direction != DIR_NONE)
      g_status = "反向候选防抖确认中";
   else
      g_status = "监控正常";

   RenderPanel();
  }
