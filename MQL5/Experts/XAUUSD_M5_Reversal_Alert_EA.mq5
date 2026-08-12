#property strict
#property copyright "Codex"
#property version "1.00"
#property description "Non-trading XAUUSD M5 reversal alerts with PushPlus."

enum SignalDirection { DIR_SHORT=-1, DIR_NONE=0, DIR_LONG=1 };

input string InpSymbol = "XAUUSD";
input int InpFastEmaPeriod = 9;
input int InpSlowEmaPeriod = 21;
input int InpAtrPeriod = 10;
input double InpSupertrendMultiplier = 3.0;
input int InpRsiPeriod = 14;
input double InpRsiMidpoint = 50.0;
input int InpHoldSeconds = 10;
input int InpTimerMilliseconds = 100;
input int InpMaximumActiveTickGapMs = 1000;
input int InpReconnectResetSeconds = 60;
input bool InpEnableSound = true;
input string InpLongSound = "alert.wav";
input string InpShortSound = "timeout.wav";
input bool InpEnablePopup = true;
input bool   InpEnablePushPlus = true;
input string InpPushPlusToken = "";
input string InpPushPlusUrl = "https://www.pushplus.plus/send";
input string InpPushPlusChannel = "wechat";
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

struct SignalSnapshot
  {
   int ema_vote,supertrend_vote,rsi_vote,candidate;
   double fast_ema,slow_ema,supertrend_line,rsi,close;
   long tick_time_msc;
   datetime server_time;
  };

const int MAX_INDICATOR_PERIOD=500;
const int MAX_HISTORY_BARS=5000;
string g_symbol="",g_status="正在初始化",g_warning_status="",g_push_status="未发送";
string g_panel_prefix="";
bool g_runtime_ready=false,g_has_snapshot=false,g_startup_test_attempted=false;
int g_fast_ema_handle=INVALID_HANDLE,g_slow_ema_handle=INVALID_HANDLE;
int g_atr_handle=INVALID_HANDLE,g_rsi_handle=INVALID_HANDLE;
int g_confirmed_direction=DIR_NONE,g_pending_direction=DIR_NONE;
ulong g_pending_elapsed_ms=0,g_last_pending_tick_ms=0;
long g_last_tick_time_msc=0,g_previous_server_tick_msc=0;
double g_last_tick_bid=0.0,g_last_tick_ask=0.0;
SignalSnapshot g_snapshot;

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
   if(InpFastEmaPeriod<=0 || InpSlowEmaPeriod<=InpFastEmaPeriod ||
      InpFastEmaPeriod>MAX_INDICATOR_PERIOD || InpSlowEmaPeriod>MAX_INDICATOR_PERIOD)
     { g_status="参数错误：EMA周期无效"; return false; }
   if(InpAtrPeriod<=0 || InpAtrPeriod>MAX_INDICATOR_PERIOD ||
      InpSupertrendMultiplier<=0.0)
     { g_status="参数错误：Supertrend参数无效"; return false; }
   if(InpRsiPeriod<=0 || InpRsiPeriod>MAX_INDICATOR_PERIOD ||
      InpRsiMidpoint<=0.0 || InpRsiMidpoint>=100.0)
     { g_status="参数错误：RSI参数无效"; return false; }
   if(InpHoldSeconds<=0 || InpTimerMilliseconds<50 ||
      InpMaximumActiveTickGapMs<=0 || InpReconnectResetSeconds<=0 ||
      InpPushPlusTimeoutMs<=0)
     { g_status="参数错误：计时参数无效"; return false; }
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
   g_runtime_ready=false;
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
   if(g_runtime_ready) return true;
   if(g_symbol=="" && !ResolveTargetSymbol()) return false;
   if(!CreateIndicatorHandles()) return false;
   g_runtime_ready=true; g_status="等待首个有效M5信号";
   return true;
  }
int RequiredHistoryBars()
  { return MathMin(MAX_HISTORY_BARS,MathMax(200,InpAtrPeriod*10)); }
int CompareValues(const double left,const double right)
  { return left>right ? DIR_LONG : left<right ? DIR_SHORT : DIR_NONE; }
int MajorityVote(const int a,const int b,const int c)
  {
   int longs=(a==DIR_LONG)+(b==DIR_LONG)+(c==DIR_LONG);
   int shorts=(a==DIR_SHORT)+(b==DIR_SHORT)+(c==DIR_SHORT);
   return longs>=2 ? DIR_LONG : shorts>=2 ? DIR_SHORT : DIR_NONE;
  }
