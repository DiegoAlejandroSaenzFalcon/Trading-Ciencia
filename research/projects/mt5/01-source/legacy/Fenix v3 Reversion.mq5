//+------------------------------------------------------------------+
//|                  FENIX PRO v4.0 - Mean Reversion XAUUSD         |
//|                                                                  |
//|  MEJORAS vs v3.0:                                               |
//|                                                                  |
//|  CORRECCIONES DE R:R:                                           |
//|  1. SL reducido: 1.5×ATR (era 2.0×ATR → pérdidas mayores)     |
//|  2. TP parcial: 50% al alcanzar 1×ATR (asegura ganancia real)  |
//|  3. TP principal: banda BB contraria (mean reversion completo)  |
//|  4. R:R real mejorado: pérdida máx ≈ 1.5 ATR,                 |
//|     ganancia = banda BB (típicamente 2-4 ATR en XAUUSD)        |
//|                                                                  |
//|  MEJORAS DE CALIDAD DE ENTRADA:                                 |
//|  5. Score de señal: se necesitan 2+ sistemas concordando        |
//|  6. ADX < 30: solo operar en mercado RANGING                   |
//|     (mean reversion no funciona bien en tendencia fuerte)       |
//|  7. Distancia mínima a banda: señal solo si precio toca banda   |
//|     con al menos X% de la BB width                              |
//|  8. Sistema S4 nuevo: Squeeze BB (banda muy estrecha = inmin.   |
//|     expansión) + RSI extremo                                    |
//|  9. Confirmación vela: la vela de señal cierra en dirección     |
//|     correcta (no entrar en medio de vela activa)                |
//|                                                                  |
//|  MEJORAS DE GESTIÓN:                                            |
//| 10. BE más agresivo: 0.4×ATR (era 0.5×ATR)                    |
//| 11. Trailing más ceñido: 0.3×ATR (era 0.4×ATR)                |
//| 12. Cierre por señal opuesta: solo si la señal es >= 2 sistemas |
//| 13. Re-entrada inteligente: solo si RSI sigue en extremo        |
//| 14. Máximo 1 posición activa siempre (sin acumulación)          |
//| 15. Filtro de volatilidad: no entrar si ATR > 3× promedio       |
//|     (noticias de alto impacto)                                  |
//+------------------------------------------------------------------+
#property copyright "Fenix Pro v4.0 - DiegoSaenz"
#property version   "4.00"
#property strict
#property description "Mean Reversion XAUUSD M1/M5 con R:R mejorado"
#property description "V4.0: Score multi-sistema, ADX<30, partial TP, SL 1.5×ATR"

#include <Trade/Trade.mqh>

//=================================================================
//  PARÁMETROS DE ENTRADA
//=================================================================
input group "=== BOLLINGER BANDS ==="
input int    Inp_BB_Period    = 20;
input double Inp_BB_Sigma     = 2.0;
// BB alternativa para S2 y S4
input int    Inp_BB2_Period   = 20;
input double Inp_BB2_Sigma    = 2.0;
// BB estrecha para squeeze (S4)
input double Inp_SqueezeThreshPct = 0.008; // Ancho BB / precio < este % = squeeze

input group "=== RSI ==="
input int    Inp_RSI_Period   = 6;
input double Inp_RSI_OB       = 70.0;
input double Inp_RSI_OS       = 30.0;
input double Inp_RSI_Mid      = 50.0;
input double Inp_RSI_ExtOB    = 76.0; // Extremo para S1 y S4 (señal más fuerte)
input double Inp_RSI_ExtOS    = 24.0;

input group "=== MACD (Sistema 2) ==="
input int    Inp_MACD_Fast    = 5;
input int    Inp_MACD_Slow    = 13;
input int    Inp_MACD_Signal  = 1;

input group "=== FILTROS AVANZADOS V4.0 ==="
// ADX: solo operar en mercado RANGING (baja tendencia)
// Mean reversion funciona mal en tendencia fuerte
input bool   Inp_UseADXFilter = true;
input int    Inp_ADX_Period   = 14;
input double Inp_ADX_MaxLevel = 30.0;  // NO operar si ADX > este valor

// Filtro de tendencia H1: no operar contra tendencia de H1
input bool   Inp_UseH1Filter  = true;
input int    Inp_H1_EMA       = 50;
// Si esta activo, solo permite BUY si precio > EMA H1, SELL si precio < EMA H1
// (trading a favor de la tendencia macroestructura mientras bouncea la BB micro)
input bool   Inp_H1StrictMode = false; // false = más permisivo (ambas direcciones OK)

// Score mínimo: cuántos sistemas deben confirmar (1 o 2)
input int    Inp_MinScore     = 2;  // 2 = requiere al menos 2 sistemas → mejor filtrado

// Distancia mínima a la banda: solo entrar si precio está muy cerca de la banda
input double Inp_BandTouchPct = 0.15; // precio dentro de 15% del ancho de banda desde borde

// Filtro de volatilidad: no entrar en noticias
input bool   Inp_UseATRVolFilter = true;
input int    Inp_ATRAvgPeriod    = 20; // ATR promedio
input double Inp_ATRMaxMult      = 2.5;// Si ATR actual > N×ATR promedio → no entrar

input group "=== ATR Y RIESGO ==="
input int    Inp_ATR_Period   = 14;
input double Inp_SL_ATR       = 1.5;  // Reducido de 2.0 → mejora R:R
input double Inp_RiskPct      = 1.0;
input long   Inp_Magic        = 3002;

input group "=== PARTIAL TAKE PROFIT V4.0 ==="
// Partial: cuando el precio alcanza 1×ATR de la entrada, cerramos el 50%
// El 50% restante sigue hacia la banda BB contraria (TP final)
input bool   Inp_UsePartialTP    = true;
input double Inp_PartialATR      = 1.0;  // Cerrar 50% cuando ganancia = N×ATR
input double Inp_PartialPct      = 0.50; // Qué fracción cerrar (50%)

