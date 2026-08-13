#property strict
#property copyright "Codex"
#property version "1.00"
#property description "Non-trading XAUUSD M5 reversal alerts with PushPlus."

enum SignalDirection { DIR_SHORT=-1, DIR_NONE=0, DIR_LONG=1 };
enum PushResponseParseResult
  {
   PUSH_CODE_MISSING=-1,
   PUSH_CODE_INVALID=0,
   PUSH_CODE_OK=1
  };

input string InpSymbol = "XAUUSD";
input int InpFastEmaPeriod = 7;
input int InpSlowEmaPeriod = 18;
input int InpAtrPeriod = 8;
input double InpSupertrendMultiplier = 2.4;
input int InpRsiPeriod = 9;
input double InpRsiNeutralLower = 48.0;
input double InpRsiNeutralUpper = 52.0;
input double InpCandidateEntryScore = 55.0;
input double InpDirectionMaintenanceScore = 35.0;
input double InpMinimumConfirmationSeconds = 3.0;
input double InpMaximumConfirmationSeconds = 10.0;
input double InpEmaDistanceWeight = 25.0;
input double InpEmaSlopeWeight = 10.0;
input double InpSupertrendWeight = 40.0;
input double InpRsiWeight = 25.0;
input double InpEmaDistanceAtrScale = 0.20;
input double InpEmaSlopeAtrScale = 0.08;
input double InpSupertrendAtrScale = 0.50;
input int InpTimerMilliseconds = 100;
input int InpMaximumActiveTickGapMs = 1000;
input int InpReconnectResetSeconds = 60;
input bool InpEnableSound = true;
input string InpLongSound = "alert.wav";
input string InpShortSound = "timeout.wav";
input bool InpEnablePopup = false;
input bool InpEnableLargeNotification = true;
input int InpLargeNotificationSeconds = 15;
input bool   InpEnablePushPlus = true;
input string InpPushPlusToken = "";
input string InpPushPlusUrl = "https://www.pushplus.plus/send";
input string InpPushPlusChannel = "app";
input string InpPushPlusTemplate = "txt";
input int    InpPushPlusTimeoutMs = 5000;
input bool   InpSendStartupTest = false;
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;
input int InpPanelX = 12;
input int InpPanelY = 18;
input color InpLongColor = clrLimeGreen;
input color InpShortColor = clrTomato;
input color InpNeutralColor = clrSilver;
input color InpErrorColor = clrOrangeRed;

struct ScoreSnapshot
  {
   double ema_score,supertrend_score,rsi_score,total_score,required_seconds;
   double fast_ema,slow_ema,supertrend_line,rsi,close;
   long tick_time_msc;
   datetime server_time;
  };

const int MAX_INDICATOR_PERIOD=500;
const int MAX_HISTORY_BARS=5000;
string g_symbol="",g_status="正在初始化",g_push_status="未发送";
string g_sound_warning="",g_push_warning="";
string g_panel_prefix="";
bool g_inputs_valid=false,g_runtime_ready=false,g_has_snapshot=false;
bool g_startup_test_attempted=false;
int g_fast_ema_handle=INVALID_HANDLE,g_slow_ema_handle=INVALID_HANDLE;
int g_atr_handle=INVALID_HANDLE,g_rsi_handle=INVALID_HANDLE;
int g_confirmed_direction=DIR_NONE,g_pending_direction=DIR_NONE;
double g_confirmation_progress=0.0,g_pending_required_seconds=0.0;
ulong g_last_confirmation_tick_ms=0;
bool g_has_last_confirmation_tick=false;
bool g_st_cache_ready=false,g_st_long_trend=false;
double g_st_final_upper=0.0,g_st_final_lower=0.0,g_st_previous_close=0.0;
double g_st_committed_open=0.0,g_st_committed_high=0.0;
double g_st_committed_low=0.0,g_st_committed_atr=0.0;
datetime g_st_committed_time=0,g_st_active_time=0;
long g_last_tick_time_msc=0,g_previous_server_tick_msc=0;
double g_last_tick_bid=0.0,g_last_tick_ask=0.0;
bool g_large_visible=false;
ulong g_large_hide_at_ms=0;
int g_large_font_size=15;
int g_large_title_font_size=28;
ScoreSnapshot g_snapshot;

string DirectionText(const int direction)
  {
   if(direction==DIR_LONG) return "多";
   if(direction==DIR_SHORT) return "空";
   return "中性";
  }
color DirectionColor(const int direction)
  {
   if(direction==DIR_LONG) return InpLongColor;
   if(direction==DIR_SHORT) return InpShortColor;
   return InpNeutralColor;
  }