bool CalculateSupertrendVote(const MqlRates &rates[],const double &atr[],
                             const int count,int &vote,double &line)
  {
   if(count<3) return false;
   double mid=(rates[0].high+rates[0].low)*0.5;
   double upper=mid+InpSupertrendMultiplier*atr[0];
   double lower=mid-InpSupertrendMultiplier*atr[0];
   bool long_trend=rates[0].close>=mid;
   for(int i=1;i<count;i++)
     {
      mid=(rates[i].high+rates[i].low)*0.5;
      double basic_upper=mid+InpSupertrendMultiplier*atr[i];
      double basic_lower=mid-InpSupertrendMultiplier*atr[i];
      double final_upper=(basic_upper>=upper && rates[i-1].close<=upper) ? upper : basic_upper;
      double final_lower=(basic_lower<=lower && rates[i-1].close>=lower) ? lower : basic_lower;
      if(long_trend && rates[i].close<final_lower) long_trend=false;
      else if(!long_trend && rates[i].close>final_upper) long_trend=true;
      upper=final_upper; lower=final_lower;
     }
   line=long_trend ? lower : upper;
   vote=CompareValues(rates[count-1].close,line);
   return true;
  }
bool ReadLiveSignal(SignalSnapshot &s)
  {
   int count=RequiredHistoryBars();
   if(BarsCalculated(g_fast_ema_handle)<count || BarsCalculated(g_slow_ema_handle)<count ||
      BarsCalculated(g_atr_handle)<count || BarsCalculated(g_rsi_handle)<count)
     { g_status="等待M5历史数据"; return false; }
   MqlRates rates[]; double atr[],fast[],slow[],rsi[];
   ArraySetAsSeries(rates,false); ArraySetAsSeries(atr,false);
   if(CopyRates(g_symbol,PERIOD_M5,0,count,rates)!=count ||
      CopyBuffer(g_atr_handle,0,0,count,atr)!=count ||
      CopyBuffer(g_fast_ema_handle,0,0,1,fast)!=1 ||
      CopyBuffer(g_slow_ema_handle,0,0,1,slow)!=1 ||
      CopyBuffer(g_rsi_handle,0,0,1,rsi)!=1)
     { g_status="M5数据复制未完成"; return false; }
   int st_vote=DIR_NONE; double st_line=0.0;
   if(!CalculateSupertrendVote(rates,atr,count,st_vote,st_line)) return false;
   MqlTick tick; if(!SymbolInfoTick(g_symbol,tick)) return false;
   s.fast_ema=fast[0]; s.slow_ema=slow[0]; s.rsi=rsi[0];
   s.close=rates[count-1].close; s.supertrend_line=st_line;
   s.ema_vote=CompareValues(s.fast_ema,s.slow_ema);
   s.supertrend_vote=st_vote; s.rsi_vote=CompareValues(s.rsi,InpRsiMidpoint);
   s.candidate=MajorityVote(s.ema_vote,s.supertrend_vote,s.rsi_vote);
   s.tick_time_msc=tick.time_msc; s.server_time=(datetime)tick.time;
   return true;
  }
void ResetSignalState()
  { g_confirmed_direction=g_pending_direction=DIR_NONE; g_pending_elapsed_ms=0; g_last_pending_tick_ms=0; }
bool AdvanceReversalState(const int candidate,const ulong now_ms)
  {
   if(g_confirmed_direction==DIR_NONE)
     { if(candidate!=DIR_NONE) g_confirmed_direction=candidate; return false; }
   if(candidate==DIR_NONE || candidate==g_confirmed_direction)
     { g_pending_direction=DIR_NONE; g_pending_elapsed_ms=0; g_last_pending_tick_ms=0; return false; }
   if(g_pending_direction!=candidate)
     { g_pending_direction=candidate; g_pending_elapsed_ms=0; g_last_pending_tick_ms=now_ms; return false; }
   ulong delta=now_ms>=g_last_pending_tick_ms ? now_ms-g_last_pending_tick_ms : 0;
   if(delta<=(ulong)InpMaximumActiveTickGapMs) g_pending_elapsed_ms+=delta;
   g_last_pending_tick_ms=now_ms;
   if(g_pending_elapsed_ms<(ulong)InpHoldSeconds*1000) return false;
   g_confirmed_direction=candidate; g_pending_direction=DIR_NONE;
   g_pending_elapsed_ms=0; g_last_pending_tick_ms=0;
   return true;
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
                            const SignalSnapshot &s)
  {
   string transition=(previous_direction==DIR_SHORT && direction==DIR_LONG) ? "空转多" : "多转空";
   return "品种："+g_symbol+"\n周期：M5\n方向："+transition+
          "\n服务器时间："+TimeToString(s.server_time,TIME_DATE|TIME_SECONDS)+
          "\nEMA："+DirectionText(s.ema_vote)+
          "\nSupertrend："+DirectionText(s.supertrend_vote)+
          "\nRSI："+DirectionText(s.rsi_vote)+
          "\n确认时间："+IntegerToString(InpHoldSeconds)+" 秒";
  }