input group "=== TRAILING STOP & BREAKEVEN V4.0 ==="
input bool   Inp_UseTrail        = true;
input double Inp_BE_ATR          = 0.4;  // BE más agresivo (era 0.5)
input double Inp_BE_Buffer_Pts   = 3.0;
input double Inp_Trail_Start_ATR = 0.9;  // Activar trail antes (era 1.0)
input double Inp_Trail_Dist_ATR  = 0.30; // Ceñir trailing (era 0.4)

input group "=== SISTEMAS ACTIVOS ==="
input bool   Inp_UseS1           = true;  // BB Touch + RSI extremo
input bool   Inp_UseS2           = true;  // BB Media Cross + MACD
input bool   Inp_UseS3           = true;  // RSI Flip
input bool   Inp_UseS4           = true;  // BB Squeeze + RSI extremo (NUEVO)

input group "=== FILTROS DE SEGURIDAD ==="
input int    Inp_MaxSpread       = 35;    // Reducido ligeramente
input int    Inp_SessionStart    = 7;
input int    Inp_SessionEnd      = 20;
input bool   Inp_CloseFriday     = true;
input int    Inp_ReentryBars     = 2;     // Reducido de 3 → menos re-entradas agresivas

input group "=== CIRCUIT BREAKER ==="
input double Inp_MaxDailyDD      = 2.5;   // Más conservador (era 3.0)
input double Inp_MaxTotalDD      = 8.0;   // Más conservador (era 10.0)

input group "=== CIERRE POR SEÑAL CONTRARIA ==="
// V4.0: Solo cerrar por señal opuesta si al menos 2 sistemas confirman
input int    Inp_ExitMinScore    = 2;     // Señales mínimas para cierre anticipado
input bool   Inp_UseExitBySignal = true;

input group "=== PANEL ==="
input bool   Inp_Panel           = true;

//=================================================================
//  HANDLES DE INDICADORES
//=================================================================
int hBB, hBB2, hRSI, hMACD, hATR, hH1_EMA, hADX;
int hATR_Avg = INVALID_HANDLE; // Para filtro de volatilidad

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade trade;

double g_dayStartEquity  = 0;
double g_peakEquity      = 0;
bool   g_dailyBreach     = false;
bool   g_totalBreach     = false;
int    g_lastDDDay       = -1;

bool   g_reentryPending  = false;
bool   g_reentryIsBuy    = false;
int    g_reentryBarsLeft = 0;
double g_reentryBBUpper  = 0;
double g_reentryBBLower  = 0;
double g_reentryBBMid    = 0;
double g_reentryRSI      = 0; // V4.0: guardar RSI al momento de señal para re-entrada

int    g_wins            = 0;
int    g_losses          = 0;
int    g_todayTrades     = 0;
datetime g_dayRef        = 0;

string g_lastSignal      = "---";
string g_lastSystem      = "---";
int    g_lastScore       = 0;

// V4.0: control de posición
bool   g_beActivated     = false;
bool   g_trailActivated  = false;
bool   g_partialDone     = false; // partial TP ya ejecutado
double g_openEntryPrice  = 0;     // precio de entrada de la posición actual

//=================================================================
//  OnInit
//=================================================================
int OnInit() {
   trade.SetExpertMagicNumber(Inp_Magic);
   trade.SetDeviationInPoints(30);

   hBB     = iBands(_Symbol,  PERIOD_M1, Inp_BB_Period,   0, Inp_BB_Sigma,   PRICE_CLOSE);
   hBB2    = iBands(_Symbol,  PERIOD_M1, Inp_BB2_Period,  0, Inp_BB2_Sigma,  PRICE_CLOSE);
   hRSI    = iRSI(_Symbol,    PERIOD_M1, Inp_RSI_Period,  PRICE_CLOSE);
   hMACD   = iMACD(_Symbol,   PERIOD_M1, Inp_MACD_Fast, Inp_MACD_Slow, Inp_MACD_Signal, PRICE_CLOSE);
   hATR    = iATR(_Symbol,    PERIOD_M1, Inp_ATR_Period);
   hH1_EMA = iMA(_Symbol,     PERIOD_H1, Inp_H1_EMA, 0, MODE_EMA, PRICE_CLOSE);
   hADX    = iADX(_Symbol,    PERIOD_M1, Inp_ADX_Period);
   // ATR promedio para filtro de volatilidad
   hATR_Avg = iATR(_Symbol,   PERIOD_M1, Inp_ATRAvgPeriod);

   if(hBB==INVALID_HANDLE||hBB2==INVALID_HANDLE||hRSI==INVALID_HANDLE||
      hMACD==INVALID_HANDLE||hATR==INVALID_HANDLE||hH1_EMA==INVALID_HANDLE||
      hADX==INVALID_HANDLE) {
      Print("Error creando indicadores v4.0"); return INIT_FAILED;
   }

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dayRef         = TimeCurrent();

   Print("=== FENIX PRO v4.0 + MEJORAS R:R | ",_Symbol," M1 ===");
   Print("Sistemas: S1=",Inp_UseS1," S2=",Inp_UseS2," S3=",Inp_UseS3," S4(nuevo)=",Inp_UseS4);
   Print("Score mínimo: ",Inp_MinScore," sistemas concordantes para abrir");
   Print("SL: ",Inp_SL_ATR,"×ATR (reducido de 2.0 → menos pérdida máxima)");
   Print("Partial TP: 50% a ",Inp_PartialATR,"×ATR, resto a banda BB contraria");
   Print("ADX filter: ADX < ",Inp_ADX_MaxLevel," (solo ranging, NO tendencia)");
   Print("BE: ",Inp_BE_ATR,"×ATR | Trail activa: ",Inp_Trail_Start_ATR,"×ATR dist: ",Inp_Trail_Dist_ATR,"×ATR");
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason) {
   IndicatorRelease(hBB); IndicatorRelease(hBB2); IndicatorRelease(hRSI);
   IndicatorRelease(hMACD); IndicatorRelease(hATR); IndicatorRelease(hH1_EMA);
   IndicatorRelease(hADX);
   if(hATR_Avg != INVALID_HANDLE) IndicatorRelease(hATR_Avg);
   ObjectsDeleteAll(0, "FPV4_");
}