bool ValidateInputs()
  {
   if(StringLen(InpSymbol)==0) { g_status="参数错误：品种名为空"; return false; }
   if(InpFastEmaPeriod<1 || InpSlowEmaPeriod<1 ||
      InpFastEmaPeriod>=InpSlowEmaPeriod ||
      InpFastEmaPeriod>MAX_INDICATOR_PERIOD || InpSlowEmaPeriod>MAX_INDICATOR_PERIOD)
     { g_status="参数错误：EMA周期"; return false; }
   if(InpAtrPeriod<1 || InpAtrPeriod>MAX_INDICATOR_PERIOD ||
      !MathIsValidNumber(InpSupertrendMultiplier) || InpSupertrendMultiplier<=0.0)
     { g_status="参数错误：Supertrend参数"; return false; }
   if(InpRsiPeriod<1 || InpRsiPeriod>MAX_INDICATOR_PERIOD ||
      !MathIsValidNumber(InpRsiNeutralLower) ||
      !MathIsValidNumber(InpRsiNeutralUpper) ||
      InpRsiNeutralLower<0.0 || InpRsiNeutralLower>=50.0 ||
      InpRsiNeutralUpper<=50.0 || InpRsiNeutralUpper>100.0)
     { g_status="参数错误：RSI参数"; return false; }
   double weight_sum=InpEmaDistanceWeight+InpEmaSlopeWeight+
                     InpSupertrendWeight+InpRsiWeight;
   if(!MathIsValidNumber(InpEmaDistanceWeight) ||
      !MathIsValidNumber(InpEmaSlopeWeight) ||
      !MathIsValidNumber(InpSupertrendWeight) ||
      !MathIsValidNumber(InpRsiWeight) ||
      InpEmaDistanceWeight<=0.0 || InpEmaSlopeWeight<=0.0 ||
      InpSupertrendWeight<=0.0 || InpRsiWeight<=0.0 ||
      !MathIsValidNumber(weight_sum) || MathAbs(weight_sum-100.0)>1e-6)
     { g_status="参数错误：评分权重"; return false; }
   if(!MathIsValidNumber(InpCandidateEntryScore) ||
      !MathIsValidNumber(InpDirectionMaintenanceScore) ||
      InpDirectionMaintenanceScore<=0.0 ||
      InpDirectionMaintenanceScore>=InpCandidateEntryScore ||
      InpCandidateEntryScore>100.0)
     { g_status="参数错误：评分阈值"; return false; }
   if(!MathIsValidNumber(InpMinimumConfirmationSeconds) ||
      !MathIsValidNumber(InpMaximumConfirmationSeconds) ||
      InpMinimumConfirmationSeconds<=0.0 ||
      InpMinimumConfirmationSeconds>InpMaximumConfirmationSeconds)
     { g_status="参数错误：确认时间"; return false; }
   if(!MathIsValidNumber(InpEmaDistanceAtrScale) ||
      !MathIsValidNumber(InpEmaSlopeAtrScale) ||
      !MathIsValidNumber(InpSupertrendAtrScale) ||
      InpEmaDistanceAtrScale<=0.0 || InpEmaSlopeAtrScale<=0.0 ||
      InpSupertrendAtrScale<=0.0)
     { g_status="参数错误：标准化尺度"; return false; }
   if(InpTimerMilliseconds<50 ||
      InpMaximumActiveTickGapMs<=0 || InpReconnectResetSeconds<=0 ||
      InpPushPlusTimeoutMs<=0 || InpLargeNotificationSeconds<=0)
     { g_status="参数错误：运行计时"; return false; }
   return true;
  }
bool ResolveTargetSymbol()
  {
   if(SymbolSelect(InpSymbol,true)) { g_symbol=InpSymbol; return true; }
   string needle=InpSymbol; StringToUpper(needle);
   for(int i=0;i<SymbolsTotal(false);i++)
     {
      string candidate=SymbolName(i,false),upper=candidate; StringToUpper(upper);
      if(StringFind(upper,needle)>=0 && SymbolSelect(candidate,true))
        { g_symbol=candidate; return true; }
     }
   g_status="找不到品种："+InpSymbol;
   return false;
  }
void ReleaseHandles()
  {
   if(g_fast_ema_handle!=INVALID_HANDLE) IndicatorRelease(g_fast_ema_handle);
   if(g_slow_ema_handle!=INVALID_HANDLE) IndicatorRelease(g_slow_ema_handle);
   if(g_atr_handle!=INVALID_HANDLE) IndicatorRelease(g_atr_handle);
   if(g_rsi_handle!=INVALID_HANDLE) IndicatorRelease(g_rsi_handle);
   g_fast_ema_handle=g_slow_ema_handle=g_atr_handle=g_rsi_handle=INVALID_HANDLE;
   g_runtime_ready=false; g_st_cache_ready=false; g_st_active_time=0;
  }
bool CreateIndicatorHandles()
  {
   ReleaseHandles();
   g_fast_ema_handle=iMA(g_symbol,PERIOD_M5,InpFastEmaPeriod,0,MODE_EMA,PRICE_CLOSE);
   g_slow_ema_handle=iMA(g_symbol,PERIOD_M5,InpSlowEmaPeriod,0,MODE_EMA,PRICE_CLOSE);
   g_atr_handle=iATR(g_symbol,PERIOD_M5,InpAtrPeriod);
   g_rsi_handle=iRSI(g_symbol,PERIOD_M5,InpRsiPeriod,PRICE_CLOSE);
   if(g_fast_ema_handle==INVALID_HANDLE || g_slow_ema_handle==INVALID_HANDLE ||
      g_atr_handle==INVALID_HANDLE || g_rsi_handle==INVALID_HANDLE)
     { g_status="指标句柄创建失败，错误码 "+IntegerToString(GetLastError()); ReleaseHandles(); return false; }
   return true;
  }
bool TryInitializeRuntime()
  {
   if(!g_inputs_valid) return false;
   if(g_runtime_ready) return true;
   if(g_symbol=="" && !ResolveTargetSymbol()) return false;
   if(g_atr_handle==INVALID_HANDLE && !CreateIndicatorHandles()) return false;
   if(!InitializeSupertrendCache()) return false;
   g_runtime_ready=true; g_status="等待首个有效M5信号";
   return true;
  }
int RequiredHistoryBars()
  {
   int scaled=(InpAtrPeriod>MAX_HISTORY_BARS/10) ?
              MAX_HISTORY_BARS : InpAtrPeriod*10;
   return MathMin(MAX_HISTORY_BARS,MathMax(200,scaled));
  }
double ClampUnit(const double value)
  { return MathMax(-1.0,MathMin(1.0,value)); }
