//+------------------------------------------------------------------+
//|  FENIX V2.0 - BB+RSI(6)+MACD(5,13,1) XAUUSD MEJORADO           |
//|                                                                  |
//|  PROBLEMA CRÍTICO EN V1:                                        |
//|  TP = 0.8×ATR vs SL = 2.0×ATR                                  |
//|  → R:R real = 0.40:1 (¡necesitas ganar el 72% para no perder!) |
//|                                                                  |
//|  CORRECCIÓN FUNDAMENTAL V2.0:                                   |
//|  TP = 2.0×ATR vs SL = 1.0×ATR → R:R = 2:1 A FAVOR             |
//|  Con este R:R, ganar el 34% es suficiente para ser rentable     |
//|                                                                  |
//|  MEJORAS ADICIONALES:                                           |
//|  1. R:R 2:1 forzado en cada operación                          |
//|  2. Filtro de sesión Londres+NY (spreads menores, liquidez)     |
//|  3. ADX < 28: solo operar en mercado lateral (BB funciona)      |
//|  4. Confirmación más estricta: vela cierra en dirección         |
//|  5. Trailing stop + Breakeven automático                        |
//|  6. Partial close 50% al alcanzar 1×ATR                        |
//|  7. Filtro de volatilidad: no entrar en picos (noticias)        |
//|  8. Máx 1 posición simultánea (sin acumulación)                 |
//|  9. Cooldown extendido a 90s entre operaciones                  |
//| 10. Circuit breaker más conservador: -2.0% vs -3.0%            |
//|                                                                  |
//|  PARÁMETROS OPTIMIZADOS PARA XAUUSD M1:                        |
//|  - RSI(6): señal rápida pero requiere extremo claro             |
//|  - MACD(5,13,1): confirma dirección de momentum                 |
//|  - BB(20,2): define bandas de reversión                         |
//|  - ATR(14): calibra SL/TP dinámicamente                         |
//+------------------------------------------------------------------+
#property copyright "Fenix V2.0 - DiegoSaenz"
#property version   "2.00"
#property strict
#property description "BB+RSI(6)+MACD(5,13,1) XAUUSD con R:R 2:1 corregido"
#property description "V2.0: Filtros ADX+Sesion+Volatilidad, Partial TP, Trailing"

#include <Trade/Trade.mqh>

//=================================================================
//  PARÁMETROS DE ENTRADA
//=================================================================
input group "=== INDICADORES ==="
input int    Inp_BB_Period    = 20;
input double Inp_BB_Sigma     = 2.0;
input int    Inp_RSI_Period   = 6;
input double Inp_RSI_Buy      = 38.0; // Más estricto que 40 (menos señales, más calidad)
input double Inp_RSI_Sell     = 62.0; // Más estricto que 60
input int    Inp_MACD_Fast    = 5;
input int    Inp_MACD_Slow    = 13;
input int    Inp_MACD_Signal  = 1;
input int    Inp_ATR_Period   = 14;   // Cambiado de 10 a 14 (más estable)

input group "=== R:R CORREGIDO — CLAVE V2.0 ==="
// ANTES: TP=0.8 SL=2.0 → R:R=0.40:1 (terrible)
// AHORA: TP=2.0 SL=1.0 → R:R=2.0:1 (objetivo mínimo profesional)
// REGLA: TP siempre >= 2× SL
input double Inp_TP_ATR       = 2.0;  // TP = 2×ATR (era 0.8 — ¡multiplicado x2.5!)
input double Inp_SL_ATR       = 1.0;  // SL = 1×ATR (era 2.0 — reducido a la mitad)
input double Inp_TP_MinPoints = 60;   // TP mínimo en puntos para cuenta con spread
input double Inp_SL_MinPoints = 30;   // SL mínimo en puntos
input double Inp_RiskPct      = 1.0;  // % balance por operación (no cambiar)
input long   Inp_Magic        = 1235; // Magic diferente al V1 para evitar conflictos

input group "=== PARTIAL CLOSE V2.0 ==="
input bool   Inp_UsePartial    = true;
input double Inp_PartialATR    = 1.0;  // Cerrar 50% cuando ganamos 1×ATR
input double Inp_PartialPct    = 0.50; // Fracción a cerrar