//=================================================================
//  UTILIDADES
//=================================================================
bool IsNewCandle() {
   static int lastBars = 0;
   int bars = iBars(_Symbol, PERIOD_M1);
   if(bars != lastBars) { lastBars = bars; return true; }
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

ENUM_POSITION_TYPE GetPositionType() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==Inp_Magic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol)
         return (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   }
   return (ENUM_POSITION_TYPE)-1;
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

//=================================================================
//  FILTROS
//=================================================================
bool IsInSession() {
   MqlDateTime dt; datetime srv=TimeTradeServer(); if(srv<=0) srv=TimeCurrent();
   TimeToStruct(srv,dt);
   if(dt.day_of_week==0||dt.day_of_week==6) return false;
   if(Inp_CloseFriday&&dt.day_of_week==5&&dt.hour>=20) return false;
   if(Inp_SessionStart<=Inp_SessionEnd)
      return (dt.hour>=Inp_SessionStart && dt.hour<Inp_SessionEnd);
   else
      return (dt.hour>=Inp_SessionStart || dt.hour<Inp_SessionEnd);
}

bool IsSpreadOK() {
   return (SymbolInfoInteger(_Symbol,SYMBOL_SPREAD) <= Inp_MaxSpread);
}

// V4.0: filtro ADX — solo operar en mercado ranging
bool IsMarketRanging(double adx) {
   if(!Inp_UseADXFilter) return true;
   return (adx < Inp_ADX_MaxLevel);
}

// V4.0: filtro de volatilidad — no entrar en picos de ATR (noticias)
bool IsVolatilityNormal(double atrCurrent, double atrAvg) {
   if(!Inp_UseATRVolFilter || atrAvg <= 0) return true;
   return (atrCurrent < atrAvg * Inp_ATRMaxMult);
}

// V4.0: verificar que el precio está cerca de la banda (no señal falsa a medio camino)
bool IsPriceNearBand(bool forBuy, double price, double bbU, double bbL) {
   double bbWidth = bbU - bbL;
   if(bbWidth <= 0) return false;
   double tolerance = bbWidth * Inp_BandTouchPct;
   if(forBuy)  return (price <= bbL + tolerance);
   else        return (price >= bbU - tolerance);
}

bool CheckDrawdown() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt; datetime srv=TimeTradeServer(); if(srv<=0) srv=TimeCurrent();
   TimeToStruct(srv,dt);
   if(dt.day!=g_lastDDDay) {
      g_lastDDDay=dt.day; g_dayStartEquity=equity; g_dailyBreach=false;
   }
   if(equity>g_peakEquity) g_peakEquity=equity;
   if(g_dayStartEquity>0) {
      double dd=(g_dayStartEquity-equity)/g_dayStartEquity*100.0;
      if(dd>=Inp_MaxDailyDD){
         if(!g_dailyBreach) Print(">>> CIRCUIT BREAKER DIARIO: ",DoubleToString(dd,2),"%");
         g_dailyBreach=true; return false;
      }
   }
   if(g_peakEquity>0) {
      double dd=(g_peakEquity-equity)/g_peakEquity*100.0;
      if(dd>=Inp_MaxTotalDD){
         if(!g_totalBreach) Print(">>> CIRCUIT BREAKER TOTAL: ",DoubleToString(dd,2),"%");
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
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double risk=equity*Inp_RiskPct/100.0;
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0) return SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double pipVal=tv/ts;
   double lot=risk/(slDist*pipVal);
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step>0) lot=MathFloor(lot/step)*step;
   return MathMax(minL,MathMin(maxL,lot));
}

//=================================================================
//  LEER INDICADORES
//=================================================================
bool ReadIndicators(
   double &bbU,  double &bbM,  double &bbL,
   double &bbU2, double &bbM2, double &bbL2,
   double &rsi0, double &rsi1,
   double &macdH0, double &macdH1,
   double &atr, double &atrAvg,
   double &h1ema, double &adx
) {
   double _bbU[],_bbM[],_bbL[];
   double _bbU2[],_bbM2[],_bbL2[];
   double _rsi[],_macdH[],_atr[],_atrA[],_h1[],_adx[];
   ArraySetAsSeries(_bbU,true);ArraySetAsSeries(_bbM,true);ArraySetAsSeries(_bbL,true);
   ArraySetAsSeries(_rsi,true);ArraySetAsSeries(_macdH,true);
   ArraySetAsSeries(_adx,true);

   if(CopyBuffer(hBB, 1,1,2,_bbU) <2) return false;
   if(CopyBuffer(hBB, 0,1,2,_bbM) <2) return false;
   if(CopyBuffer(hBB, 2,1,2,_bbL) <2) return false;
   if(CopyBuffer(hBB2,1,1,1,_bbU2)<1) return false;
   if(CopyBuffer(hBB2,0,1,1,_bbM2)<1) return false;
   if(CopyBuffer(hBB2,2,1,1,_bbL2)<1) return false;
   if(CopyBuffer(hRSI,0,1,2,_rsi) <2) return false;
   if(CopyBuffer(hMACD,0,1,2,_macdH)<2) return false;
   if(CopyBuffer(hATR,0,1,1,_atr) <1) return false;
   if(CopyBuffer(hH1_EMA,0,0,1,_h1)<1) return false;
   if(CopyBuffer(hADX,0,0,1,_adx) <1) return false;

   bbU=_bbU[0]; bbM=_bbM[0]; bbL=_bbL[0];
   bbU2=_bbU2[0]; bbM2=_bbM2[0]; bbL2=_bbL2[0];
   rsi0=_rsi[0]; rsi1=_rsi[1];
   macdH0=_macdH[0]; macdH1=_macdH[1];
   atr=_atr[0]; h1ema=_h1[0]; adx=_adx[0];

   // ATR promedio
   atrAvg = atr; // Default
   if(hATR_Avg!=INVALID_HANDLE) {
      if(CopyBuffer(hATR_Avg,0,1,1,_atrA)<1) return false;
      atrAvg=_atrA[0];
   }
   return true;
}