bool AdvanceSupertrendValues(const MqlRates &bar,const double atr,
                             double &upper,double &lower,bool &long_trend,
                             double &previous_close,const bool initialized)
  {
   if(!MathIsValidNumber(bar.open) || !MathIsValidNumber(bar.high) ||
      !MathIsValidNumber(bar.low) || !MathIsValidNumber(bar.close) ||
      !MathIsValidNumber(atr) || atr<=0.0)
      return false;
   double midpoint=(bar.high+bar.low)*0.5;
   double basic_upper=midpoint+InpSupertrendMultiplier*atr;
   double basic_lower=midpoint-InpSupertrendMultiplier*atr;
   if(!MathIsValidNumber(midpoint) || !MathIsValidNumber(basic_upper) ||
      !MathIsValidNumber(basic_lower))
      return false;
   if(!initialized)
     {
      upper=basic_upper; lower=basic_lower;
      long_trend=bar.close>=midpoint;
     }
   else
     {
      double final_upper=(basic_upper>=upper && previous_close<=upper) ?
                         upper : basic_upper;
      double final_lower=(basic_lower<=lower && previous_close>=lower) ?
                         lower : basic_lower;
      if(long_trend && bar.close<final_lower) long_trend=false;
      else if(!long_trend && bar.close>final_upper) long_trend=true;
      upper=final_upper; lower=final_lower;
     }
   previous_close=bar.close;
   return true;
  }
bool InitializeSupertrendCache()
  {
   ResetSignalState();
   int count=RequiredHistoryBars();
   if(BarsCalculated(g_atr_handle)<count+1)
     { g_status="等待M5历史数据"; return false; }
   MqlRates rates[]; double atr[];
   ArraySetAsSeries(rates,false); ArraySetAsSeries(atr,false);
   if(CopyRates(g_symbol,PERIOD_M5,1,count,rates)!=count ||
      CopyBuffer(g_atr_handle,0,1,count,atr)!=count)
     { g_status="M5历史缓存未就绪"; return false; }
   double upper=0.0,lower=0.0,previous_close=0.0;
   bool long_trend=false,initialized=false;
   datetime committed_time=0;
   for(int i=0;i<count;i++)
     {
      if(!AdvanceSupertrendValues(rates[i],atr[i],upper,lower,long_trend,
                                  previous_close,initialized))
         return false;
      initialized=true; committed_time=rates[i].time;
     }
   if(!initialized) return false;
   g_st_final_upper=upper; g_st_final_lower=lower;
   g_st_long_trend=long_trend; g_st_previous_close=previous_close;
   g_st_committed_open=rates[count-1].open;
   g_st_committed_high=rates[count-1].high;
   g_st_committed_low=rates[count-1].low;
   g_st_committed_atr=atr[count-1];
   g_st_committed_time=committed_time; g_st_active_time=0;
   g_st_cache_ready=true;
   return true;
  }
bool PreviewCurrentSupertrend(const MqlRates &bar,const double atr,double &line)
  {
   if(!g_st_cache_ready || bar.time<=g_st_committed_time) return false;
   double upper=g_st_final_upper,lower=g_st_final_lower;
   double previous_close=g_st_previous_close;
   bool long_trend=g_st_long_trend;
   if(!AdvanceSupertrendValues(bar,atr,upper,lower,long_trend,
                               previous_close,true))
      return false;
   line=long_trend ? lower : upper;
   return MathIsValidNumber(line);
  }
bool SynchronizeSupertrendCache(const MqlRates &current_bar,
                                const MqlRates &previous_bar,
                                const double previous_atr)
  {
   if(!g_st_cache_ready) return InitializeSupertrendCache();
   if(current_bar.time<=g_st_committed_time ||
      (g_st_active_time!=0 && current_bar.time<g_st_active_time))
      return InitializeSupertrendCache();
   if(g_st_active_time==0)
     {
      if(previous_bar.time!=g_st_committed_time ||
         previous_bar.open!=g_st_committed_open ||
         previous_bar.high!=g_st_committed_high ||
         previous_bar.low!=g_st_committed_low ||
         previous_bar.close!=g_st_previous_close ||
         previous_atr!=g_st_committed_atr)
         return InitializeSupertrendCache();
      g_st_active_time=current_bar.time;
      return true;
     }
   if(current_bar.time==g_st_active_time)
     {
      if(previous_bar.time!=g_st_committed_time ||
         previous_bar.open!=g_st_committed_open ||
         previous_bar.high!=g_st_committed_high ||
         previous_bar.low!=g_st_committed_low ||
         previous_bar.close!=g_st_previous_close ||
         previous_atr!=g_st_committed_atr)
         return InitializeSupertrendCache();
      return true;
     }
   if(previous_bar.time!=g_st_active_time ||
      previous_bar.time<=g_st_committed_time)
      return InitializeSupertrendCache();
   double upper=g_st_final_upper,lower=g_st_final_lower;
   double previous_close=g_st_previous_close;
   bool long_trend=g_st_long_trend;
   if(!AdvanceSupertrendValues(previous_bar,previous_atr,upper,lower,
                               long_trend,previous_close,true))
      return false;
   g_st_final_upper=upper; g_st_final_lower=lower;
   g_st_long_trend=long_trend; g_st_previous_close=previous_close;
   g_st_committed_open=previous_bar.open;
   g_st_committed_high=previous_bar.high;
   g_st_committed_low=previous_bar.low;
   g_st_committed_atr=previous_atr;
   g_st_committed_time=previous_bar.time; g_st_active_time=current_bar.time;
   return true;
  }