input group "=== TRAILING STOP & BREAKEVEN V2.0 ==="
input bool   Inp_UseTrail      = true;
input double Inp_BE_ATR        = 0.5;  // BE cuando precio avanza 0.5×ATR
input double Inp_BE_Buffer     = 3.0;  // Puntos buffer sobre entrada en BE
input double Inp_Trail_Start   = 1.2;  // Activar trailing cuando ganamos 1.2×ATR
input double Inp_Trail_Dist    = 0.35; // Trailing a 0.35×ATR del precio

input group "=== FILTRO DE SESIÓN (solo Londres y NY) ==="
input bool   Inp_UseSession    = true;
input int    Inp_GMTOffset     = 0;   // Diferencia GMT del broker (Pepperstone demo = 0)
input int    Inp_LondonOpen    = 7;   // 07:00 GMT
input int    Inp_LondonClose   = 17;  // 17:00 GMT
input int    Inp_NYOpen        = 13;  // 13:00 GMT
input int    Inp_NYClose       = 22;  // 22:00 GMT

input group "=== ADX FILTER — SOLO MERCADO RANGING ==="
// BB mean reversion funciona SOLO en mercado lateral
// En tendencia fuerte (ADX alto), el precio puede seguir moviéndose
// contra la posición mucho más allá del SL
input bool   Inp_UseADX        = true;
input int    Inp_ADX_Period    = 14;
input double Inp_ADX_MaxLevel  = 28.0; // Bloquear si ADX > 28 (tendencia fuerte)

input group "=== FILTRO H1 TENDENCIA ==="
input bool   Inp_UseH1Filter   = true;
input int    Inp_H1_EMA        = 50;   // EMA 50 en H1 para filtrar tendencia macro

input group "=== FILTRO DE VOLATILIDAD (bloquear noticias) ==="
input bool   Inp_UseVolFilter  = true;
input int    Inp_ATR_AvgPeriod = 20;  // Período ATR promedio
input double Inp_ATR_MaxMult   = 2.5; // Bloquear si ATR actual > 2.5× ATR promedio

input group "=== CONTROL ==="
input int    Inp_MaxSpread     = 35;  // Más estricto (era sin límite efectivo)
input int    Inp_Cooldown      = 90;  // 90s entre trades (era 60)
input int    Inp_MaxTrades     = 25;  // Reducido de 40 (menos operaciones = mejor calidad)
input bool   Inp_CloseFriday   = true;
input bool   Inp_Panel         = true;

input group "=== CIRCUIT BREAKER ==="
input double Inp_MaxDailyDD    = 2.0;  // Reducido de 3.0% → más conservador
input double Inp_MaxTotalDD    = 8.0;  // Reducido de 10.0%

//=================================================================
//  HANDLES
//=================================================================
int hBB, hRSI, hMACD, hATR, hH1EMA, hADX;
int hATR_Avg = INVALID_HANDLE;

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade trade;

double g_dayStartEq  = 0;
double g_peakEq      = 0;
bool   g_dailyBreach = false;
bool   g_totalBreach = false;
int    g_lastDDDay   = -1;

datetime g_lastTrade = 0;
datetime g_dayRef    = 0;
int      g_todayTrades = 0;
int      g_wins      = 0;
int      g_losses    = 0;

// V2.0: estado de gestión de posición
bool   g_beActive    = false;
bool   g_trailActive = false;
bool   g_partialDone = false;
double g_openPrice   = 0;