bool ReadCandles(double &h1,double &l1,double &c1,double &o1,
                 double &h2,double &l2,double &c2,double &o2) {
   double hi[],lo[],cl[],op[];
   ArraySetAsSeries(hi,true);ArraySetAsSeries(lo,true);
   ArraySetAsSeries(cl,true);ArraySetAsSeries(op,true);
   if(CopyHigh(_Symbol, PERIOD_M1,1,2,hi)<2) return false;
   if(CopyLow(_Symbol,  PERIOD_M1,1,2,lo)<2) return false;
   if(CopyClose(_Symbol,PERIOD_M1,1,2,cl)<2) return false;
   if(CopyOpen(_Symbol, PERIOD_M1,1,2,op)<2) return false;
   h1=hi[0];l1=lo[0];c1=cl[0];o1=op[0];
   h2=hi[1];l2=lo[1];c2=cl[1];o2=op[1];
   return true;
}

//=================================================================
//  SISTEMAS DE SEÑAL V4.0
//  Cada sistema retorna: 1=BUY, -1=SELL, 0=sin señal
//=================================================================

// S1: BB Touch + RSI extremo + vela confirma
// V4.0: requiere precio CERCA de la banda + vela ya cerrada en dirección
int Sistema1(double bbU, double bbM, double bbL,
             double rsi, double h1, double l1, double c1, double o1,
             double price, double h1ema) {
   if(!Inp_UseS1) return 0;
   bool isGreen = (c1 > o1);
   bool isRed   = (c1 < o1);
   bool h1Up = (!Inp_UseH1Filter || !Inp_H1StrictMode || price > h1ema);
   bool h1Dn = (!Inp_UseH1Filter || !Inp_H1StrictMode || price < h1ema);

   // V4.0: RSI extremo más estricto para S1 (más fiable)
   bool buy  = (l1 <= bbL * 1.0005)
               && (c1 > bbL)
               && isGreen
               && (rsi <= Inp_RSI_ExtOS)   // RSI extremo, no solo < 30
               && IsPriceNearBand(true, price, bbU, bbL)
               && h1Up;
   bool sell = (h1 >= bbU * 0.9995)
               && (c1 < bbU)
               && isRed
               && (rsi >= Inp_RSI_ExtOB)   // RSI extremo
               && IsPriceNearBand(false, price, bbU, bbL)
               && h1Dn;

   if(buy)  return  1;
   if(sell) return -1;
   return 0;
}

// S2: BB Media Cross + MACD (igual que antes pero con filtro H1)
int Sistema2(double bbM2, double rsi, double macdH0, double macdH1,
             double c1, double c2, double price, double h1ema) {
   if(!Inp_UseS2) return 0;
   bool h1Up = (!Inp_UseH1Filter || !Inp_H1StrictMode || price > h1ema);
   bool h1Dn = (!Inp_UseH1Filter || !Inp_H1StrictMode || price < h1ema);
   bool buy  = (c2<bbM2) && (c1>bbM2) && (macdH1<0) && (macdH0>0) && (rsi<58) && h1Up;
   bool sell = (c2>bbM2) && (c1<bbM2) && (macdH1>0) && (macdH0<0) && (rsi>42) && h1Dn;
   if(buy)  return  1;
   if(sell) return -1;
   return 0;
}

// S3: RSI Flip (sale de extremo y cruza 50)
int Sistema3(double bbU, double bbM, double bbL,
             double rsi0, double rsi1, double price, double h1ema) {
   if(!Inp_UseS3) return 0;
   bool h1Up = (!Inp_UseH1Filter || !Inp_H1StrictMode || price > h1ema);
   bool h1Dn = (!Inp_UseH1Filter || !Inp_H1StrictMode || price < h1ema);
   // V4.0: precio debe estar debajo de la media BB para BUY (mean reversion real)
   bool buy  = (rsi1<38) && (rsi0>Inp_RSI_Mid) && (price<bbM) && h1Up;
   bool sell = (rsi1>62) && (rsi0<Inp_RSI_Mid) && (price>bbM) && h1Dn;
   if(buy)  return  1;
   if(sell) return -1;
   return 0;
}

// S4 NUEVO V4.0: BB Squeeze + RSI en extremo
// Señal: las bandas BB están muy apretadas (baja volatilidad) y el RSI está en extremo
// Esto anticipa una expansión de volatilidad hacia la media
int Sistema4(double bbU, double bbM, double bbL,
             double rsi, double price, double h1ema) {
   if(!Inp_UseS4) return 0;

   // Calcular ancho relativo de BB
   double bbWidth = bbU - bbL;
   double sqeezeThresh = price * Inp_SqueezeThreshPct;
   bool isSqueeze = (bbWidth <= sqeezeThresh * 2); // banda estrecha

   if(!isSqueeze) return 0;

   bool h1Up = (!Inp_UseH1Filter || !Inp_H1StrictMode || price > h1ema);
   bool h1Dn = (!Inp_UseH1Filter || !Inp_H1StrictMode || price < h1ema);

   bool buy  = (rsi <= Inp_RSI_OS + 5) && (price < bbM) && h1Up;
   bool sell = (rsi >= Inp_RSI_OB - 5) && (price > bbM) && h1Dn;

   if(buy)  return  1;
   if(sell) return -1;
   return 0;
}