bool ReadAdaptiveSignal(ScoreSnapshot &snapshot)
  {
   if(BarsCalculated(g_fast_ema_handle)<2 ||
      BarsCalculated(g_slow_ema_handle)<1 ||
      BarsCalculated(g_atr_handle)<2 || BarsCalculated(g_rsi_handle)<1)
     { g_status="等待M5历史数据"; return false; }
   MqlRates rates[]; double atr[],fast[],slow[],rsi[];
   ArraySetAsSeries(rates,true); ArraySetAsSeries(atr,true);
   ArraySetAsSeries(fast,true); ArraySetAsSeries(slow,true);
   ArraySetAsSeries(rsi,true);
   if(CopyRates(g_symbol,PERIOD_M5,0,2,rates)!=2 ||
      CopyBuffer(g_atr_handle,0,0,2,atr)!=2 ||
      CopyBuffer(g_fast_ema_handle,0,0,2,fast)!=2 ||
      CopyBuffer(g_slow_ema_handle,0,0,1,slow)!=1 ||
      CopyBuffer(g_rsi_handle,0,0,1,rsi)!=1)
     { g_status="M5数据复制未完成"; return false; }
   if(!SynchronizeSupertrendCache(rates[0],rates[1],atr[1])) return false;
   double supertrend_line=0.0;
   if(!PreviewCurrentSupertrend(rates[0],atr[0],supertrend_line)) return false;
   MqlTick tick; if(!SymbolInfoTick(g_symbol,tick)) return false;
   double price=tick.bid;
   if(!MathIsValidNumber(fast[0]) || !MathIsValidNumber(fast[1]) ||
      !MathIsValidNumber(slow[0]) || !MathIsValidNumber(atr[0]) ||
      !MathIsValidNumber(rsi[0]) || !MathIsValidNumber(price) ||
      !MathIsValidNumber(supertrend_line) || atr[0]<=0.0 || price<=0.0)
     { g_status="M5评分数据无效"; return false; }
   snapshot.ema_score=
      InpEmaDistanceWeight*
      ClampUnit((fast[0]-slow[0])/(InpEmaDistanceAtrScale*atr[0]))+
      InpEmaSlopeWeight*
      ClampUnit((fast[0]-fast[1])/(InpEmaSlopeAtrScale*atr[0]));
   snapshot.supertrend_score=InpSupertrendWeight*
      ClampUnit((price-supertrend_line)/(InpSupertrendAtrScale*atr[0]));
   snapshot.rsi_score=0.0;
   if(rsi[0]>InpRsiNeutralUpper)
      snapshot.rsi_score=InpRsiWeight*
         ClampUnit((rsi[0]-InpRsiNeutralUpper)/8.0);
   else if(rsi[0]<InpRsiNeutralLower)
      snapshot.rsi_score=InpRsiWeight*
         ClampUnit((rsi[0]-InpRsiNeutralLower)/8.0);
   if(!MathIsValidNumber(snapshot.ema_score) ||
      !MathIsValidNumber(snapshot.supertrend_score) ||
      !MathIsValidNumber(snapshot.rsi_score))
     { g_status="M5评分结果无效"; return false; }
   snapshot.total_score=MathMax(-100.0,MathMin(100.0,
      snapshot.ema_score+snapshot.supertrend_score+snapshot.rsi_score));
   snapshot.required_seconds=RequiredConfirmationSeconds(snapshot.total_score);
   snapshot.fast_ema=fast[0]; snapshot.slow_ema=slow[0];
   snapshot.rsi=rsi[0]; snapshot.close=price;
   snapshot.supertrend_line=supertrend_line;
   snapshot.tick_time_msc=tick.time_msc;
   snapshot.server_time=(datetime)tick.time;
   return true;
  }
void ResetSignalState()
  {
   g_confirmed_direction=g_pending_direction=DIR_NONE;
   g_confirmation_progress=0.0; g_pending_required_seconds=0.0;
   g_last_confirmation_tick_ms=0; g_has_last_confirmation_tick=false;
  }
double RequiredConfirmationSeconds(const double score)
  {
   double required=InpMaximumConfirmationSeconds-
      (MathAbs(score)-InpCandidateEntryScore)*
      (InpMaximumConfirmationSeconds-InpMinimumConfirmationSeconds)/25.0;
   return MathMax(InpMinimumConfirmationSeconds,
                  MathMin(InpMaximumConfirmationSeconds,required));
  }
int ScoreDirection(const double score,const double threshold)
  {
   if(score>=threshold) return DIR_LONG;
   if(score<=-threshold) return DIR_SHORT;
   return DIR_NONE;
  }
bool AdvanceAdaptiveState(const double score,const ulong now_ms)
  {
   if(!MathIsValidNumber(score)) return false;
   int entry_direction=ScoreDirection(score,InpCandidateEntryScore);
   if(g_confirmed_direction==DIR_NONE && g_pending_direction==DIR_NONE &&
      entry_direction!=DIR_NONE)
     {
      g_confirmed_direction=entry_direction;
      g_last_confirmation_tick_ms=now_ms;
      g_has_last_confirmation_tick=true;
      return false;
     }
   ulong delta_ms=0;
   if(g_has_last_confirmation_tick && now_ms>=g_last_confirmation_tick_ms)
      delta_ms=now_ms-g_last_confirmation_tick_ms;
   double active_seconds=delta_ms<=(ulong)InpMaximumActiveTickGapMs ?
                         (double)delta_ms/1000.0 : 0.0;
   g_last_confirmation_tick_ms=now_ms;
   g_has_last_confirmation_tick=true;
   if(entry_direction==g_confirmed_direction)
     {
      g_pending_direction=DIR_NONE; g_confirmation_progress=0.0;
      g_pending_required_seconds=0.0;
      return false;
     }
   if(entry_direction!=DIR_NONE && entry_direction!=g_pending_direction)
     {
      g_pending_direction=entry_direction;
      g_pending_required_seconds=RequiredConfirmationSeconds(score);
      g_confirmation_progress=ClampUnit(
         active_seconds/RequiredConfirmationSeconds(score));
      g_confirmation_progress=MathMax(0.0,g_confirmation_progress);
      return false;
     }
   if(g_pending_direction==DIR_NONE) return false;
   int maintenance_direction=
      ScoreDirection(score,InpDirectionMaintenanceScore);
   if(maintenance_direction==-g_pending_direction)
     {
      g_pending_direction=DIR_NONE; g_confirmation_progress=0.0;
      g_pending_required_seconds=0.0;
      return false;
     }
   if(entry_direction==g_pending_direction)
     {
      g_pending_required_seconds=RequiredConfirmationSeconds(score);
      g_confirmation_progress+=
         active_seconds/RequiredConfirmationSeconds(score);
      if(g_confirmation_progress>=1.0)
        {
         g_confirmed_direction=g_pending_direction;
         g_pending_direction=DIR_NONE; g_confirmation_progress=0.0;
         g_pending_required_seconds=0.0;
         g_has_last_confirmation_tick=true;
         return true;
        }
     }
   else if(maintenance_direction==g_pending_direction)
      g_confirmation_progress-=
         active_seconds/InpMaximumConfirmationSeconds*0.5;
   else
      g_confirmation_progress-=
         active_seconds/InpMaximumConfirmationSeconds;
   g_confirmation_progress=MathMax(0.0,MathMin(1.0,
                                               g_confirmation_progress));
   if(g_confirmation_progress<=0.0)
     { g_pending_direction=DIR_NONE; g_pending_required_seconds=0.0; }
   return false;
  }