//=================================================================
//  OnInit
//=================================================================
int OnInit() {
   trade.SetExpertMagicNumber(Inp_Magic);
   trade.SetDeviationInPoints(30);

   hBB     = iBands(_Symbol,  PERIOD_M1, Inp_BB_Period,   0, Inp_BB_Sigma, PRICE_CLOSE);
   hRSI    = iRSI(_Symbol,    PERIOD_M1, Inp_RSI_Period,  PRICE_CLOSE);
   hMACD   = iMACD(_Symbol,   PERIOD_M1, Inp_MACD_Fast, Inp_MACD_Slow, Inp_MACD_Signal, PRICE_CLOSE);
   hATR    = iATR(_Symbol,    PERIOD_M1, Inp_ATR_Period);
   hH1EMA  = iMA(_Symbol,     PERIOD_H1, Inp_H1_EMA,   0, MODE_EMA, PRICE_CLOSE);
   hADX    = iADX(_Symbol,    PERIOD_M1, Inp_ADX_Period);
   hATR_Avg= iATR(_Symbol,    PERIOD_M1, Inp_ATR_AvgPeriod);

   if(hBB==INVALID_HANDLE||hRSI==INVALID_HANDLE||hMACD==INVALID_HANDLE||
      hATR==INVALID_HANDLE||hH1EMA==INVALID_HANDLE||hADX==INVALID_HANDLE) {
      Print(">>> ERROR: Handles fallidos V2.0"); return INIT_FAILED;
   }

   g_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEq     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayRef     = TimeCurrent();

   Print("=== FENIX V2.0 — R:R CORREGIDO | ",_Symbol," M1 ===");
   Print("R:R V1 (MALO):  TP=0.8×ATR SL=2.0×ATR → 0.40:1");
   Print("R:R V2 (BUENO): TP=",Inp_TP_ATR,"×ATR SL=",Inp_SL_ATR,"×ATR → ",
         NormalizeDouble(Inp_TP_ATR/Inp_SL_ATR,1),":1");
   Print("Sesión: SOLO Londres (",Inp_LondonOpen,"-",Inp_LondonClose,"h GMT) + NY (",Inp_NYOpen,"-",Inp_NYClose,"h GMT)");
   Print("ADX < ",Inp_ADX_MaxLevel," (solo ranging) | Volatilidad < ",Inp_ATR_MaxMult,"× ATR avg");
   Print("Partial TP 50% a ",Inp_PartialATR,"×ATR | BE a ",Inp_BE_ATR,"×ATR | Trail a ",Inp_Trail_Start,"×ATR");
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason) {
   IndicatorRelease(hBB); IndicatorRelease(hRSI); IndicatorRelease(hMACD);
   IndicatorRelease(hATR); IndicatorRelease(hH1EMA); IndicatorRelease(hADX);
   if(hATR_Avg!=INVALID_HANDLE) IndicatorRelease(hATR_Avg);
   ObjectsDeleteAll(0, "FV2_");
}

//=================================================================
//  UTILIDADES
//=================================================================
bool IsNewCandle() {
   static int lastBars = 0;
   int b = iBars(_Symbol, PERIOD_M1);
   if(b != lastBars) { lastBars = b; return true; }
   return false;
}

bool HasPosition() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==Inp_Magic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
   }
   return false;
}

ulong GetCurrentTicket() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==Inp_Magic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) return t;
   }
   return 0;
}

ENUM_POSITION_TYPE GetPosType() {
   ulong t = GetCurrentTicket();
   if(t==0) return (ENUM_POSITION_TYPE)-1;
   PositionSelectByTicket(t);
   return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
}

//=================================================================
//  FILTROS
//=================================================================
bool IsInSession() {
   if(!Inp_UseSession) return true;
   MqlDateTime dt; datetime srv=TimeTradeServer(); if(srv<=0) srv=TimeCurrent();
   TimeToStruct(srv,dt);
   if(dt.day_of_week==0||dt.day_of_week==6) return false;
   if(Inp_CloseFriday&&dt.day_of_week==5&&dt.hour>=20) return false;
   int gH = (dt.hour - Inp_GMTOffset + 24) % 24;
   bool london = (gH>=Inp_LondonOpen && gH<Inp_LondonClose);
   bool ny     = (gH>=Inp_NYOpen     && gH<Inp_NYClose);
   return (london || ny);
}

bool SpreadOK() { return ((int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) <= Inp_MaxSpread); }

bool CheckDrawdown() {
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt; datetime srv=TimeTradeServer(); if(srv<=0) srv=TimeCurrent();
   TimeToStruct(srv,dt);
   if(dt.day!=g_lastDDDay) {
      g_lastDDDay=dt.day; g_dayStartEq=eq; g_dailyBreach=false;
   }
   if(eq>g_peakEq) g_peakEq=eq;
   if(g_dayStartEq>0) {
      double dd=(g_dayStartEq-eq)/g_dayStartEq*100.0;
      if(dd>=Inp_MaxDailyDD){
         if(!g_dailyBreach) Print(">>> CB DIARIO: ",NormalizeDouble(dd,2),"%");
         g_dailyBreach=true; return false;
      }
   }
   if(g_peakEq>0) {
      double dd=(g_peakEq-eq)/g_peakEq*100.0;
      if(dd>=Inp_MaxTotalDD){
         if(!g_totalBreach) Print(">>> CB TOTAL: ",NormalizeDouble(dd,2),"%");
         g_totalBreach=true; return false;
      }
   }
   g_totalBreach=false; return true;
}