//=================================================================
//  CALCULAR SCORE TOTAL (V4.0: requiere confirmación multi-sistema)
//=================================================================
// Retorna: score positivo = señal BUY, score negativo = señal SELL
// Valor absoluto = número de sistemas que confirman
int CalculateScore(double bbU, double bbM, double bbL,
                   double bbU2, double bbM2, double bbL2,
                   double rsi0, double rsi1,
                   double macdH0, double macdH1,
                   double c1, double o1, double h1, double l1,
                   double c2, double o2,
                   double price, double h1ema, double adx) {
   int score = 0;

   score += Sistema1(bbU, bbM, bbL, rsi0, h1, l1, c1, o1, price, h1ema);
   score += Sistema2(bbM2, rsi0, macdH0, macdH1, c1, c2, price, h1ema);
   score += Sistema3(bbU, bbM, bbL, rsi0, rsi1, price, h1ema);
   score += Sistema4(bbU, bbM, bbL, rsi0, price, h1ema);

   return score;
}

//=================================================================
//  APERTURA DE ORDEN (V4.0: SL 1.5×ATR, TP = banda BB contraria)
//=================================================================
bool OpenOrder(bool isBuy, double bbUpper, double bbLower, double atr, string comment) {
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return false;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   bool ok=false;

   if(isBuy) {
      // SL: 1.5×ATR por debajo de entrada (reducido de 2.0)
      double sl  = NormalizeDouble(tick.ask - atr * Inp_SL_ATR, dg);
      // TP: banda superior (mean reversion completo)
      double tp  = NormalizeDouble(bbUpper, dg);
      double lot = CalcLot(tick.ask - sl);
      ok = trade.Buy(lot, _Symbol, tick.ask, sl, tp, comment);
      if(ok) {
         g_openEntryPrice = tick.ask;
         Print(">>> BUY V4.0 [",comment,"] Lot:",DoubleToString(lot,3),
               " SL:",DoubleToString(sl,dg)," TP_final:",DoubleToString(tp,dg),
               " SL_dist:",DoubleToString(atr*Inp_SL_ATR/_Point,0),"pts",
               " TP_dist:",DoubleToString((bbUpper-tick.ask)/_Point,0),"pts");
      }
   } else {
      double sl  = NormalizeDouble(tick.bid + atr * Inp_SL_ATR, dg);
      double tp  = NormalizeDouble(bbLower, dg);
      double lot = CalcLot(sl - tick.bid);
      ok = trade.Sell(lot, _Symbol, tick.bid, sl, tp, comment);
      if(ok) {
         g_openEntryPrice = tick.bid;
         Print(">>> SELL V4.0 [",comment,"] Lot:",DoubleToString(lot,3),
               " SL:",DoubleToString(sl,dg)," TP_final:",DoubleToString(tp,dg),
               " SL_dist:",DoubleToString(atr*Inp_SL_ATR/_Point,0),"pts",
               " TP_dist:",DoubleToString((tick.bid-bbLower)/_Point,0),"pts");
      }
   }

   if(ok) {
      g_todayTrades++;
      g_reentryPending  = false;
      g_beActivated     = false;
      g_trailActivated  = false;
      g_partialDone     = false;
   } else {
      Print("! Error orden V4.0: ",trade.ResultRetcodeDescription());
   }
   return ok;
}

//=================================================================
//  PARTIAL TP V4.0: cerrar 50% cuando precio alcanza 1×ATR
//=================================================================
void CheckPartialTP(double atr) {
   if(!Inp_UsePartialTP || g_partialDone) return;
   ulong ticket = GetCurrentTicket();
   if(ticket == 0) return;
   if(!PositionSelectByTicket(ticket)) return;

   ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double vol = PositionGetDouble(POSITION_VOLUME);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double targetDist = atr * Inp_PartialATR;

   bool doPartial = false;
   if(pt == POSITION_TYPE_BUY  && tick.bid >= g_openEntryPrice + targetDist) doPartial = true;
   if(pt == POSITION_TYPE_SELL && tick.ask <= g_openEntryPrice - targetDist) doPartial = true;

   if(!doPartial) return;

   double closeLot = NormalizeDouble(vol * Inp_PartialPct, 2);
   if(step > 0) closeLot = MathFloor(closeLot / step) * step;
   closeLot = NormalizeDouble(closeLot, 2);
   double remLot   = NormalizeDouble(vol - closeLot, 2);

   if(closeLot < minLot || remLot < minLot) return;

   if(trade.PositionClosePartial(ticket, closeLot)) {
      g_partialDone = true;
      // Mover SL a breakeven inmediatamente después del partial
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      int dg = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double beSL = (pt==POSITION_TYPE_BUY)
         ? NormalizeDouble(g_openEntryPrice + 3*_Point, dg)
         : NormalizeDouble(g_openEntryPrice - 3*_Point, dg);
      bool updBE = (pt==POSITION_TYPE_BUY) ? (beSL>curSL) : (curSL<=0||beSL<curSL);
      if(updBE) trade.PositionModify(ticket, beSL, curTP);

      double pf = PositionGetDouble(POSITION_PROFIT);
      Print(">>> PARTIAL TP V4.0: #",ticket," cerrado ",NormalizeDouble(closeLot,2),"lots",
            " @ profit actual: $",DoubleToString(pf,2),
            " | Resto: ",NormalizeDouble(remLot,2),"lots sigue a banda contraria");
   }
}