string JsonEscape(string value)
  {
   StringReplace(value,"\\","\\\\");
   StringReplace(value,"\"","\\\"");
   StringReplace(value,"\n","\\n");
   StringReplace(value,"\r","\\r");
   StringReplace(value,"\t","\\t");
   return value;
  }
string BuildReversalTitle(const int previous_direction,const int direction)
  {
   string transition=(previous_direction==DIR_SHORT && direction==DIR_LONG) ? "空转多提醒" : "多转空提醒";
   return g_symbol+" M5 "+transition;
  }
string BuildReversalContent(const int previous_direction,const int direction,
                            const ScoreSnapshot &s)
  {
   string transition=(previous_direction==DIR_SHORT && direction==DIR_LONG) ? "空转多" : "多转空";
   return "品种："+g_symbol+"\n周期：M5\n方向："+transition+
          "\n服务器时间："+TimeToString(s.server_time,TIME_DATE|TIME_SECONDS)+
          "\nEMA："+DoubleToString(s.ema_score,1)+
          "\nSupertrend："+DoubleToString(s.supertrend_score,1)+
          "\nRSI："+DoubleToString(s.rsi_score,1)+
          "\n确认时间："+DoubleToString(s.required_seconds,1)+" 秒";
  }
bool IsJsonWhitespace(const ushort ch)
  { return ch==' ' || ch=='\t' || ch=='\r' || ch=='\n'; }
void SkipJsonWhitespace(const string text,int &index)
  {
   int length=StringLen(text);
   while(index<length && IsJsonWhitespace((ushort)StringGetCharacter(text,index))) index++;
  }
bool ParseJsonString(const string text,int &index,string &value)
  {
   int length=StringLen(text);
   if(index>=length || StringGetCharacter(text,index)!='"') return false;
   index++; value="";
   while(index<length)
     {
      ushort ch=(ushort)StringGetCharacter(text,index++);
      if(ch=='"') return true;
      if(ch=='\\')
        {
         if(index>=length) return false;
         ushort escaped=(ushort)StringGetCharacter(text,index++);
         if(escaped=='"' || escaped=='\\' || escaped=='/') value+=ShortToString(escaped);
         else if(escaped=='b') value+=ShortToString(8);
         else if(escaped=='f') value+=ShortToString(12);
         else if(escaped=='n') value+="\n";
         else if(escaped=='r') value+="\r";
         else if(escaped=='t') value+="\t";
         else return false;
        }
      else if(ch<32) return false;
      else value+=ShortToString(ch);
     }
   return false;
  }
bool SkipJsonValue(const string text,int &index)
  {
   int length=StringLen(text);
   SkipJsonWhitespace(text,index);
   if(index>=length) return false;
   ushort first=(ushort)StringGetCharacter(text,index);
   if(first=='"')
     { string ignored; return ParseJsonString(text,index,ignored); }
   if(first=='{' || first=='[')
     {
      ushort open=first,close=(first=='{' ? '}' : ']');
      int depth=0; bool in_string=false,escaped=false;
      while(index<length)
        {
         ushort ch=(ushort)StringGetCharacter(text,index++);
         if(in_string)
           {
            if(escaped) escaped=false;
            else if(ch=='\\') escaped=true;
            else if(ch=='"') in_string=false;
            continue;
           }
         if(ch=='"') in_string=true;
         else if(ch==open) depth++;
         else if(ch==close)
           { depth--; if(depth==0) return true; }
        }
      return false;
     }
   int start=index;
   while(index<length)
     {
      ushort ch=(ushort)StringGetCharacter(text,index);
      if(ch==',' || ch=='}' || ch==']' || IsJsonWhitespace(ch)) break;
      index++;
     }
   if(index==start) return false;
   string literal=StringSubstr(text,start,index-start);
   if(literal=="true" || literal=="false" || literal=="null") return true;
   int p=0,literal_length=StringLen(literal);
   if(StringGetCharacter(literal,p)=='-') p++;
   if(p>=literal_length) return false;
   if(StringGetCharacter(literal,p)=='0') p++;
   else
     {
      ushort digit=(ushort)StringGetCharacter(literal,p);
      if(digit<'1' || digit>'9') return false;
      while(p<literal_length)
        {
         digit=(ushort)StringGetCharacter(literal,p);
         if(digit<'0' || digit>'9') break;
         p++;
        }
     }
   return p==literal_length;
  }