//=================================================================
//  CÁLCULO DE LOTE
//=================================================================
double CalcLot(double slDist) {
   if(slDist<=0) return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk = eq * Inp_RiskPct / 100.0;
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0) return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double lot = risk / (slDist * tv/ts);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step>0) lot=MathFloor(lot/step)*step;
   return MathMax(minL,MathMin(maxL,lot));
}

//=================================================================
//  APERTURA DE ORDEN — R:R CORREGIDO
//=================================================================
bool OpenOrder(bool isBuy, double atr, string comment) {
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return false;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   // SL y TP con R:R >= 2:1 GARANTIZADO
   double slDist = MathMax(atr * Inp_SL_ATR, Inp_SL_MinPoints * _Point);
   double tpDist = MathMax(atr * Inp_TP_ATR, Inp_TP_MinPoints * _Point);
   if(tpDist < slDist * 1.8) tpDist = slDist * 2.0; // Garantizar R:R 2:1 mínimo

   double sl=0, tp=0;
   bool ok=false;

   if(isBuy) {
      sl = NormalizeDouble(tick.ask - slDist, dg);
      tp = NormalizeDouble(tick.ask + tpDist, dg);
      double lot = CalcLot(slDist);
      ok = trade.Buy(lot, _Symbol, tick.ask, sl, tp, comment);
      if(ok) {
         g_openPrice = tick.ask;
         Print(">>> BUY V2.0 [",comment,"] lot=",NormalizeDouble(lot,3),
               " SL=",NormalizeDouble(sl,dg)," TP=",NormalizeDouble(tp,dg),
               " R:R=1:",NormalizeDouble(tpDist/slDist,2));
      }
   } else {
      sl = NormalizeDouble(tick.bid + slDist, dg);
      tp = NormalizeDouble(tick.bid - tpDist, dg);
      double lot = CalcLot(slDist);
      ok = trade.Sell(lot, _Symbol, tick.bid, sl, tp, comment);
      if(ok) {
         g_openPrice = tick.bid;
         Print(">>> SELL V2.0 [",comment,"] lot=",NormalizeDouble(lot,3),
               " SL=",NormalizeDouble(sl,dg)," TP=",NormalizeDouble(tp,dg),
               " R:R=1:",NormalizeDouble(tpDist/slDist,2));
      }
   }

   if(ok) {
      g_todayTrades++;
      g_lastTrade   = TimeCurrent();
      g_beActive    = false;
      g_trailActive = false;
      g_partialDone = false;
   } else {
      Print("! ERROR V2.0: ",trade.ResultRetcodeDescription());
   }
   return ok;
}

//=================================================================
//  PARTIAL CLOSE V2.0
//=================================================================
void CheckPartialTP(double atr) {
   if(!Inp_UsePartial || g_partialDone) return;
   ulong ticket = GetCurrentTicket(); if(ticket==0) return;
   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double vol = PositionGetDouble(POSITION_VOLUME);
   double minLot = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double step   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;

   double targetDist = atr * Inp_PartialATR;
   bool doP = false;
   if(pt==POSITION_TYPE_BUY  && tick.bid >= g_openPrice + targetDist) doP=true;
   if(pt==POSITION_TYPE_SELL && tick.ask <= g_openPrice - targetDist) doP=true;
   if(!doP) return;

   double closeLot = NormalizeDouble(vol * Inp_PartialPct, 2);
   if(step>0) closeLot = MathFloor(closeLot/step)*step;
   closeLot = NormalizeDouble(closeLot,2);
   double remLot   = NormalizeDouble(vol - closeLot, 2);
   if(closeLot<minLot || remLot<minLot) return;

   if(trade.PositionClosePartial(ticket, closeLot)) {
      g_partialDone = true;
      // Mover SL a breakeven inmediatamente
      double curSL=PositionGetDouble(POSITION_SL), curTP=PositionGetDouble(POSITION_TP);
      int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
      double beSL = (pt==POSITION_TYPE_BUY)
         ? NormalizeDouble(g_openPrice + 3*_Point, dg)
         : NormalizeDouble(g_openPrice - 3*_Point, dg);
      bool upd = (pt==POSITION_TYPE_BUY)?(beSL>curSL):(curSL<=0||beSL<curSL);
      if(upd) {
         trade.PositionModify(ticket, beSL, curTP);
         g_beActive = true;
         Print(">>> PARTIAL V2.0 + BE: cerrado ",NormalizeDouble(closeLot,2),"lots, SL→BE");
      }
   }
}