//=================================================================
//  GESTIÓN DE TRAILING + BE (V4.0: más agresivo)
//=================================================================
void ManagePosition(double atr) {
   if(!Inp_UseTrail) return;
   if(atr<=0) return;

   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;
   double buffer=Inp_BE_Buffer_Pts*_Point;

   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong ticket=PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol)   continue;

      ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openP =PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL =PositionGetDouble(POSITION_SL);
      double curTP =PositionGetDouble(POSITION_TP);
      double newSL =curSL;

      if(pt==POSITION_TYPE_BUY) {
         double price=tick.bid;
         double traveled=price-openP;

         // Fase 2: Trailing (primero chequear)
         if(traveled>=Inp_Trail_Start_ATR*atr) {
            if(!g_trailActivated){
               g_trailActivated=true;
               Print(">>> TRAIL ON V4.0 BUY: dist=",DoubleToString(Inp_Trail_Dist_ATR*atr/_Point,1),"pts");
            }
            double trailSL=NormalizeDouble(price-Inp_Trail_Dist_ATR*atr,dg);
            if(trailSL>newSL+_Point) newSL=trailSL;
         }
         // Fase 1: Breakeven (más agresivo: 0.4 ATR)
         else if(!g_beActivated&&traveled>=Inp_BE_ATR*atr) {
            double beSL=NormalizeDouble(openP+buffer,dg);
            if(beSL>newSL+_Point) newSL=beSL;
         }

         // Seguridad: SL no puede ser mayor que precio actual - minStop
         double maxSL=NormalizeDouble(price-minStop,dg);
         if(newSL>maxSL) newSL=maxSL;

         if(newSL>curSL+_Point) {
            if(trade.PositionModify(ticket,newSL,curTP)) {
               if(!g_beActivated&&!g_trailActivated){
                  g_beActivated=true;
                  Print(">>> BE V4.0 BUY: SL→",DoubleToString(newSL,dg));
               }
            }
         }

      } else if(pt==POSITION_TYPE_SELL) {
         double price=tick.ask;
         double traveled=PositionGetDouble(POSITION_PRICE_OPEN)-price;

         if(traveled>=Inp_Trail_Start_ATR*atr) {
            if(!g_trailActivated){
               g_trailActivated=true;
               Print(">>> TRAIL ON V4.0 SELL: dist=",DoubleToString(Inp_Trail_Dist_ATR*atr/_Point,1),"pts");
            }
            double trailSL=NormalizeDouble(price+Inp_Trail_Dist_ATR*atr,dg);
            if(curSL==0||trailSL<newSL-_Point) newSL=trailSL;
         }
         else if(!g_beActivated&&traveled>=Inp_BE_ATR*atr) {
            double beSL=NormalizeDouble(openP-buffer,dg);
            if(curSL==0||beSL<newSL-_Point) newSL=beSL;
         }

         double minSL=NormalizeDouble(price+minStop,dg);
         if(newSL!=0&&newSL<minSL) newSL=minSL;

         bool shouldMod=(curSL==0&&newSL>0)||(curSL>0&&newSL<curSL-_Point);
         if(shouldMod) {
            if(trade.PositionModify(ticket,newSL,curTP)) {
               if(!g_beActivated&&!g_trailActivated){
                  g_beActivated=true;
                  Print(">>> BE V4.0 SELL: SL→",DoubleToString(newSL,dg));
               }
            }
         }
      }
   }
}