PushResponseParseResult ParseTopLevelBusinessCode(const string response,int &code)
  {
   int length=StringLen(response),index=0;
   SkipJsonWhitespace(response,index);
   if(index>=length || StringGetCharacter(response,index)!='{') return PUSH_CODE_INVALID;
   index++;
   bool code_found=false;
   bool expect_member=false;
   while(index<length)
     {
      SkipJsonWhitespace(response,index);
      if(index<length && StringGetCharacter(response,index)=='}')
        {
         if(expect_member) return PUSH_CODE_INVALID;
         index++; SkipJsonWhitespace(response,index);
         if(index!=length) return PUSH_CODE_INVALID;
         return code_found ? PUSH_CODE_OK : PUSH_CODE_MISSING;
        }
      string key="";
      if(!ParseJsonString(response,index,key)) return PUSH_CODE_INVALID;
      SkipJsonWhitespace(response,index);
      if(index>=length || StringGetCharacter(response,index)!=':') return PUSH_CODE_INVALID;
      index++; SkipJsonWhitespace(response,index);
      if(key=="code")
        {
         if(code_found) return PUSH_CODE_INVALID;
         bool quoted=false;
         if(index<length && StringGetCharacter(response,index)=='"') { quoted=true; index++; }
         int value_start=index;
         if(index<length && StringGetCharacter(response,index)=='-') index++;
         int digit_start=index;
         while(index<length)
           {
            ushort digit=(ushort)StringGetCharacter(response,index);
            if(digit<'0' || digit>'9') break;
            index++;
           }
         if(index==digit_start) return PUSH_CODE_INVALID;
         int value_end=index;
         if(quoted)
           {
            if(index>=length || StringGetCharacter(response,index)!='"') return PUSH_CODE_INVALID;
            index++;
           }
         code=(int)StringToInteger(StringSubstr(response,value_start,value_end-value_start));
         code_found=true;
        }
      else if(!SkipJsonValue(response,index)) return PUSH_CODE_INVALID;
      SkipJsonWhitespace(response,index);
      if(index<length && StringGetCharacter(response,index)==',')
        { index++; expect_member=true; continue; }
      if(index<length && StringGetCharacter(response,index)=='}') continue;
      return PUSH_CODE_INVALID;
     }
   return PUSH_CODE_INVALID;
  }
bool SendPushPlus(const string title,const string content)
  {
   if(!InpEnablePushPlus) { g_push_status="已关闭"; return false; }
   if(StringLen(InpPushPlusToken)==0)
     { g_push_status="Token 未配置"; g_push_warning="PushPlus Token 未配置"; return false; }
   string json="{\"token\":\""+JsonEscape(InpPushPlusToken)+"\","+
               "\"title\":\""+JsonEscape(title)+"\","+
               "\"content\":\""+JsonEscape(content)+"\","+
               "\"template\":\""+JsonEscape(InpPushPlusTemplate)+"\","+
               "\"channel\":\""+JsonEscape(InpPushPlusChannel)+"\"}";
   char post[],result[];
   int bytes=StringToCharArray(json,post,0,WHOLE_ARRAY,CP_UTF8);
   if(bytes>0) ArrayResize(post,bytes-1);
   string headers="Content-Type: application/json; charset=utf-8\r\n";
   string response_headers;
   ResetLastError();
   int http=WebRequest("POST",InpPushPlusUrl,headers,InpPushPlusTimeoutMs,
                       post,result,response_headers);
   if(http==-1)
     { int error=GetLastError(); g_push_status="请求失败，MT5错误 "+IntegerToString(error);
       g_push_warning="PushPlus 请求失败，请检查 WebRequest 白名单"; Print(g_push_status); return false; }
   if(http!=200)
     { g_push_status="HTTP "+IntegerToString(http); g_push_warning=g_push_status;
       Print("PushPlus ",g_push_status); return false; }
   string response=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   int code=0;
   PushResponseParseResult parsed=ParseTopLevelBusinessCode(response,code);
   if(parsed==PUSH_CODE_MISSING)
     { g_push_status="响应缺少业务码"; g_push_warning=g_push_status; Print("PushPlus ",g_push_status); return false; }
   if(parsed==PUSH_CODE_INVALID)
     { g_push_status="响应业务码格式无效"; g_push_warning=g_push_status; Print("PushPlus ",g_push_status); return false; }
   if(code!=200)
     { g_push_status="业务码 "+IntegerToString(code); g_push_warning=g_push_status;
       Print("PushPlus ",g_push_status); return false; }
   g_push_status="服务端已接收"; g_push_warning="";
   return true;
  }
string LargeObjectName(const string suffix)
  { return g_panel_prefix+suffix; }
void HideLargeNotification()
  {
   ObjectDelete(0,LargeObjectName("LARGE_BG"));
   ObjectDelete(0,LargeObjectName("LARGE_TITLE"));
   ObjectDelete(0,LargeObjectName("LARGE_BODY"));
   ObjectDelete(0,LargeObjectName("LARGE_COUNTDOWN"));
   ObjectDelete(0,LargeObjectName("LARGE_CLOSE"));
   g_large_visible=false;
   g_large_hide_at_ms=0;
   ChartRedraw(0);
  }
void PositionLargeObject(const string suffix,const int x,const int y)
  {
   string name=LargeObjectName(suffix);
   if(ObjectFind(0,name)<0) return;
   ObjectSetInteger(0,name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,y);
  }
void CenterLargeNotification()
  {
   if(!g_large_visible) return;
   long chart_width=0,chart_height=0;
   if(!ChartGetInteger(0,CHART_WIDTH_IN_PIXELS,0,chart_width) ||
      !ChartGetInteger(0,CHART_HEIGHT_IN_PIXELS,0,chart_height))
      return;
   int available_width=(int)MathMax(1,chart_width-4);
   int available_height=(int)MathMax(1,chart_height-4);
   int box_width=(int)MathMin(560,available_width);
   int box_height=(int)MathMin(300,available_height);
   bool compact=(box_width<440 || box_height<260);
   bool tiny=(box_width<260 || box_height<190);
   g_large_font_size=tiny ? 8 : compact ? 11 : 15;
   g_large_title_font_size=tiny ? 12 : compact ? 20 : 28;
   int padding=tiny ? 5 : compact ? 16 : 30;
   int title_top=tiny ? 4 : compact ? 18 : 28;
   int body_top=tiny ? 34 : compact ? 60 : 82;
   int left=(int)MathMax(0,(chart_width-box_width)/2);
   int top=(int)MathMax(0,(chart_height-box_height)/2);
   string bg=LargeObjectName("LARGE_BG");
   ObjectSetInteger(0,bg,OBJPROP_XSIZE,box_width);
   ObjectSetInteger(0,bg,OBJPROP_YSIZE,box_height);
   PositionLargeObject("LARGE_BG",left,top);
   PositionLargeObject("LARGE_TITLE",left+padding,top+title_top);
   PositionLargeObject("LARGE_BODY",left+padding,top+body_top);
   PositionLargeObject("LARGE_COUNTDOWN",left+padding,
                       top+MathMax(body_top+40,box_height-(tiny ? 16 : 34)));
   PositionLargeObject("LARGE_CLOSE",left+MathMax(0,box_width-(tiny ? 22 : 42)),
                       top+(tiny ? 2 : 8));
   ObjectSetInteger(0,LargeObjectName("LARGE_TITLE"),OBJPROP_FONTSIZE,
                    g_large_title_font_size);
   ObjectSetInteger(0,LargeObjectName("LARGE_BODY"),OBJPROP_FONTSIZE,
                    g_large_font_size);
   ObjectSetInteger(0,LargeObjectName("LARGE_COUNTDOWN"),OBJPROP_FONTSIZE,
                    MathMax(9,g_large_font_size-3));
   ChartRedraw(0);
  }