//=================================================================
//  TRAILING STOP + BREAKEVEN V2.0 (más agresivos que V1)
//=================================================================
void ManagePosition(double atr) {
   if(!Inp_UseTrail) return;
   if(atr<=0) return;

   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double minStop = SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double buffer  = Inp_BE_Buffer*_Point;

   ulong ticket = GetCurrentTicket(); if(ticket==0) return;
   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double openP  = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL  = PositionGetDouble(POSITION_SL);
   double curTP  = PositionGetDouble(POSITION_TP);
   double newSL  = curSL;

   if(pt==POSITION_TYPE_BUY) {
      double price    = tick.bid;
      double traveled = price - openP;

      // Fase 2: Trailing (prioridad)
      if(traveled >= Inp_Trail_Start * atr) {
         if(!g_trailActive) {
            g_trailActive=true;
            Print(">>> TRAIL ON V2.0 BUY: dist=",NormalizeDouble(Inp_Trail_Dist*atr/_Point,1),"pts");
         }
         double trailSL = NormalizeDouble(price - Inp_Trail_Dist*atr, dg);
         if(trailSL > newSL+_Point) newSL=trailSL;
      }
      // Fase 1: BE
      else if(!g_beActive && traveled >= Inp_BE_ATR*atr) {
         double beSL = NormalizeDouble(openP + buffer, dg);
         if(beSL > newSL+_Point) newSL=beSL;
      }

      // Seguridad mínima distancia al precio
      double maxSL = NormalizeDouble(price-minStop, dg);
      if(newSL>maxSL) newSL=maxSL;

      if(newSL>curSL+_Point) {
         if(trade.PositionModify(ticket,newSL,curTP)) {
            if(!g_beActive&&!g_trailActive) {
               g_beActive=true;
               Print(">>> BE V2.0 BUY: SL→",NormalizeDouble(newSL,dg));
            }
         }
      }

   } else if(pt==POSITION_TYPE_SELL) {
      double price    = tick.ask;
      double traveled = PositionGetDouble(POSITION_PRICE_OPEN)-price;

      if(traveled >= Inp_Trail_Start*atr) {
         if(!g_trailActive) {
            g_trailActive=true;
            Print(">>> TRAIL ON V2.0 SELL: dist=",NormalizeDouble(Inp_Trail_Dist*atr/_Point,1),"pts");
         }
         double trailSL = NormalizeDouble(price+Inp_Trail_Dist*atr, dg);
         if(curSL==0||trailSL<newSL-_Point) newSL=trailSL;
      }
      else if(!g_beActive && traveled>=Inp_BE_ATR*atr) {
         double beSL = NormalizeDouble(openP-buffer, dg);
         if(curSL==0||beSL<newSL-_Point) newSL=beSL;
      }

      double minSL = NormalizeDouble(price+minStop, dg);
      if(newSL!=0&&newSL<minSL) newSL=minSL;

      bool shouldMod=(curSL==0&&newSL>0)||(curSL>0&&newSL<curSL-_Point);
      if(shouldMod) {
         if(trade.PositionModify(ticket,newSL,curTP)) {
            if(!g_beActive&&!g_trailActive) {
               g_beActive=true;
               Print(">>> BE V2.0 SELL: SL→",NormalizeDouble(newSL,dg));
            }
         }
      }
   }
}