//=================================================================
//  CIERRE POR SEÑAL CONTRARIA V4.0
//  Solo cerrar si al menos Inp_ExitMinScore sistemas confirman la señal contraria
//=================================================================
void CheckExitBySignal(double bbU, double bbM, double bbL,
                       double bbU2, double bbM2, double bbL2,
                       double rsi0, double rsi1,
                       double macdH0, double macdH1,
                       double c1, double o1, double h1L, double l1,
                       double c2, double o2,
                       double price, double h1ema, double adx) {
   if(!Inp_UseExitBySignal || !HasPosition()) return;

   ENUM_POSITION_TYPE pt=GetPositionType();
   int exitScore=0;

   // Solo calcular señal OPUESTA a la posición actual
   if(pt==POSITION_TYPE_BUY) {
      // ¿Cuántos sistemas dicen SELL ahora?
      if(Sistema1(bbU,bbM,bbL,rsi0,h1L,l1,c1,o1,price,h1ema)==-1) exitScore++;
      if(Sistema2(bbM2,rsi0,macdH0,macdH1,c1,c2,price,h1ema)==-1)  exitScore++;
      if(Sistema3(bbU,bbM,bbL,rsi0,rsi1,price,h1ema)==-1)           exitScore++;
      if(Sistema4(bbU,bbM,bbL,rsi0,price,h1ema)==-1)                exitScore++;
   } else {
      if(Sistema1(bbU,bbM,bbL,rsi0,h1L,l1,c1,o1,price,h1ema)==1) exitScore++;
      if(Sistema2(bbM2,rsi0,macdH0,macdH1,c1,c2,price,h1ema)==1)  exitScore++;
      if(Sistema3(bbU,bbM,bbL,rsi0,rsi1,price,h1ema)==1)           exitScore++;
      if(Sistema4(bbU,bbM,bbL,rsi0,price,h1ema)==1)                exitScore++;
   }

   if(exitScore>=Inp_ExitMinScore) {
      for(int i=PositionsTotal()-1;i>=0;i--) {
         ulong t=PositionGetTicket(i);
         if(PositionSelectByTicket(t)&&
            PositionGetInteger(POSITION_MAGIC)==Inp_Magic&&
            PositionGetString(POSITION_SYMBOL)==_Symbol) {
            double pf=PositionGetDouble(POSITION_PROFIT);
            if(trade.PositionClose(t))
               Print(">>> CIERRE V4.0 señal contraria (",exitScore," sist.) P/L:$",DoubleToString(pf,2));
         }
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
      for(int i=PositionsTotal()-1;i>=0;i--) {
         ulong t=PositionGetTicket(i);
         if(PositionSelectByTicket(t)&&
            PositionGetInteger(POSITION_MAGIC)==Inp_Magic&&
            PositionGetString(POSITION_SYMBOL)==_Symbol) {
            trade.PositionClose(t); Print(">>> CIERRE VIERNES V4.0");
         }
      }
   }
}

//=================================================================
//  PANEL V4.0
//=================================================================
void Lbl(string n,string txt,int x,int y,color c) {
   if(ObjectFind(0,n)<0){
      ObjectCreate(0,n,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,9);
      ObjectSetString(0,n,OBJPROP_FONT,"Consolas");
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
}

void UpdatePanel(string estado, double rsi, double spread, bool inSession, double adx, int score) {
   if(!Inp_Panel) return;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double pnl=eq-bal;
   double ddDay=(g_dayStartEquity>0)?(g_dayStartEquity-eq)/g_dayStartEquity*100:0;
   double ddTot=(g_peakEquity>0)?(g_peakEquity-eq)/g_peakEquity*100:0;
   int    wr=(g_wins+g_losses>0)?g_wins*100/(g_wins+g_losses):0;
   color  cp=pnl>=0?clrLimeGreen:clrOrangeRed;
   color  cs=inSession?clrLimeGreen:clrGray;
   color  cdd=ddDay<Inp_MaxDailyDD*0.7?clrLimeGreen:clrOrangeRed;
   color  cadx=(adx<Inp_ADX_MaxLevel)?clrLimeGreen:clrOrangeRed;

   string trailStatus="";
   if(Inp_UseTrail&&HasPosition()){
      if(g_trailActivated)       trailStatus=" [TRAIL]";
      else if(g_beActivated)     trailStatus=" [BE]";
      if(g_partialDone)          trailStatus+="+[PARTIAL]";
   }

   Lbl("FPV4_0","FENIX PRO v4.0 | "+_Symbol+" | M1",10,15,clrCyan);
   Lbl("FPV4_1","Bal:$"+DoubleToString(bal,2)+" P/L:$"+DoubleToString(pnl,2),10,30,cp);
   Lbl("FPV4_2","W:"+IntegerToString(g_wins)+" L:"+IntegerToString(g_losses)+
                " WR:"+IntegerToString(wr)+"% Tr:"+IntegerToString(g_todayTrades),10,45,clrYellow);
   Lbl("FPV4_3","DD dia:"+DoubleToString(ddDay,1)+"% DD tot:"+DoubleToString(ddTot,1)+"%",10,60,cdd);
   Lbl("FPV4_4","ADX:"+DoubleToString(adx,1)+(adx<Inp_ADX_MaxLevel?" RANGING":" TREND-block")+
                " RSI:"+DoubleToString(rsi,1)+
                " Spr:"+IntegerToString((int)spread),10,75,cadx);
   Lbl("FPV4_5","Score:"+IntegerToString(score)+"/4 Min:"+IntegerToString(Inp_MinScore)+
                " Estado: "+estado+trailStatus,10,90,cs);
   Lbl("FPV4_6","R:R: SL="+DoubleToString(Inp_SL_ATR,1)+"×ATR | TP=BB contraria"+
                " | PartialTP@"+DoubleToString(Inp_PartialATR,1)+"×ATR",10,105,clrSilver);
   Lbl("FPV4_7","Ult señal: ["+g_lastSystem+"] "+g_lastSignal+
                " (score "+IntegerToString(g_lastScore)+")",10,120,clrLightGray);
   Lbl("FPV4_8",g_dailyBreach?"!!! CIRCUIT BREAKER DIARIO !!!":
                g_totalBreach?"!!! CIRCUIT BREAKER TOTAL !!!":"",10,135,clrOrangeRed);
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
            Print((pf>=0?"WIN":"LOSS")," $",DoubleToString(pf,2),
                  " | W:",g_wins," L:",g_losses," WR:",wr,"%");
         }
      }
   }
}