int ParseBusinessCode(const string response)
  {
   int pos=StringFind(response,"\"code\"");
   if(pos<0) return -2147483647;
   pos=StringFind(response,":",pos);
   if(pos<0) return -2147483647;
   string tail=StringSubstr(response,pos+1);
   StringTrimLeft(tail);
   if(StringLen(tail)>0 && StringGetCharacter(tail,0)=='"')
      tail=StringSubstr(tail,1);
   return (int)StringToInteger(tail);
  }
bool SendPushPlus(const string title,const string content)
  {
   if(!InpEnablePushPlus) { g_push_status="已关闭"; return false; }
   if(StringLen(InpPushPlusToken)==0)
     { g_push_status="Token 未配置"; g_warning_status="PushPlus Token 未配置"; return false; }
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
       g_warning_status="PushPlus 请求失败，请检查 WebRequest 白名单"; Print(g_push_status); return false; }
   if(http!=200)
     { g_push_status="HTTP "+IntegerToString(http); Print("PushPlus ",g_push_status); return false; }
   string response=CharArrayToString(result,0,WHOLE_ARRAY,CP_UTF8);
   int code=ParseBusinessCode(response);
   if(code!=200)
     { g_push_status="业务码 "+IntegerToString(code); Print("PushPlus ",g_push_status); return false; }
   g_push_status="服务端已接收"; g_warning_status="";
   return true;
  }
void EmitConfirmedReversal(const int previous_direction,const int direction,
                           const SignalSnapshot &s)
  {
   if(InpEnableSound)
     {
      string file=direction==DIR_LONG ? InpLongSound : InpShortSound;
      if(!PlaySound(file)) g_warning_status="声音播放失败："+file;
     }
   string title=BuildReversalTitle(previous_direction,direction);
   string content=BuildReversalContent(previous_direction,direction,s);
   if(InpEnablePopup) Alert(title,"\n",content);
   SendPushPlus(title,content);
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
      SetLabel("VOTES",2,"EMA "+DirectionText(g_snapshot.ema_vote)+" | Supertrend "+
               DirectionText(g_snapshot.supertrend_vote)+" | RSI "+DirectionText(g_snapshot.rsi_vote),InpNeutralColor);
   else SetLabel("VOTES",2,"EMA - | Supertrend - | RSI -",InpNeutralColor);
   string pending="候选：无";
   if(g_pending_direction!=DIR_NONE)
      pending="候选："+DirectionText(g_pending_direction)+"，已保持 "+
              DoubleToString((double)g_pending_elapsed_ms/1000.0,1)+" 秒";
   SetLabel("PENDING",3,pending,DirectionColor(g_pending_direction));
   SetLabel("PUSH",4,"PushPlus："+g_push_status,InpNeutralColor);
   SetLabel("STATUS",5,"状态："+g_status,InpNeutralColor);
   SetLabel("WARN",6,"警告："+(g_warning_status=="" ? "无" : g_warning_status),
            g_warning_status=="" ? InpNeutralColor : InpErrorColor);
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
   if(!ValidateInputs()) { RenderPanel(); return INIT_PARAMETERS_INCORRECT; }
   if(!EventSetMillisecondTimer(InpTimerMilliseconds))
     { g_status="定时器创建失败"; RenderPanel(); return INIT_FAILED; }
   if(!InpEnablePushPlus) g_push_status="已关闭";
   else if(StringLen(InpPushPlusToken)==0) g_push_status="Token 未配置";
   TryInitializeRuntime(); MaybeSendStartupTest(); RenderPanel();
   return INIT_SUCCEEDED;
  }
void OnDeinit(const int reason)
  { EventKillTimer(); ReleaseHandles(); ObjectsDeleteAll(0,g_panel_prefix); }
void OnTimer()
  {
   if(!g_runtime_ready)
     { TryInitializeRuntime(); MaybeSendStartupTest(); RenderPanel(); if(!g_runtime_ready) return; }
   MqlTick tick; if(!IsNewTargetTick(tick)) return;
   if(g_previous_server_tick_msc>0 &&
      tick.time_msc-g_previous_server_tick_msc>(long)InpReconnectResetSeconds*1000)
     { ResetSignalState(); g_status="报价恢复，静默重建基准"; }
   g_previous_server_tick_msc=tick.time_msc;
   SignalSnapshot s; if(!ReadLiveSignal(s)) { RenderPanel(); return; }
   g_snapshot=s; g_has_snapshot=true;
   int previous=g_confirmed_direction;
   if(AdvanceReversalState(s.candidate,GetTickCount64()))
     { g_status="已确认"+BuildReversalTitle(previous,g_confirmed_direction);
       EmitConfirmedReversal(previous,g_confirmed_direction,s); }
   else if(g_pending_direction!=DIR_NONE) g_status="反向候选防抖确认中";
   else g_status="监控正常";
   RenderPanel();
  }