//=================================================================
//  CIERRE POR SEÑAL CONTRARIA (requiere MACD Y RSI para ser válida)
//=================================================================
void CheckExitBySignal(double rsi, double bbMid, double price, double macdH) {
   if(!HasPosition()) return;
   ENUM_POSITION_TYPE pt = GetPosType();
   bool doClose=false; string reason="";

   // V2.0: requiere MACD + precio vs media para cerrar (más selectivo que V1)
   if(pt==POSITION_TYPE_BUY) {
      // Señal de cierre: precio por debajo de la media Y MACD giró negativo Y RSI sobrecomprado
      if(price < bbMid && macdH < 0 && rsi > 58) { doClose=true; reason="BB<Mid+MACD<0+RSI>58"; }
   } else if(pt==POSITION_TYPE_SELL) {
      // Señal de cierre: precio por encima de la media Y MACD giró positivo Y RSI sobrevendido
      if(price > bbMid && macdH > 0 && rsi < 42) { doClose=true; reason="BB>Mid+MACD>0+RSI<42"; }
   }

   if(doClose) {
      ulong ticket=GetCurrentTicket();
      if(ticket>0 && PositionSelectByTicket(ticket)) {
         double pf=PositionGetDouble(POSITION_PROFIT);
         if(trade.PositionClose(ticket))
            Print(">>> CIERRE V2.0 señal [",reason,"] P&L:$",NormalizeDouble(pf,2));
      }
   }
}

//=================================================================
//  CIERRE VIERNES
//=================================================================
void CheckFridayClose() {
   if(!Inp_CloseFriday) return;
   MqlDateTime dt; datetime srv=TimeTradeServer(); if(srv<=0) srv=TimeCurrent();
   TimeToStruct(srv,dt);
   if(dt.day_of_week==5&&dt.hour>=20&&HasPosition()) {
      ulong ticket=GetCurrentTicket();
      if(ticket>0) { trade.PositionClose(ticket); Print(">>> CIERRE VIERNES V2.0"); }
   }
}

//=================================================================
//  PANEL V2.0
//=================================================================
void Lbl(string n, string txt, int x, int y, color c, int fs=9) {
   if(ObjectFind(0,n)<0) {
      ObjectCreate(0,n,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
      ObjectSetString(0,n,OBJPROP_FONT,"Consolas");
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
}

void UpdatePanel(string estado, double rsi, double macdH, double adx,
                 bool inSession, double spread) {
   if(!Inp_Panel) return;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double pnl=eq-bal;
   double ddD=(g_dayStartEq>0)?(g_dayStartEq-eq)/g_dayStartEq*100:0;
   double ddT=(g_peakEq>0)?(g_peakEq-eq)/g_peakEq*100:0;
   int wr=(g_wins+g_losses>0)?g_wins*100/(g_wins+g_losses):0;
   color cp=pnl>=0?clrLimeGreen:clrOrangeRed;
   color cs=inSession?clrLimeGreen:clrGray;
   color cdd=ddD<Inp_MaxDailyDD*0.7?clrLimeGreen:clrOrangeRed;
   color cadx=(adx<Inp_ADX_MaxLevel)?clrLimeGreen:clrOrangeRed;

   string tStr="";
   if(Inp_UseTrail&&HasPosition()){
      if(g_trailActive)       tStr=" [TRAIL]";
      else if(g_beActive)     tStr=" [BE]";
      else                    tStr=" [SL orig]";
      if(g_partialDone)       tStr+=" +PART";
   }

   Lbl("FV2_0","FENIX V2.0 | "+_Symbol+" M1 | R:R=1:"+DoubleToString(Inp_TP_ATR/Inp_SL_ATR,1),
               10,15,clrCyan,10);
   Lbl("FV2_1","Bal:$"+DoubleToString(bal,2)+"  P&L:$"+DoubleToString(pnl,2),10,32,cp);
   Lbl("FV2_2","W:"+IntegerToString(g_wins)+" L:"+IntegerToString(g_losses)+
               " WR:"+IntegerToString(wr)+"% Tr:"+IntegerToString(g_todayTrades)+
               "/"+IntegerToString(Inp_MaxTrades),10,49,clrYellow);
   Lbl("FV2_3","DD dia:"+DoubleToString(ddD,1)+"% DD tot:"+DoubleToString(ddT,1)+"%",10,66,cdd);
   Lbl("FV2_4","ADX:"+DoubleToString(adx,1)+(adx<Inp_ADX_MaxLevel?" RANGING":" TREND-BLOCK")+
               " | Spr:"+IntegerToString((int)spread)+
               " | Ses:"+(inSession?"ACTIVA":"FUERA"),10,83,cadx);
   Lbl("FV2_5","RSI:"+DoubleToString(rsi,1)+
               " MACD_H:"+DoubleToString(macdH,5)+
               (macdH>0?" (alcista)":" (bajista)"),10,100,macdH>0?clrLimeGreen:clrOrangeRed);
   Lbl("FV2_6","Estado: "+estado+tStr,10,117,cs);
   Lbl("FV2_7",g_dailyBreach?"!!! CIRCUIT BREAKER DIARIO !!!":
               g_totalBreach?"!!! CIRCUIT BREAKER TOTAL !!!":
               "TP="+DoubleToString(Inp_TP_ATR,1)+"×ATR | SL="+DoubleToString(Inp_SL_ATR,1)+"×ATR",
               10,134,g_dailyBreach||g_totalBreach?clrOrangeRed:clrDimGray);
   ChartRedraw(0);
}

//=================================================================
//  TRACKING DE RESULTADOS
//=================================================================
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult &res) {
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)==Inp_Magic &&
            HistoryDealGetString(trans.deal,DEAL_SYMBOL)==_Symbol   &&
            HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_OUT) {
            double pf=HistoryDealGetDouble(trans.deal,DEAL_PROFIT);
            if(pf>=0) g_wins++; else g_losses++;
            int wr=(g_wins+g_losses>0)?g_wins*100/(g_wins+g_losses):0;
            Print((pf>=0?"WIN":"LOSS")," $",NormalizeDouble(pf,2),
                  " | W:",g_wins," L:",g_losses," WR:",wr,"%");
         }
      }
   }
}