//=================================================================
//  OnTick — LÓGICA PRINCIPAL V4.0
//=================================================================
void OnTick() {
   // 0. Reset diario
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   MqlDateTime dr; TimeToStruct(g_dayRef,dr);
   if(dt.day!=dr.day){g_todayTrades=0;g_wins=g_losses=0;g_dayRef=TimeCurrent();g_reentryPending=false;}

   // 1. Cierre viernes
   CheckFridayClose();

   // 2. Circuit breaker
   bool ddOK=CheckDrawdown();

   // 3. Leer indicadores
   double bbU,bbM,bbL,bbU2,bbM2,bbL2;
   double rsi0,rsi1,macdH0,macdH1,atr,atrAvg,h1ema,adx;
   if(!ReadIndicators(bbU,bbM,bbL,bbU2,bbM2,bbL2,rsi0,rsi1,macdH0,macdH1,atr,atrAvg,h1ema,adx)){
      UpdatePanel("ERR indicadores",0,0,false,0,0); return;
   }
   double h1,l1,c1,o1,h2,l2,c2,o2;
   if(!ReadCandles(h1,l1,c1,o1,h2,l2,c2,o2)){
      UpdatePanel("ERR velas",rsi0,0,false,adx,0); return;
   }
   MqlTick tick; if(!SymbolInfoTick(_Symbol,tick)) return;
   double price=tick.last;
   double spread=(tick.ask-tick.bid)/_Point;
   bool inSession=IsInSession();
   bool spreadOK=IsSpreadOK();
   bool ranging=IsMarketRanging(adx);
   bool volOK=IsVolatilityNormal(atr,atrAvg);

   // 4. Gestionar posición abierta (trailing, BE, partial)
   if(HasPosition()) {
      // Partial TP primero
      CheckPartialTP(atr);
      // Trailing y BE
      ManagePosition(atr);
      // Cierre por señal contraria (solo en vela nueva)
      if(IsNewCandle())
         CheckExitBySignal(bbU,bbM,bbL,bbU2,bbM2,bbL2,rsi0,rsi1,
                           macdH0,macdH1,c1,o1,h1,l1,c2,o2,price,h1ema,adx);
      UpdatePanel("EN POSICION | "+g_lastSystem,rsi0,spread,inSession,adx,g_lastScore);
      return;
   }

   // 5. Verificar condiciones para abrir
   if(!ddOK) {
      UpdatePanel("CIRCUIT BREAKER",rsi0,spread,inSession,adx,0); return;
   }
   if(!inSession) {
      UpdatePanel("Fuera de sesion",rsi0,spread,false,adx,0); return;
   }
   if(!spreadOK) {
      UpdatePanel("Spread alto: "+IntegerToString((int)spread),rsi0,spread,inSession,adx,0); return;
   }
   if(!ranging) {
      UpdatePanel("ADX TRENDING ("+DoubleToString(adx,1)+") - esperando ranging",rsi0,spread,inSession,adx,0); return;
   }
   if(!volOK) {
      UpdatePanel("VOLATILIDAD ALTA (noticias?) - bloqueado",rsi0,spread,inSession,adx,0); return;
   }

   // 6. Analizar solo en vela nueva
   if(!IsNewCandle()) {
      // Re-entrada en tick: verificar si el RSI sigue en extremo
      if(g_reentryPending && g_reentryBarsLeft > 0) {
         // V4.0: solo re-entrar si el RSI sigue en extremo
         bool rsiStillExtreme = (g_reentryIsBuy && rsi0 <= Inp_RSI_OS+5) ||
                                (!g_reentryIsBuy && rsi0 >= Inp_RSI_OB-5);
         if(rsiStillExtreme) {
            if(g_reentryIsBuy && tick.ask <= g_reentryBBLower*1.0005) {
               if(OpenOrder(true, g_reentryBBUpper, g_reentryBBLower, atr, "S1_REENTRY"))
               {g_lastSignal="REENTRY-BUY"; g_lastSystem="S1r";}
            } else if(!g_reentryIsBuy && tick.bid >= g_reentryBBUpper*0.9995) {
               if(OpenOrder(false, g_reentryBBUpper, g_reentryBBLower, atr, "S1_REENTRY"))
               {g_lastSignal="REENTRY-SELL"; g_lastSystem="S1r";}
            }
         } else {
            g_reentryPending=false;
            Print("Re-entrada cancelada: RSI ya no en extremo (",DoubleToString(rsi0,1),")");
         }
      }
      UpdatePanel(g_reentryPending?"REENTRY pendiente...":"Esperando vela...",rsi0,spread,inSession,adx,0);
      return;
   }

   // Decrementar re-entrada en vela nueva
   if(g_reentryPending) {
      g_reentryBarsLeft--;
      if(g_reentryBarsLeft<=0){g_reentryPending=false;Print("Re-entrada expirada");}
   }

   // 7. CALCULAR SCORE (cuántos sistemas confirman)
   int scoreRaw = CalculateScore(bbU,bbM,bbL,bbU2,bbM2,bbL2,
                                 rsi0,rsi1,macdH0,macdH1,
                                 c1,o1,h1,l1,c2,o2,price,h1ema,adx);
   int absScore = (int)MathAbs(scoreRaw);
   bool isBuySignal  = (scoreRaw >= Inp_MinScore);
   bool isSellSignal = (scoreRaw <= -Inp_MinScore);

   // Determinar sistema principal para logging
   string sysName="";
   if(Sistema1(bbU,bbM,bbL,rsi0,h1,l1,c1,o1,price,h1ema)!=0) sysName="S1+";
   if(Sistema2(bbM2,rsi0,macdH0,macdH1,c1,c2,price,h1ema)!=0) sysName+=sysName.Length()>0?"S2+":"S2+";
   if(Sistema3(bbU,bbM,bbL,rsi0,rsi1,price,h1ema)!=0)          sysName+=sysName.Length()>0?"S3":"S3";
   if(Sistema4(bbU,bbM,bbL,rsi0,price,h1ema)!=0)                sysName+=sysName.Length()>0?"+S4":"+S4";
   if(sysName=="") sysName="---";

   // 8. EJECUTAR SEÑAL (requiere score mínimo)
   if(isBuySignal || isSellSignal) {
      bool isBuy = isBuySignal;
      string sigTxt = isBuy?"BUY":"SELL";
      g_lastSignal = sigTxt; g_lastSystem = sysName; g_lastScore = absScore;

      Print(">>> SEÑAL V4.0: ",sigTxt," score=",absScore,"/4 sistemas=[",sysName,"]",
            " RSI=",DoubleToString(rsi0,1)," ADX=",DoubleToString(adx,1));

      if(OpenOrder(isBuy, bbU, bbL, atr, sysName)) {
         UpdatePanel("ENTRO "+sigTxt+" ["+sysName+"] s:"+IntegerToString(absScore),
                     rsi0,spread,inSession,adx,absScore);
      } else {
         // Intentar re-entrada si falló la apertura
         if(Inp_ReentryBars>0) {
            g_reentryPending=true;
            g_reentryIsBuy=isBuy;
            g_reentryBarsLeft=Inp_ReentryBars;
            g_reentryBBUpper=bbU; g_reentryBBLower=bbL; g_reentryBBMid=bbM;
            g_reentryRSI=rsi0;
            Print(">>> Re-entrada V4.0 activada: ",sigTxt," por ",Inp_ReentryBars," velas");
            UpdatePanel("REENTRY "+sigTxt+" pendiente ["+sysName+"]",rsi0,spread,inSession,adx,absScore);
         }
      }
      return;
   }

   // 9. Sin señal suficiente
   string estado="";
   if(rsi0<35)       estado="RSI bajo ("+DoubleToString(rsi0,0)+") buscando BUY";
   else if(rsi0>65)  estado="RSI alto ("+DoubleToString(rsi0,0)+") buscando SELL";
   else              estado="RSI neutral ("+DoubleToString(rsi0,0)+")";
   if(Inp_UseH1Filter) estado+=(price>h1ema)?" H1:^":" H1:v";
   UpdatePanel(estado+" score:"+IntegerToString(absScore)+"/4",rsi0,spread,inSession,adx,absScore);
}
//+------------------------------------------------------------------+