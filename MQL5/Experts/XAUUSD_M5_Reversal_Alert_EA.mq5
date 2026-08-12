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

struct SignalSnapshot
  {
   int ema_vote,supertrend_vote,rsi_vote,candidate;
   double fast_ema,slow_ema,supertrend_line,rsi,close;
   long tick_time_msc;
   datetime server_time;
  };

const int MAX_INDICATOR_PERIOD=500;
const int MAX_HISTORY_BARS=5000;
string g_symbol="",g_status="正在初始化",g_push_status="未发送";
string g_sound_warning="",g_push_warning="";
string g_panel_prefix="";
bool g_runtime_ready=false,g_has_snapshot=false,g_startup_test_attempted=false;
int g_fast_ema_handle=INVALID_HANDLE,g_slow_ema_handle=INVALID_HANDLE;
int g_atr_handle=INVALID_HANDLE,g_rsi_handle=INVALID_HANDLE;
int g_confirmed_direction=DIR_NONE,g_pending_direction=DIR_NONE;
ulong g_pending_elapsed_ms=0,g_last_pending_tick_ms=0;
long g_last_tick_time_msc=0,g_previous_server_tick_msc=0;
double g_last_tick_bid=0.0,g_last_tick_ask=0.0;
bool g_large_visible=false;
ulong g_large_hide_at_ms=0;
int g_large_font_size=15;
int g_large_title_font_size=28;
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
      InpPushPlusTimeoutMs<=0 || InpLargeNotificationSeconds<=0)
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
                           const SignalSnapshot &s)
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
               "\nEMA："+DirectionText(s.ema_vote)+
               "\nSupertrend："+DirectionText(s.supertrend_vote)+
               "\nRSI："+DirectionText(s.rsi_vote)+
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
                           const SignalSnapshot &s)
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
      SetLabel("VOTES",2,"EMA "+DirectionText(g_snapshot.ema_vote)+" | Supertrend "+
               DirectionText(g_snapshot.supertrend_vote)+" | RSI "+DirectionText(g_snapshot.rsi_vote),InpNeutralColor);
   else SetLabel("VOTES",2,"EMA - | Supertrend - | RSI -",InpNeutralColor);
   string pending="候选：无";
   if(g_pending_direction!=DIR_NONE)
     {
      ulong hold_ms=(ulong)InpHoldSeconds*1000;
      ulong remaining_ms=g_pending_elapsed_ms<hold_ms ? hold_ms-g_pending_elapsed_ms : 0;
      pending="候选："+DirectionText(g_pending_direction)+"，已保持 "+
              DoubleToString((double)g_pending_elapsed_ms/1000.0,1)+" 秒，剩余 "+
              DoubleToString((double)remaining_ms/1000.0,1)+" 秒";
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
   if(!ValidateInputs()) { RenderPanel(); return INIT_PARAMETERS_INCORRECT; }
   if(!EventSetMillisecondTimer(InpTimerMilliseconds))
     { g_status="定时器创建失败"; RenderPanel(); return INIT_FAILED; }
   if(!InpEnablePushPlus) g_push_status="已关闭";
   else if(StringLen(InpPushPlusToken)==0) g_push_status="Token 未配置";
   TryInitializeRuntime(); RenderPanel();
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
      tick.time_msc-g_previous_server_tick_msc>(long)InpReconnectResetSeconds*1000)
     { ResetSignalState(); g_status="报价恢复，静默重建基准"; }
   g_previous_server_tick_msc=tick.time_msc;
   SignalSnapshot s; if(!ReadLiveSignal(s)) { RenderPanel(); return; }
   g_snapshot=s; g_has_snapshot=true;
   int previous=g_confirmed_direction;
   bool confirmed=AdvanceReversalState(s.candidate,GetTickCount64());
   if(g_confirmed_direction!=DIR_NONE)
      MaybeSendStartupTest();
   if(confirmed)
     { g_status="已确认"+BuildReversalTitle(previous,g_confirmed_direction);
       EmitConfirmedReversal(previous,g_confirmed_direction,s); }
   else if(g_pending_direction!=DIR_NONE) g_status="反向候选防抖确认中";
   else g_status="监控正常";
   RenderPanel();
  }