void CreateLargeLabel(const string suffix,const string text,const int font_size,
                      const color text_color)
  {
   string name=LargeObjectName(suffix);
   if(ObjectFind(0,name)<0) ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetString(0,name,OBJPROP_TEXT,text);
   ObjectSetString(0,name,OBJPROP_FONT,"Microsoft YaHei");
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,font_size);
   ObjectSetInteger(0,name,OBJPROP_COLOR,text_color);
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,name,OBJPROP_ZORDER,1);
  }
void ShowLargeNotification(const int previous_direction,const int direction,
                           const ScoreSnapshot &s)
  {
   if(!InpEnableLargeNotification) return;
   HideLargeNotification();
   string transition=(previous_direction==DIR_SHORT && direction==DIR_LONG)
                     ? "空转多" : "多转空";
   color accent=direction==DIR_LONG ? InpLongColor : InpShortColor;
   string bg=LargeObjectName("LARGE_BG");
   ObjectCreate(0,bg,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,bg,OBJPROP_BGCOLOR,C'18,22,28');
   ObjectSetInteger(0,bg,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,bg,OBJPROP_COLOR,accent);
   ObjectSetInteger(0,bg,OBJPROP_WIDTH,4);
   ObjectSetInteger(0,bg,OBJPROP_BACK,false);
   ObjectSetInteger(0,bg,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,bg,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,bg,OBJPROP_ZORDER,1);

   CreateLargeLabel("LARGE_TITLE",g_symbol+" · M5  "+transition,28,accent);
   string body="服务器时间："+TimeToString(s.server_time,TIME_DATE|TIME_SECONDS)+
               "\nEMA："+DoubleToString(s.ema_score,1)+
               "\nSupertrend："+DoubleToString(s.supertrend_score,1)+
               "\nRSI："+DoubleToString(s.rsi_score,1)+
               "\nPushPlus："+g_push_status;
   CreateLargeLabel("LARGE_BODY",body,15,clrWhite);
   CreateLargeLabel("LARGE_COUNTDOWN","",12,clrSilver);

   string close_name=LargeObjectName("LARGE_CLOSE");
   ObjectCreate(0,close_name,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,close_name,OBJPROP_XSIZE,36);
   ObjectSetInteger(0,close_name,OBJPROP_YSIZE,28);
   ObjectSetString(0,close_name,OBJPROP_TEXT,"×");
   ObjectSetString(0,close_name,OBJPROP_FONT,"Microsoft YaHei");
   ObjectSetInteger(0,close_name,OBJPROP_FONTSIZE,14);
   ObjectSetInteger(0,close_name,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,close_name,OBJPROP_BGCOLOR,C'55,60,68');
   ObjectSetInteger(0,close_name,OBJPROP_BORDER_COLOR,accent);
   ObjectSetInteger(0,close_name,OBJPROP_HIDDEN,true);
   ObjectSetInteger(0,close_name,OBJPROP_SELECTABLE,true);
   ObjectSetInteger(0,close_name,OBJPROP_STATE,false);
   ObjectSetInteger(0,close_name,OBJPROP_ZORDER,100);

   g_large_visible=true;
   g_large_hide_at_ms=GetTickCount64()+(ulong)InpLargeNotificationSeconds*1000;
   CenterLargeNotification();
  }
void UpdateLargeNotification()
  {
   if(!g_large_visible) return;
   ulong now_ms=GetTickCount64();
   if(now_ms>=g_large_hide_at_ms)
     { HideLargeNotification(); return; }
   ulong remaining_ms=g_large_hide_at_ms-now_ms;
   int remaining_seconds=(int)((remaining_ms+999)/1000);
   string name=LargeObjectName("LARGE_COUNTDOWN");
   if(ObjectFind(0,name)>=0)
      ObjectSetString(0,name,OBJPROP_TEXT,
                      IntegerToString(remaining_seconds)+" 秒后自动关闭");
   ChartRedraw(0);
  }
void EmitConfirmedReversal(const int previous_direction,const int direction,
                           const ScoreSnapshot &s)
  {
   if(InpEnableSound)
     {
      string file=direction==DIR_LONG ? InpLongSound : InpShortSound;
      if(!PlaySound(file)) g_sound_warning="声音播放失败："+file;
      else g_sound_warning="";
     }
   string title=BuildReversalTitle(previous_direction,direction);
   string content=BuildReversalContent(previous_direction,direction,s);
   if(InpEnablePopup) Alert(title,"\n",content);
   SendPushPlus(title,content);
   ShowLargeNotification(previous_direction,direction,s);
  }
void EnsureLabel(const string suffix,const int row)
  {
   string name=g_panel_prefix+suffix;
   if(ObjectFind(0,name)>=0) return;
   ObjectCreate(0,name,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,name,OBJPROP_CORNER,InpPanelCorner);
   ObjectSetInteger(0,name,OBJPROP_XDISTANCE,InpPanelX);
   ObjectSetInteger(0,name,OBJPROP_YDISTANCE,InpPanelY+row*18);
   ObjectSetInteger(0,name,OBJPROP_FONTSIZE,10);
   ObjectSetString(0,name,OBJPROP_FONT,"Microsoft YaHei");
   ObjectSetInteger(0,name,OBJPROP_SELECTABLE,false);
  }