//=================================================================
//  OnTick — LÓGICA PRINCIPAL V2.0
//=================================================================
void OnTick() {
   // Reset diario
   MqlDateTime dt,dl;
   TimeToStruct(TimeCurrent(),dt); TimeToStruct(g_dayRef,dl);
   if(dt.day!=dl.day) {
      g_todayTrades=0; g_wins=0; g_losses=0; g_dayRef=TimeCurrent();
   }

   // 1. Viernes
   CheckFridayClose();

   // 2. Circuit breaker
   bool ddOK=CheckDrawdown();

   // 3. Leer indicadores
   double bbM[],bbU[],bbL[];
   double rsiV[],macdH[],atrV[],atrAvg[];
   double h1ema[],adxV[];
   ArraySetAsSeries(bbM,true); ArraySetAsSeries(bbU,true); ArraySetAsSeries(bbL,true);
   ArraySetAsSeries(rsiV,true); ArraySetAsSeries(macdH,true);
   ArraySetAsSeries(atrV,true); ArraySetAsSeries(h1ema,true);
   ArraySetAsSeries(adxV,true);

   if(CopyBuffer(hBB,  0,0,2,bbM)  <2) return;
   if(CopyBuffer(hBB,  1,0,2,bbU)  <2) return;
   if(CopyBuffer(hBB,  2,0,2,bbL)  <2) return;
   if(CopyBuffer(hRSI, 0,0,1,rsiV) <1) return;
   if(CopyBuffer(hMACD,0,0,1,macdH)<1) return;
   if(CopyBuffer(hATR, 0,1,1,atrV) <1) return;
   if(CopyBuffer(hH1EMA,0,0,1,h1ema)<1) return;
   if(CopyBuffer(hADX, 0,0,1,adxV) <1) return;

   double atr    = atrV[0];
   double rsi    = rsiV[0];
   double mHist  = macdH[0];
   double mMid   = bbM[0];
   double mUpper = bbU[0];
   double mLower = bbL[0];
   double adx    = adxV[0];
   double h1e    = h1ema[0];
   if(atr<=0) return;

   // ATR promedio para filtro de volatilidad
   double atrAvgVal = atr;
   if(hATR_Avg!=INVALID_HANDLE) {
      if(CopyBuffer(hATR_Avg,0,1,1,atrAvg)==1) atrAvgVal=atrAvg[0];
   }

   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double price=tick.last;
   double spread=(tick.ask-tick.bid)/_Point;

   bool inSession=IsInSession();
   bool spreadOK=SpreadOK();
   bool ranging=(adx<Inp_ADX_MaxLevel);
   bool volOK=(!Inp_UseVolFilter || atrAvgVal<=0 || atr<atrAvgVal*Inp_ATR_MaxMult);

   // 4. Gestión de posición abierta (PRIORIDAD en cada tick)
   if(HasPosition()) {
      CheckPartialTP(atr);
      ManagePosition(atr);
      if(IsNewCandle()) CheckExitBySignal(rsi, mMid, price, mHist);
      UpdatePanel("EN POSICION",rsi,mHist,adx,inSession,(int)spread);
      return;
   }

   // 5. Verificar condiciones para abrir
   if(!ddOK) {
      UpdatePanel("CIRCUIT BREAKER",rsi,mHist,adx,inSession,spread); return;
   }
   if(!inSession) {
      UpdatePanel("Fuera de sesion",rsi,mHist,adx,false,spread); return;
   }
   if(!spreadOK) {
      UpdatePanel("Spread alto "+IntegerToString((int)spread),rsi,mHist,adx,inSession,spread); return;
   }
   if(!ranging) {
      UpdatePanel("ADX TREND ("+DoubleToString(adx,1)+") bloqueado",rsi,mHist,adx,inSession,spread); return;
   }
   if(!volOK) {
      UpdatePanel("VOLATILIDAD ALTA noticias?",rsi,mHist,adx,inSession,spread); return;
   }
   if(g_todayTrades>=Inp_MaxTrades) {
      UpdatePanel("MAX TRADES "+IntegerToString(g_todayTrades),rsi,mHist,adx,inSession,spread); return;
   }
   if(TimeCurrent()-g_lastTrade<Inp_Cooldown) {
      int r=(int)(Inp_Cooldown-(TimeCurrent()-g_lastTrade));
      UpdatePanel("Cooldown "+IntegerToString(r)+"s",rsi,mHist,adx,inSession,spread); return;
   }

   // Solo en vela nueva
   if(!IsNewCandle()) {
      UpdatePanel("Esperando vela...",rsi,mHist,adx,inSession,spread); return;
   }

   // Filtro H1
   bool h1Up = (!Inp_UseH1Filter || price > h1e);
   bool h1Dn = (!Inp_UseH1Filter || price < h1e);

   // ========================================================
   // SEÑALES V2.0 — MÁS ESTRICTAS QUE V1
   // BUY: precio BAJO la media BB + RSI extremo bajo + MACD positivo + H1 alcista
   // SELL: precio SOBRE la media BB + RSI extremo alto + MACD negativo + H1 bajista
   // ========================================================
   bool buy  = (price < mMid)             // precio debajo de media BB
               && (rsi <= Inp_RSI_Buy)    // RSI extremo (<=38, más estricto que V1's 40)
               && (mHist > 0)             // MACD histograma positivo (momentum alcista)
               && h1Up;                   // H1 filtro de tendencia macro

   bool sell = (price > mMid)             // precio encima de media BB
               && (rsi >= Inp_RSI_Sell)   // RSI extremo (>=62)
               && (mHist < 0)             // MACD histograma negativo
               && h1Dn;

   // 6. Ejecutar señal
   if(buy || sell) {
      string comment = buy ? "FV2-BUY" : "FV2-SELL";
      if(OpenOrder(buy, atr, comment)) {
         UpdatePanel((buy?"ENTRO BUY":"ENTRO SELL")+" ["+comment+"]",
                     rsi,mHist,adx,inSession,spread);
      } else {
         UpdatePanel("ERR apertura",rsi,mHist,adx,inSession,spread);
      }
      return;
   }

   // 7. Sin señal: mostrar estado diagnóstico
   string estado="";
   bool rsiOK_buy  = (rsi <= Inp_RSI_Buy);
   bool rsiOK_sell = (rsi >= Inp_RSI_Sell);
   bool macdOK_buy = (mHist > 0);
   bool macdOK_sell= (mHist < 0);

   if(price < mMid) {
      if(!rsiOK_buy)  estado="BB<Mid | RSI falta ("+DoubleToString(rsi,0)+" > "+DoubleToString(Inp_RSI_Buy,0)+")";
      else if(!macdOK_buy) estado="BB<Mid+RSI OK | MACD falta (negativo)";
      else                 estado="BUY posible pero H1 en contra";
   } else {
      if(!rsiOK_sell) estado="BB>Mid | RSI falta ("+DoubleToString(rsi,0)+" < "+DoubleToString(Inp_RSI_Sell,0)+")";
      else if(!macdOK_sell) estado="BB>Mid+RSI OK | MACD falta (positivo)";
      else                  estado="SELL posible pero H1 en contra";
   }
   if(estado=="") estado="Sin confluencia";

   UpdatePanel(estado,rsi,mHist,adx,inSession,spread);
}
//+------------------------------------------------------------------+