void SetLabel(const string suffix,const int row,const string text,const color c)
  {
   EnsureLabel(suffix,row); string name=g_panel_prefix+suffix;
   ObjectSetString(0,name,OBJPROP_TEXT,text); ObjectSetInteger(0,name,OBJPROP_COLOR,c);
  }
void RenderPanel()
  {
   string shown=g_symbol=="" ? InpSymbol : g_symbol;
   SetLabel("TITLE",0,shown+" · M5 PushPlus 多空监控",clrWhite);
   SetLabel("DIR",1,"已确认方向："+DirectionText(g_confirmed_direction),DirectionColor(g_confirmed_direction));
   if(g_has_snapshot)
      SetLabel("VOTES",2,"EMA "+DoubleToString(g_snapshot.ema_score,1)+" | Supertrend "+
               DoubleToString(g_snapshot.supertrend_score,1)+" | RSI "+
               DoubleToString(g_snapshot.rsi_score,1),InpNeutralColor);
   else SetLabel("VOTES",2,"EMA - | Supertrend - | RSI -",InpNeutralColor);
   string pending="候选：无";
   if(g_pending_direction!=DIR_NONE)
     {
      double remaining_seconds=
         MathMax(0.0,(1.0-g_confirmation_progress)*
                    MathMax(InpMinimumConfirmationSeconds,
                            g_pending_required_seconds));
      pending="候选："+DirectionText(g_pending_direction)+"，进度 "+
              DoubleToString(g_confirmation_progress*100.0,0)+"%，剩余 "+
              DoubleToString(remaining_seconds,1)+" 秒";
     }
   SetLabel("PENDING",3,pending,DirectionColor(g_pending_direction));
   SetLabel("PUSH",4,"PushPlus："+g_push_status,InpNeutralColor);
   SetLabel("STATUS",5,"状态："+g_status,InpNeutralColor);
   string warnings="";
   if(g_sound_warning!="") warnings=g_sound_warning;
   if(g_push_warning!="") warnings+=(warnings=="" ? "" : " | ")+g_push_warning;
   SetLabel("WARN",6,"警告："+(warnings=="" ? "无" : warnings),
            warnings=="" ? InpNeutralColor : InpErrorColor);
   ChartRedraw(0);
  }
bool IsNewTargetTick(MqlTick &tick)
  {
   if(!SymbolInfoTick(g_symbol,tick)) return false;
   if(tick.time_msc==g_last_tick_time_msc && tick.bid==g_last_tick_bid && tick.ask==g_last_tick_ask) return false;
   g_last_tick_time_msc=tick.time_msc; g_last_tick_bid=tick.bid; g_last_tick_ask=tick.ask;
   return true;
  }
void MaybeSendStartupTest()
  {
   if(g_startup_test_attempted || !InpSendStartupTest) return;
   g_startup_test_attempted=true;
   SendPushPlus(g_symbol+" M5 PushPlus 测试","EA 已连接并开始监控；此消息不代表交易方向。");
  }
int OnInit()
  {
   g_panel_prefix="XAU_M5_PP_"+IntegerToString((long)ChartID())+"_"+
                  IntegerToString((long)GetMicrosecondCount())+"_";
   g_inputs_valid=ValidateInputs();
   if(!g_inputs_valid) { RenderPanel(); return INIT_SUCCEEDED; }
   if(!EventSetMillisecondTimer(InpTimerMilliseconds))
     { g_status="定时器创建失败"; RenderPanel(); return INIT_FAILED; }
   if(!InpEnablePushPlus) g_push_status="已关闭";
   else if(StringLen(InpPushPlusToken)==0) g_push_status="Token 未配置";
   if(g_inputs_valid) TryInitializeRuntime();
   RenderPanel();
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int reason)
  {
   EventKillTimer();
   HideLargeNotification();
   ReleaseHandles();
   ObjectsDeleteAll(0,g_panel_prefix);
  }
void OnChartEvent(const int id,const long &lparam,const double &dparam,
                  const string &sparam)
  {
   if(id==CHARTEVENT_OBJECT_CLICK &&
      sparam==LargeObjectName("LARGE_CLOSE"))
     {
      HideLargeNotification();
      return;
     }
   if(id==CHARTEVENT_CHART_CHANGE)
      CenterLargeNotification();
  }
void OnTimer()
  {
   UpdateLargeNotification();
   if(!g_runtime_ready)
     { TryInitializeRuntime(); RenderPanel(); if(!g_runtime_ready) return; }
   MqlTick tick; if(!IsNewTargetTick(tick)) return;
   if(g_previous_server_tick_msc>0 &&
      (tick.time_msc<g_previous_server_tick_msc ||
       tick.time_msc-g_previous_server_tick_msc>
       (long)InpReconnectResetSeconds*1000))
     {
      ResetSignalState(); g_st_cache_ready=false; g_st_active_time=0;
      if(!InitializeSupertrendCache()) { RenderPanel(); return; }
      g_status="报价恢复，静默重建基准";
     }
   g_previous_server_tick_msc=tick.time_msc;
   ScoreSnapshot s; if(!ReadAdaptiveSignal(s)) { RenderPanel(); return; }
   g_snapshot=s; g_has_snapshot=true;
   int previous=g_confirmed_direction;
   bool confirmed=AdvanceAdaptiveState(s.total_score,GetTickCount64());
   if(g_confirmed_direction!=DIR_NONE)
      MaybeSendStartupTest();
   if(confirmed)
     { g_status="已确认"+BuildReversalTitle(previous,g_confirmed_direction);
       EmitConfirmedReversal(previous,g_confirmed_direction,s); }
   else if(g_pending_direction!=DIR_NONE) g_status="反向候选防抖确认中";
   else g_status="监控正常";
   RenderPanel();
  }
