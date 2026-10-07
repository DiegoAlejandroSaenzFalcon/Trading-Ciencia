//+------------------------------------------------------------------+
//|           DIEGO SAENZ EA - V6.0  (London + NY Sessions)         |
//|                                                                  |
//|  CORRECCIONES CRÍTICAS vs V3.0/V5.0:                           |
//|                                                                  |
//|  PROBLEMA RAÍZ IDENTIFICADO (análisis historial 20/03/2026):   |
//|  - Ganancia promedio: $0.58 | Pérdida promedio: -$1.89          |
//|  - Ratio R:R real: 1:3.24 — completamente invertido             |
//|  - 302 operaciones en 1 día → sobre-trading destructivo         |
//|  - Sin SL real en la mayoría de posiciones                      |
//|  - Harvest a $0.15 mientras pérdidas abiertas de -$5 a -$10    |
//|                                                                  |
//|  SOLUCIONES V6.0:                                               |
//|  1. R:R mínimo 2:1 forzado: TP = 2.5×ATR, SL = 1.2×ATR        |
//|  2. SL duro OBLIGATORIO en cada posición                        |
//|  3. Harvest mínimo = 2.0×ATR (no $0.15 ridiculos)              |
//|  4. Máximo 6 posiciones total (era 15)                          |
//|  5. CT máximo 2 niveles por dirección antes de forzar basket TP |
//|  6. Basket TP: cerrar todo al alcanzar objetivo neto            |
//|  7. Cycle Max Loss: -1.5×ATR equivalente                        |
//|  8. Partial close: 50% al 1:1, SL a breakeven, 50% corre libre |
//|  9. Solo sesiones Londres (7-17 GMT) y NY (13-22 GMT)          |
//| 10. Counter-trade OPUESTO siempre (hedge verdadero)             |
//| 11. Pausa 60s entre primarias + 1 primaria a la vez            |
//| 12. Neutralizador eliminado (generaba ruido, no cobertura)      |
//+------------------------------------------------------------------+
#property copyright "DiegoSaenz EA V6.0"
#property version   "6.00"
#property strict
#property description "Motor contra-trading XAUUSD con R:R >= 2:1 forzado"
#property description "V6.0: Correccion fundamental del ratio riesgo/recompensa"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   60
#define VERSION_STR   "DIEGOSAENZ_V6.0"

//=================================================================
//  ENUMERACIONES
//=================================================================
enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

//=================================================================
//  PARÁMETROS DE ENTRADA
//=================================================================
input group "═══ CONFIGURACIÓN PRINCIPAL ═══"
input long   Inp_Magic             = 6000;
input int    Inp_MaxPositionsTotal = 6;      // Máx posiciones (reducido de 15)
input double Inp_LotBase           = 0.01;
input double Inp_LotMaximum        = 0.03;   // Reducido para cuenta pequeña
input double Inp_RiskPerTradePct   = 0.01;   // 1% por operación
input double Inp_BalanceRiskPct    = 0.10;
input bool   Inp_UseDynamicLot     = true;
input double Inp_CTMinBalanceUSD   = 50.0;
input double Inp_MinFreeMarginPct  = 0.40;

input group "═══ SL/TP — CORAZÓN DEL R:R ═══"
// REGLA DE ORO V6.0: TP siempre >= 2 x SL
// Con SL=1.2 ATR y TP=2.5 ATR → R:R = 2.08:1
// Objetivo: avg_win / avg_loss >= 2.0
input double Inp_SL_ATR            = 1.2;   // Stop Loss = N × ATR
input double Inp_TP_ATR            = 2.5;   // Take Profit = N × ATR (SIEMPRE >= 2×SL)
input double Inp_TP_MinPoints      = 80;    // TP mínimo en puntos (protección broker)
input double Inp_SL_MinPoints      = 40;    // SL mínimo en puntos
// Partial close: protege capital sin sacrificar el objetivo principal
input bool   Inp_UsePartialClose   = true;
input double Inp_Partial_ATR       = 1.2;   // Cerrar 50% cuando precio = entrada + N×ATR
input double Inp_PartialPct        = 0.50;  // Qué % cerrar en el partial (0.50 = 50%)

input group "═══ TRAILING STOP ═══"
input bool   Inp_UseTrailSL        = true;
input double Inp_TrailStart_ATR    = 1.5;   // Activar trailing cuando ganancia >= N×ATR
input double Inp_TrailDist_ATR     = 0.6;   // Distancia del trailing en ATR
input double Inp_BE_ATR            = 0.8;   // Breakeven cuando ganancia >= N×ATR

input group "═══ COUNTER-TRADE ENGINE ═══"
input ENUM_CT_MODE Inp_CTMode      = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR     = 1.2;   // Distancia mínima entre CTs del mismo tipo
input int    Inp_CTFixedPoints     = 100;
input int    Inp_CTIntervalSec     = 10;    // Tiempo mínimo entre CTs (era 5, aumentado)
input int    Inp_CTMaxSameDir      = 2;     // Máx CTs misma dirección (era 4, reducido)
input int    Inp_PrimaryCooldownSec= 90;    // Tiempo entre primarias (era 60)
input double Inp_CTMaxSpreadPoints = 30;

input group "═══ BASKET TP CENTRALIZADO ═══"
// Clave: cuando el P&L neto del ciclo supera el objetivo, cerrar TODO
// Objetivo mínimo = 2.0 × pérdida máxima esperada del ciclo
input bool   Inp_UseBasketTP       = true;
input double Inp_BasketTPFactor    = 0.80;  // USD mínimo para activar basket TP
input double Inp_BasketTPRatio     = 2.0;   // TP = N × ganancia promedio del ciclo
input int    Inp_BasketCheckSec    = 3;

input group "═══ HARVEST — UMBRAL REAL ═══"
// CRÍTICO: Harvest mínimo debe ser >= 2x el spread esperado
// Con ATR de oro ~5 USD por 0.01 lote, mínimo viable = 1.0 USD
input double Inp_HarvestMinUSD     = 0.80;  // Era $0.15 → imposible cubrir pérdidas
input double Inp_HarvestATRMult    = 0.20;  // Harvest = max(HarvestMinUSD, ATR*mult)
input bool   Inp_HarvestContinuous = true;
input int    Inp_HarvestIntervalSec= 3;

input group "═══ CLUSTER OPTIMIZER ═══"
input double Inp_ClusterCoverFactor= 1.30;  // Cobertura mínima 1.3×
input double Inp_ClusterMinExcedent= 0.40;
input int    Inp_ClusterIntervalSec= 3;

input group "═══ CYCLE MAX LOSS ═══"
input bool   Inp_UseCycleMaxLoss   = true;
input double Inp_CycleMaxLossUSD   = -1.50; // Pérdida máxima del ciclo
input double Inp_CycleMaxLossRatio = 1.5;   // O N × ganancia promedio
input int    Inp_CyclePauseSec     = 45;    // Pausa post-reset de ciclo

input group "═══ FILTRO DE SESIÓN ═══"
// Solo Londres y NY: mayor liquidez, spreads menores, tendencias más claras
input bool   Inp_UseSessionFilter  = true;
input int    Inp_GMTOffset         = 0;     // Ajuste GMT del broker
input int    Inp_LondonOpen        = 7;     // 7 GMT
input int    Inp_LondonClose       = 17;    // 17 GMT
input int    Inp_NYOpen            = 13;    // 13 GMT
input int    Inp_NYClose           = 22;    // 22 GMT

input group "═══ ADX + TENDENCIA ═══"
input bool   Inp_UseADX            = true;
input int    Inp_ADXPeriod         = 14;
input double Inp_ADXTrendLevel     = 30.0;  // Tendencia fuerte si ADX > 30
input bool   Inp_UseHTF            = true;
input ENUM_TIMEFRAMES Inp_HTFTF    = PERIOD_M5;

input group "═══ PROTECCIÓN DIARIA ═══"
input bool   Inp_UseDailyLimit     = true;
input double Inp_DailyLossUSD      = -4.0;  // Máximo -$4 por día
input double Inp_DailyLossPct      = 0.02;  // O -2% del balance
input int    Inp_LossStreakMax      = 3;     // Reducir lotes tras 3 pérdidas
input double Inp_LossStreakReduce   = 0.60;

input group "═══ EQUITY GUARD ═══"
input bool   Inp_UseEquityGuard    = true;
input double Inp_EmergencyLossUSD  = -4.0;
input double Inp_MaxDrawdownPct    = 0.12;
input int    Inp_EmergencyCooldown = 180;

input group "═══ INDICADORES ═══"
input int    Inp_ATRPeriod         = 14;
input int    Inp_EMAFast           = 21;
input int    Inp_EMASlow           = 55;
input int    Inp_RSIPeriod         = 7;
input int    Inp_MACDFast          = 12;
input int    Inp_MACDSlow          = 26;
input int    Inp_MACDSig           = 9;

input group "═══ CONTROL ═══"
input int    Inp_MaxSpread         = 35;
input bool   Inp_ShowDashboard     = true;
input int    Inp_DashX             = 12;
input int    Inp_DashY             = 28;

//=================================================================
//  ESTRUCTURA DE REGISTRO DE POSICIÓN
//=================================================================
struct PosRecord {
   ulong    ticket;
   int      posType;
   double   openPrice;
   double   volume;
   double   netProfit;
   datetime openTime;
   string   comment;
   bool     isPrimary;
   bool     isCounter;
   double   peakProfit;
   bool     wallActive;
   bool     beActivated;
   bool     trailActivated;
   bool     partialDone;
   double   kX; double kP; double kK; bool kInit;
};

struct Portfolio {
   int    totalPos;
   int    buyCount, sellCount;
   double buyProfit, sellProfit;
   double totalProfit;
   double positiveSum, negativeSum;
   ulong  worstTicket; double worstProfit;
   int    ctCount;
   double currentDD;
};

struct MarketSnap {
   double bid, ask;
   double atr;
   double emaFast, emaSlow;
   double rsi;
   double macdMain, macdSig;
   double adx;
   int    htfTrend;
   double spread;
   bool   isBullish, isBearish;
};

//=================================================================
//  HANDLES
//=================================================================
int h_ATR, h_EMAFast, h_EMASlow, h_RSI, h_MACD;
int h_ADX = INVALID_HANDLE;
int h_HTFEMAFast = INVALID_HANDLE, h_HTFEMASlow = INVALID_HANDLE;

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade       m_trade;
PosRecord    m_rec[MAX_RECORDS];
Portfolio    m_port;
MarketSnap   m_mkt;

double m_initialBalance     = 0;
double m_bestEquity         = 0;
bool   m_isPaused           = false;
bool   m_emergencyMode      = false;
bool   m_dailyLimitHit      = false;
bool   m_inSession          = false;

// Ciclo
double m_cycleWinsSum       = 0;
int    m_cycleWinsCount     = 0;
double m_cycleLossSum       = 0;
bool   m_cycleInPause       = false;
datetime m_cycleResetTime   = 0;

// Racha
int    m_consecutiveLosses  = 0;
double m_lotMultiplier      = 1.0;

// Diario
double m_dailyBalance       = 0;
datetime m_lastDailyReset   = 0;

// Primaria
int    m_lastPrimaryDir     = 0;
datetime m_lastPrimaryTime  = 0;
bool   m_lastPrimaryLost    = false;

// CT
double m_lastCTBuyPrice     = 0;
double m_lastCTSellPrice    = 0;
datetime m_lastCTTime       = 0;
datetime m_lastBasketCheck  = 0;
datetime m_lastHarvestTime  = 0;
datetime m_lastClusterTime  = 0;
datetime m_lastCleanupTime  = 0;
datetime m_lastDashTime     = 0;

// Stats
double m_totalPnL           = 0;
int    m_tradesOpened       = 0;
int    m_tradesClosed       = 0;
double m_bestClosed         = 0;
double m_worstClosed        = 0;
long   m_tickCount          = 0;
bool   m_isProcessing       = false;

//=================================================================
//  HELPERS BÁSICOS
//=================================================================
double NormLot(double lot) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), Inp_LotMaximum);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   return NormalizeDouble(MathMax(minL, MathMin(maxL, lot)), 2);
}

double NormPrice(double p) { return NormalizeDouble(p, _Digits); }

bool GetTick(MqlTick &t) { return SymbolInfoTick(_Symbol, t); }

double GetATR() {
   double b[1];
   if(CopyBuffer(h_ATR, 0, 1, 1, b) == 1) return b[0];
   return _Point * 200;
}

double GetTickVal() { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize(){ return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); }

double PipUSD(double lot) {
   double tv = GetTickVal(), ts = GetTickSize();
   return (ts > 0) ? lot * tv * (_Point / ts) : lot * tv;
}

// Calcular cuánto vale N puntos en USD para un lote dado
double PointsToUSD(double points, double lot) {
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv <= 0 || ts <= 0) return points * lot;
   return (points / ts) * tv * lot;
}

bool SpreadOK() {
   return (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= Inp_MaxSpread);
}

bool MarginOK(double lot, ENUM_ORDER_TYPE type) {
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_CTMinBalanceUSD) return false;
   if(free < eq * Inp_MinFreeMarginPct) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg))
      if(marg > free * 0.55) return false;
   return true;
}

//=================================================================
//  RECORDS (gestión de posiciones)
//=================================================================
int FindRec(ulong ticket) {
   for(int i = 0; i < MAX_RECORDS; i++)
      if(m_rec[i].ticket == ticket) return i;
   return -1;
}

int FreeRec() {
   for(int i = 0; i < MAX_RECORDS; i++)
      if(m_rec[i].ticket == 0) return i;
   return -1;
}

void InitRec(int idx, ulong ticket, int posType, double openPrice, double vol,
             string comment, bool isPrimary, bool isCounter) {
   if(idx < 0 || idx >= MAX_RECORDS) return;
   ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket     = ticket;
   m_rec[idx].posType    = posType;
   m_rec[idx].openPrice  = openPrice;
   m_rec[idx].volume     = vol;
   m_rec[idx].openTime   = TimeCurrent();
   m_rec[idx].comment    = comment;
   m_rec[idx].isPrimary  = isPrimary;
   m_rec[idx].isCounter  = isCounter;
   m_rec[idx].kP         = 1.0; m_rec[idx].kK = 1.0;
}

void CleanupRecs() {
   for(int i = 0; i < MAX_RECORDS; i++) {
      if(m_rec[i].ticket == 0) continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)) {
         double pnl = m_rec[i].netProfit;
         if(pnl != 0) {
            m_totalPnL += pnl; m_tradesClosed++;
            if(pnl > m_bestClosed)  m_bestClosed  = pnl;
            if(pnl < m_worstClosed) m_worstClosed = pnl;
         }
         ZeroMemory(m_rec[i]);
      }
   }
}

void SyncPositions() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(FindRec(t) >= 0) continue;
      int idx = FreeRec(); if(idx < 0) continue;
      int pt = (int)PositionGetInteger(POSITION_TYPE);
      double op = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol = PositionGetDouble(POSITION_VOLUME);
      string comm = PositionGetString(POSITION_COMMENT);
      bool isPrim = (StringFind(comm, "Primary") >= 0);
      bool isCT   = (StringFind(comm, "CT_") >= 0);
      InitRec(idx, t, pt, op, vol, comm, isPrim, isCT);
   }
}

//=================================================================
//  KALMAN FILTER (suavizado para P&L)
//=================================================================
void KalmanUpdate(int idx, double meas) {
   if(!m_rec[idx].kInit) {
      m_rec[idx].kX = meas; m_rec[idx].kP = 1.0;
      m_rec[idx].kK = 1.0; m_rec[idx].kInit = true; return;
   }
   double pPred = m_rec[idx].kP + 0.01;
   double K = pPred / (pPred + 0.20);
   m_rec[idx].kX = m_rec[idx].kX + K * (meas - m_rec[idx].kX);
   m_rec[idx].kP = (1.0 - K) * pPred;
   m_rec[idx].kK = K;
}

void UpdateKalman() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int idx = FindRec(t); if(idx < 0) continue;
      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit = pf;
      if(pf > m_rec[idx].peakProfit) m_rec[idx].peakProfit = pf;
      KalmanUpdate(idx, pf);
      MqlTick tick; if(!GetTick(tick)) continue;
      // Tracking de precio mejor visto
   }
}

//=================================================================
//  MERCADO
//=================================================================
void UpdateMarket() {
   MqlTick t; if(!GetTick(t)) return;
   m_mkt.bid = t.bid; m_mkt.ask = t.ask;
   m_mkt.spread = (t.ask - t.bid) / _Point;
   m_mkt.atr = GetATR();

   double f[1], s[1], r[1], m[1], sg[1];
   if(CopyBuffer(h_EMAFast, 0, 0, 1, f) == 1) m_mkt.emaFast = f[0];
   if(CopyBuffer(h_EMASlow, 0, 0, 1, s) == 1) m_mkt.emaSlow = s[0];
   if(CopyBuffer(h_RSI,     0, 0, 1, r) == 1) m_mkt.rsi = r[0];
   if(CopyBuffer(h_MACD,    0, 0, 1, m) == 1) m_mkt.macdMain = m[0];
   if(CopyBuffer(h_MACD,    1, 0, 1, sg)== 1) m_mkt.macdSig  = sg[0];

   if(h_ADX != INVALID_HANDLE) {
      double adxB[1];
      if(CopyBuffer(h_ADX, 0, 0, 1, adxB) == 1) m_mkt.adx = adxB[0];
   }

   if(h_HTFEMAFast != INVALID_HANDLE && h_HTFEMASlow != INVALID_HANDLE) {
      double hf[1], hs[1];
      if(CopyBuffer(h_HTFEMAFast, 0, 0, 1, hf) == 1 &&
         CopyBuffer(h_HTFEMASlow, 0, 0, 1, hs) == 1) {
         if(hf[0] > hs[0] * 1.0001) m_mkt.htfTrend = 1;
         else if(hf[0] < hs[0] * 0.9999) m_mkt.htfTrend = -1;
         else m_mkt.htfTrend = 0;
      }
   }

   m_mkt.isBullish = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.rsi > 52 && m_mkt.macdMain > m_mkt.macdSig);
   m_mkt.isBearish = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.rsi < 48 && m_mkt.macdMain < m_mkt.macdSig);
}

void UpdatePortfolio() {
   ZeroMemory(m_port);
   m_port.worstProfit = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int pt  = (int)PositionGetInteger(POSITION_TYPE);
      double pf = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      string comm = PositionGetString(POSITION_COMMENT);
      m_port.totalPos++;
      m_port.totalProfit += pf;
      if(pf >= 0) m_port.positiveSum += pf;
      else        m_port.negativeSum += MathAbs(pf);
      if(pt == POSITION_TYPE_BUY) { m_port.buyCount++; m_port.buyProfit += pf; }
      else { m_port.sellCount++; m_port.sellProfit += pf; }
      if(pf < m_port.worstProfit) { m_port.worstProfit = pf; m_port.worstTicket = t; }
      if(StringFind(comm, "CT_") >= 0) m_port.ctCount++;
   }
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > m_bestEquity) m_bestEquity = eq;
   m_port.currentDD = (m_bestEquity > 0) ? (m_bestEquity - eq) / m_bestEquity : 0;
}

//=================================================================
//  SESIÓN
//=================================================================
bool IsInSession() {
   if(!Inp_UseSessionFilter) return true;
   datetime now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   int gmtHour = (dt.hour - Inp_GMTOffset + 24) % 24;
   bool london = (gmtHour >= Inp_LondonOpen && gmtHour < Inp_LondonClose);
   bool ny     = (gmtHour >= Inp_NYOpen     && gmtHour < Inp_NYClose);
   return (london || ny);
}

//=================================================================
//  ADX FILTER
//=================================================================
bool ADXAllowsEntry(ENUM_ORDER_TYPE type) {
   if(!Inp_UseADX) return true;
   double adx = m_mkt.adx;
   if(adx < Inp_ADXTrendLevel) return true; // Mercado lateral: OK
   int htf = m_mkt.htfTrend;
   if(htf == 0) return false; // Tendencia fuerte sin confirmación HTF: NO
   if(type == ORDER_TYPE_BUY  && htf ==  1) return true;
   if(type == ORDER_TYPE_SELL && htf == -1) return true;
   static datetime lastLog = 0;
   if(TimeCurrent() - lastLog > 20) {
      Print(">>> ADX BLOCK: ADX=", NormalizeDouble(adx,1), " HTF=", htf,
            " Type=", (type==ORDER_TYPE_BUY?"BUY":"SELL"));
      lastLog = TimeCurrent();
   }
   return false;
}

//=================================================================
//  DIARIO
//=================================================================
void ResetDailyIfNeeded() {
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int sec = dt.hour*3600 + dt.min*60 + dt.sec;
   datetime midnight = TimeCurrent() - sec;
   if(m_lastDailyReset < midnight) {
      m_dailyBalance    = AccountInfoDouble(ACCOUNT_BALANCE);
      m_dailyLimitHit   = false;
      m_lastDailyReset  = midnight;
      Print(">>> RESET DIARIO V6: Balance=$", NormalizeDouble(m_dailyBalance,2));
   }
}

bool DailyLimitReached() {
   if(!Inp_UseDailyLimit) return false;
   if(m_dailyLimitHit) return true;
   double eff = (AccountInfoDouble(ACCOUNT_BALANCE) - m_dailyBalance) + m_port.totalProfit;
   double lim = MathMin(MathAbs(Inp_DailyLossUSD),
                        m_dailyBalance * MathAbs(Inp_DailyLossPct));
   if(eff <= -lim) {
      Print(">>> LÍMITE DIARIO: PnL=$", NormalizeDouble(eff,2), " Límite=-$", NormalizeDouble(lim,2));
      m_dailyLimitHit = true; m_isPaused = true;
      for(int i = PositionsTotal()-1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
         if(PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) < 0)
            ClosePos(t, "DailyLimit");
      }
      return true;
   }
   return false;
}

//=================================================================
//  RACHA
//=================================================================
void UpdateStreak(double pnl) {
   if(pnl < -0.01) {
      m_consecutiveLosses++;
      if(m_consecutiveLosses >= Inp_LossStreakMax && m_lotMultiplier == 1.0) {
         m_lotMultiplier = Inp_LossStreakReduce;
         Print(">>> RACHA NEGATIVA: ", m_consecutiveLosses, " pérdidas → lote ×",
               NormalizeDouble(Inp_LossStreakReduce, 2));
      }
   } else if(pnl > 0.01) {
      if(m_lotMultiplier < 1.0) {
         m_lotMultiplier = 1.0;
         Print(">>> RACHA RECUPERADA → lote normalizado");
      }
      m_consecutiveLosses = 0;
   }
}

//=================================================================
//  CIERRE DE POSICIÓN
//=================================================================
bool ClosePos(ulong ticket, string reason = "") {
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)) {
      UpdateStreak(pf);
      // Estadísticas ciclo
      if(pf > 0) { m_cycleWinsSum += pf; m_cycleWinsCount++; }
      else          m_cycleLossSum += pf;
      // Estadísticas globales
      m_totalPnL += pf; m_tradesClosed++;
      if(pf > m_bestClosed) m_bestClosed = pf;
      if(pf < m_worstClosed) m_worstClosed = pf;
      // Detectar si la primaria cerró en pérdida
      int idx = FindRec(ticket);
      if(idx >= 0 && m_rec[idx].isPrimary) {
         m_lastPrimaryLost = (pf < 0);
         if(pf < 0) Print(">>> PRIMARY LOST: dir=", m_lastPrimaryDir, " pnl=$", NormalizeDouble(pf,2));
      }
      Print(">>> CERRADA #", ticket, " $", NormalizeDouble(pf,2),
            (reason!=""?" ["+reason+"]":""),
            " | Total: $", NormalizeDouble(m_totalPnL,2));
      if(idx >= 0) ZeroMemory(m_rec[idx]);
      return true;
   }
   return false;
}

//=================================================================
//  LOT DINÁMICO
//=================================================================
double CalcLot(int level = 0) {
   double atr = m_mkt.atr;
   if(!Inp_UseDynamicLot || atr <= 0) {
      return NormLot(Inp_LotBase * m_lotMultiplier);
   }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskUSD = bal * Inp_RiskPerTradePct;
   double slDist  = atr * Inp_SL_ATR;
   double tv = GetTickVal(), ts = GetTickSize();
   double lot = Inp_LotBase;
   if(tv > 0 && ts > 0 && slDist > 0) {
      double pipV = tv / ts;
      if(pipV > 0) lot = riskUSD / (slDist * pipV);
   }
   lot = MathMax(lot, Inp_LotBase);
   lot *= m_lotMultiplier;
   return NormLot(lot);
}

//=================================================================
//  APERTURA DE ORDEN — CON SL/TP OBLIGATORIOS
//  REGLA FUNDAMENTAL V6.0:
//  Toda orden DEBE tener SL y TP calculados con R:R >= 2:1
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type, double lot, string comment) {
   if(m_isPaused || m_emergencyMode) return 0;
   if(!SpreadOK()) return 0;
   if(PositionsTotal() >= Inp_MaxPositionsTotal) return 0;
   lot = NormLot(lot);
   if(lot <= 0) return 0;
   if(!MarginOK(lot, type)) return 0;

   MqlTick t; if(!GetTick(t)) return 0;
   double atr = m_mkt.atr;
   if(atr <= 0) return 0;

   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   int dg = _Digits;

   // SL y TP OBLIGATORIOS con R:R = TP/SL >= 2:1
   double slDist = MathMax(atr * Inp_SL_ATR, Inp_SL_MinPoints * _Point);
   double tpDist = MathMax(atr * Inp_TP_ATR, Inp_TP_MinPoints * _Point);
   // Forzar R:R mínimo 2:1
   if(tpDist < slDist * 1.8) tpDist = slDist * 2.0;

   double sl = 0, tp = 0;
   if(type == ORDER_TYPE_BUY) {
      sl = NormPrice(price - slDist);
      tp = NormPrice(price + tpDist);
   } else {
      sl = NormPrice(price + slDist);
      tp = NormPrice(price - tpDist);
   }

   bool ok = (type == ORDER_TYPE_BUY)
      ? m_trade.Buy(lot, _Symbol, price, sl, tp, comment)
      : m_trade.Sell(lot, _Symbol, price, sl, tp, comment);

   if(!ok) {
      Print(">>> ERR ORDEN: ", m_trade.ResultRetcodeDescription());
      return 0;
   }
   ulong ticket = m_trade.ResultOrder();
   if(ticket > 0) {
      m_tradesOpened++;
      double rr = tpDist / slDist;
      Print(">>> ABIERTA #", ticket, " ", (type==ORDER_TYPE_BUY?"BUY":"SELL"),
            " ", lot, " @ ", NormalizeDouble(price,dg),
            " SL=", NormalizeDouble(sl,dg), " TP=", NormalizeDouble(tp,dg),
            " R:R=1:", NormalizeDouble(rr,2), " [", comment, "]");
   }
   return ticket;
}

//=================================================================
//  GESTIÓN INDIVIDUAL: TRAILING + PARTIAL CLOSE
//=================================================================
void ManagePositions() {
   double atr = m_mkt.atr;
   if(atr <= 0) return;
   MqlTick t; if(!GetTick(t)) return;
   int dg = _Digits;
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minStop = (stopsLevel + 3) * _Point;

   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      int idx = FindRec(ticket); if(idx < 0) continue;
      int pt = m_rec[idx].posType;
      double op = m_rec[idx].openPrice;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);
      double pf = m_rec[idx].netProfit;

      // Partial close: cerrar 50% cuando llegamos a 1 ATR de ganancia
      if(Inp_UsePartialClose && !m_rec[idx].partialDone) {
         bool doPartial = false;
         if(pt == POSITION_TYPE_BUY  && t.bid >= NormPrice(op + atr * Inp_Partial_ATR)) doPartial = true;
         if(pt == POSITION_TYPE_SELL && t.ask <= NormPrice(op - atr * Inp_Partial_ATR)) doPartial = true;
         if(doPartial) {
            double closeLot = NormLot(vol * Inp_PartialPct);
            double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
            double remLot   = NormLot(vol - closeLot);
            if(closeLot >= minLot && remLot >= minLot) {
               if(m_trade.PositionClosePartial(ticket, closeLot)) {
                  m_rec[idx].partialDone = true;
                  Print(">>> PARTIAL CLOSE V6.0: #", ticket, " ", NormalizeDouble(closeLot,2), "lots");
                  // Mover SL a breakeven después del partial
                  double beSL = (pt == POSITION_TYPE_BUY)
                     ? NormPrice(op + 2*_Point)
                     : NormPrice(op - 2*_Point);
                  double curSL2 = PositionGetDouble(POSITION_SL);
                  bool updateBE = false;
                  if(pt == POSITION_TYPE_BUY  && beSL > curSL2) updateBE = true;
                  if(pt == POSITION_TYPE_SELL && (curSL2 <= 0 || beSL < curSL2)) updateBE = true;
                  if(updateBE) m_trade.PositionModify(ticket, beSL, curTP);
               }
            }
         }
      }

      // Breakeven automático
      if(!m_rec[idx].beActivated) {
         bool activateBE = false;
         if(pt == POSITION_TYPE_BUY  && t.bid >= NormPrice(op + atr * Inp_BE_ATR)) activateBE = true;
         if(pt == POSITION_TYPE_SELL && t.ask <= NormPrice(op - atr * Inp_BE_ATR)) activateBE = true;
         if(activateBE) {
            double beSL = (pt == POSITION_TYPE_BUY)
               ? NormPrice(op + 3*_Point)
               : NormPrice(op - 3*_Point);
            bool update = false;
            if(pt == POSITION_TYPE_BUY  && beSL > curSL) update = true;
            if(pt == POSITION_TYPE_SELL && (curSL <= 0 || beSL < curSL)) update = true;
            if(update) {
               if(m_trade.PositionModify(ticket, beSL, curTP)) {
                  m_rec[idx].beActivated = true;
                  Print(">>> BE V6.0: #", ticket, " SL→", NormalizeDouble(beSL,dg));
               }
            }
         }
      }

      // Trailing stop
      if(!Inp_UseTrailSL) continue;
      bool activateTrail = false;
      if(pt == POSITION_TYPE_BUY  && t.bid >= NormPrice(op + atr * Inp_TrailStart_ATR)) activateTrail = true;
      if(pt == POSITION_TYPE_SELL && t.ask <= NormPrice(op - atr * Inp_TrailStart_ATR)) activateTrail = true;
      if(!activateTrail) continue;

      double trailDist = atr * Inp_TrailDist_ATR;
      if(trailDist < minStop) trailDist = minStop;
      double newSL = 0;
      bool shouldUpdate = false;

      if(pt == POSITION_TYPE_BUY) {
         newSL = NormPrice(t.bid - trailDist);
         if(newSL > curSL + _Point) { shouldUpdate = true; }
      } else {
         newSL = NormPrice(t.ask + trailDist);
         if(curSL <= 0 || newSL < curSL - _Point) { shouldUpdate = true; }
      }

      if(shouldUpdate) {
         if(m_trade.PositionModify(ticket, newSL, curTP)) {
            if(!m_rec[idx].trailActivated) {
               m_rec[idx].trailActivated = true;
               Print(">>> TRAIL ON V6.0: #", ticket);
            }
         }
      }
   }
}

//=================================================================
//  BASKET TP — CIERRA TODO CUANDO EL CICLO ES RENTABLE
//=================================================================
void RunBasketTP() {
   if(!Inp_UseBasketTP) return;
   if(TimeCurrent() - m_lastBasketCheck < Inp_BasketCheckSec) return;
   m_lastBasketCheck = TimeCurrent();
   if(m_port.totalPos < 2) return;

   double avgWin = (m_cycleWinsCount > 0) ? m_cycleWinsSum / m_cycleWinsCount : Inp_BasketTPFactor;
   double target = MathMax(Inp_BasketTPFactor, avgWin * Inp_BasketTPRatio);

   if(m_port.totalProfit >= target) {
      Print(">>> BASKET TP V6.0: PnL=$", NormalizeDouble(m_port.totalProfit,2),
            " Target=$", NormalizeDouble(target,2), " → Cerrando todo");
      m_isProcessing = true;
      // Primero ganadoras, luego perdedoras
      for(int pass = 0; pass < 2; pass++) {
         for(int i = PositionsTotal()-1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            double pf = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            if(pass == 0 && pf < 0) continue;
            if(pass == 1 && pf >= 0) continue;
            ClosePos(t, "BasketTP");
         }
      }
      m_isProcessing = false;
      StartCycleReset("BasketTP");
   }
}

//=================================================================
//  CYCLE MAX LOSS
//=================================================================
void CheckCycleMaxLoss() {
   if(!Inp_UseCycleMaxLoss || m_port.totalPos == 0) return;
   if(m_port.totalProfit >= 0) return;
   double avgWin = (m_cycleWinsCount > 0) ? m_cycleWinsSum / m_cycleWinsCount : MathAbs(Inp_CycleMaxLossUSD);
   double limit  = MathMax(-(avgWin * Inp_CycleMaxLossRatio), Inp_CycleMaxLossUSD);
   if(m_port.totalProfit <= limit) {
      Print(">>> CYCLE MAX LOSS V6.0: PnL=$", NormalizeDouble(m_port.totalProfit,2),
            " Límite=$", NormalizeDouble(limit,2));
      m_isProcessing = true;
      for(int i = PositionsTotal()-1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
         ClosePos(t, "CycleMaxLoss");
      }
      m_isProcessing = false;
      StartCycleReset("CycleMaxLoss");
   }
}

void StartCycleReset(string reason) {
   m_cycleResetTime = TimeCurrent();
   m_cycleInPause   = true;
   m_lastCTBuyPrice = m_lastCTSellPrice = 0;
   Print(">>> CYCLE RESET V6.0 [", reason, "] Pausa ", Inp_CyclePauseSec, "s");
}

void CheckCyclePause() {
   if(!m_cycleInPause) return;
   if(TimeCurrent() - m_cycleResetTime >= Inp_CyclePauseSec) {
      m_cycleInPause = false;
      Print(">>> NUEVO CICLO V6.0");
   }
}

//=================================================================
//  HARVEST — UMBRAL CORREGIDO
//=================================================================
double GetHarvestMin() {
   double atr = m_mkt.atr;
   double tv = GetTickVal(), ts = GetTickSize();
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(atr > 0 && tv > 0 && ts > 0 && minL > 0) {
      double atrUSD = (atr / ts) * tv * minL * Inp_HarvestATRMult;
      return MathMax(Inp_HarvestMinUSD, NormalizeDouble(atrUSD, 2));
   }
   return Inp_HarvestMinUSD;
}

void RunHarvest() {
   if(!Inp_HarvestContinuous || m_isProcessing) return;
   if(TimeCurrent() - m_lastHarvestTime < Inp_HarvestIntervalSec) return;
   m_lastHarvestTime = TimeCurrent();

   double hMin = GetHarvestMin();
   int harvested = 0; double totalH = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      int idx = FindRec(t);
      double kpf = (idx >= 0 && m_rec[idx].kInit) ? m_rec[idx].kX : pf;

      // V6.0: Harvest ratio guard — no cosechar si pérdida abierta > 2x ganancia a cosechar
      if(m_port.negativeSum > pf * 2.0 && pf > 0) continue;

      bool doH = false;
      if(pf >= hMin * 3.0) doH = true; // ganancia alta: cosechar siempre
      if(kpf >= hMin && idx >= 0 && m_rec[idx].kInit && m_rec[idx].kK <= 0.30) doH = true;

      if(doH && ClosePos(t, "Harvest")) { harvested++; totalH += pf; }
   }
   if(harvested > 0)
      Print(">>> HARVEST V6.0: ", harvested, " pos | $", NormalizeDouble(totalH,2),
            " | Min=$", NormalizeDouble(hMin,2));
}

//=================================================================
//  CLUSTER OPTIMIZER
//=================================================================
void RunCluster() {
   if(m_isProcessing) return;
   if(TimeCurrent() - m_lastClusterTime < Inp_ClusterIntervalSec) return;
   m_lastClusterTime = TimeCurrent();
   if(m_port.totalPos < 2 || m_port.negativeSum == 0) return;

   // Construir lista ordenada de posiciones
   ulong posTickets[60]; double posProfits[60]; int posCount = 0;
   ulong negTickets[60]; double negProfits[60]; int negCount = 0;

   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      double pf = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pf >= 0 && posCount < 60) { posTickets[posCount]=t; posProfits[posCount]=pf; posCount++; }
      else if(pf < 0 && negCount < 60) { negTickets[negCount]=t; negProfits[negCount]=pf; negCount++; }
   }
   if(posCount == 0 || negCount == 0) return;

   // Encontrar la peor pérdida
   double worstLoss = negProfits[0];
   for(int k = 1; k < negCount; k++) if(negProfits[k] < worstLoss) worstLoss = negProfits[k];
   double needed = MathAbs(worstLoss) * Inp_ClusterCoverFactor + Inp_ClusterMinExcedent;

   // Acumular ganadoras
   double acc = 0;
   bool sel[60]; ArrayFill(sel, 0, 60, false);
   for(int k = 0; k < posCount; k++) {
      if(posProfits[k] >= 0.10 && acc < needed) { sel[k] = true; acc += posProfits[k]; }
   }
   if(acc < needed) return;

   m_isProcessing = true;
   Print(">>> CLUSTER V6.0: cubrir $", NormalizeDouble(worstLoss,2), " con $", NormalizeDouble(acc,2));
   for(int k = 0; k < posCount; k++)
      if(sel[k] && PositionSelectByTicket(posTickets[k]))
         ClosePos(posTickets[k], "ClusterPos");
   // Cerrar la peor pérdida
   ulong worstT = negTickets[0];
   for(int k = 1; k < negCount; k++) if(negProfits[k] < negProfits[0]) worstT = negTickets[k];
   if(PositionSelectByTicket(worstT)) ClosePos(worstT, "ClusterNeg");
   m_isProcessing = false;
}

//=================================================================
//  EQUITY GUARD
//=================================================================
bool CheckEquityGuard() {
   if(!Inp_UseEquityGuard) return false;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);

   if(m_port.totalProfit <= Inp_EmergencyLossUSD && !m_emergencyMode) {
      Print(">>> EMERGENCIA V6.0: P&L=$", NormalizeDouble(m_port.totalProfit,2));
      m_emergencyMode = true; m_isPaused = true;
      for(int i = PositionsTotal()-1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==Inp_Magic)
            ClosePos(t, "Emergency");
      }
      return true;
   }
   if(m_port.currentDD >= Inp_MaxDrawdownPct) {
      m_isPaused = true;
      static datetime lastDD = 0;
      if(TimeCurrent() - lastDD > 30) { Print(">>> MAX DD: ", NormalizeDouble(m_port.currentDD*100,1), "%"); lastDD=TimeCurrent(); }
   } else if(m_isPaused && !m_emergencyMode && !m_dailyLimitHit &&
             m_port.currentDD < Inp_MaxDrawdownPct * 0.5) {
      m_isPaused = false;
      Print(">>> REANUDANDO: DD=", NormalizeDouble(m_port.currentDD*100,1), "%");
   }
   return false;
}

//=================================================================
//  COUNTER-TRADE ENGINE — HEDGE VERDADERO V6.0
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType, double &ctLot, int &ctLevel) {
   if(m_port.totalPos == 0) return false;
   if(m_port.totalPos >= Inp_MaxPositionsTotal) return false;
   if(!m_inSession) return false;
   if(m_port.totalProfit >= 0 && m_port.negativeSum == 0) return false;

   double atr = m_mkt.atr; if(atr <= 0) return false;
   MqlTick t; if(!GetTick(t)) return false;

   int buyCount = m_port.buyCount, sellCount = m_port.sellCount;
   bool buyLosing  = (m_port.buyProfit  < -0.05 && buyCount  > 0);
   bool sellLosing = (m_port.sellProfit < -0.05 && sellCount > 0);

   // V6.0: HEDGE VERDADERO — siempre opuesto al perdedor
   bool openBuy = false, openSell = false;

   if(buyLosing && !sellLosing) {
      // BUYs perdiendo → abrir SELL (hedge)
      if(sellCount >= Inp_CTMaxSameDir) return false; // Límite de CTs por dirección
      openSell = true;
   } else if(sellLosing && !buyLosing) {
      // SELLs perdiendo → abrir BUY (hedge)
      if(buyCount >= Inp_CTMaxSameDir) return false;
      openBuy = true;
   } else if(buyLosing && sellLosing) {
      // Ambos perdiendo → seguir tendencia HTF
      if(m_mkt.htfTrend == 1 && buyCount < Inp_CTMaxSameDir) openBuy = true;
      else if(m_mkt.htfTrend == -1 && sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(m_port.buyProfit < m_port.sellProfit && sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(m_port.sellProfit <= m_port.buyProfit && buyCount < Inp_CTMaxSameDir) openBuy = true;
      else return false;
   } else return false;

   ENUM_ORDER_TYPE testType = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!ADXAllowsEntry(testType)) return false;

   // Distancia mínima entre CTs del mismo tipo
   double ctDist = (Inp_CTMode == CT_ATR_DISTANCE) ? atr * Inp_CTDistanceATR : Inp_CTFixedPoints * _Point;
   if(ctDist > 0) {
      if(openBuy  && m_lastCTBuyPrice  > 0 && MathAbs(t.ask - m_lastCTBuyPrice)  < ctDist) return false;
      if(openSell && m_lastCTSellPrice > 0 && MathAbs(t.bid - m_lastCTSellPrice) < ctDist) return false;
   }

   ctLevel = openBuy ? buyCount : sellCount;
   ctLot   = CalcLot(ctLevel);
   ctType  = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine() {
   if(m_isProcessing || m_isPaused || m_emergencyMode || m_cycleInPause) return;
   if(!m_inSession) return;
   if(TimeCurrent() - m_lastCTTime < Inp_CTIntervalSec) return;
   m_lastCTTime = TimeCurrent();

   MqlTick ts; if(!GetTick(ts)) return;
   if((ts.ask - ts.bid) / _Point > Inp_CTMaxSpreadPoints) return;

   // Primera posición (Primary)
   if(m_port.totalPos == 0) {
      if(TimeCurrent() - m_lastPrimaryTime < Inp_PrimaryCooldownSec) return;

      ENUM_ORDER_TYPE initType;
      if(m_mkt.isBullish) initType = ORDER_TYPE_BUY;
      else if(m_mkt.isBearish) initType = ORDER_TYPE_SELL;
      else if(m_mkt.emaFast > m_mkt.emaSlow) initType = ORDER_TYPE_BUY;
      else initType = ORDER_TYPE_SELL;

      // Si la última primaria perdió, alternar dirección
      if(m_lastPrimaryLost && m_lastPrimaryDir != 0) {
         ENUM_ORDER_TYPE alt = (m_lastPrimaryDir == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         if(initType != alt) {
            Print(">>> V6 ALT PRIMARY: última perdió en dir=", m_lastPrimaryDir, " → alternando");
            initType = alt;
         }
         m_lastPrimaryLost = false;
      }

      if(!ADXAllowsEntry(initType)) return;

      double lot = CalcLot(0);
      m_isProcessing = true;
      ulong ticket = OpenOrder(initType, lot, "Primary_Entry");
      if(ticket > 0) {
         int idx = FreeRec();
         if(idx >= 0) {
            int pt = (initType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
            double op = (initType == ORDER_TYPE_BUY) ? ts.ask : ts.bid;
            InitRec(idx, ticket, pt, op, lot, "Primary_Entry", true, false);
         }
         m_lastPrimaryDir  = (initType == ORDER_TYPE_BUY) ? 1 : -1;
         m_lastPrimaryTime = TimeCurrent();
         if(initType == ORDER_TYPE_BUY) m_lastCTBuyPrice  = ts.ask;
         else                           m_lastCTSellPrice = ts.bid;
      }
      m_isProcessing = false;
      return;
   }

   // Counter-trades
   ENUM_ORDER_TYPE ctType; double ctLot; int ctLevel;
   if(!ShouldOpenCT(ctType, ctLot, ctLevel)) return;
   if(!MarginOK(ctLot, ctType)) return;

   string ctComm = "CT_" + (ctType==ORDER_TYPE_BUY?"B":"S") + "_L" + IntegerToString(ctLevel+1);
   m_isProcessing = true;
   ulong ticket = OpenOrder(ctType, ctLot, ctComm);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int pt = (ctType==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (ctType==ORDER_TYPE_BUY) ? ts.ask : ts.bid;
         InitRec(idx, ticket, pt, op, ctLot, ctComm, false, true);
      }
      if(ctType==ORDER_TYPE_BUY) m_lastCTBuyPrice  = ts.ask;
      else                       m_lastCTSellPrice = ts.bid;
   }
}

//=================================================================
//  DASHBOARD
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

void Btn(string n, string txt, int x, int y, int w, int h, color bg) {
   if(ObjectFind(0,n)<0) {
      ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
      ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,n,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,n,OBJPROP_COLOR,clrWhite);
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
}

void DeleteDash() {
   string ns[] = {"D6_T","D6_S","D6_SES","D6_BAL","D6_PNL","D6_POS",
                  "D6_RR","D6_CYCLE","D6_MKT","D6_PERF","D6_DD",
                  "D6_BTN1","D6_BTN2"};
   for(int i=0;i<ArraySize(ns);i++) ObjectDelete(0,ns[i]);
}

void UpdateDash() {
   if(!Inp_ShowDashboard) return;
   if(TimeCurrent() - m_lastDashTime < 1) return;
   m_lastDashTime = TimeCurrent();

   int x = Inp_DashX, y = Inp_DashY, lh = 15;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);

   color cG = clrLimeGreen, cR = clrTomato, cN = clrSilver, cC = clrCyan, cY = clrGold;
   color pnlC = (m_port.totalProfit >= 0) ? cG : cR;
   color sessC = m_inSession ? cG : cN;
   color ddC  = (m_port.currentDD > 0.10) ? cR : (m_port.currentDD > 0.05) ? clrOrange : cG;

   double atr = m_mkt.atr;
   double rrActual = (atr > 0) ? (Inp_TP_ATR / Inp_SL_ATR) : 0;

   string stStr = m_emergencyMode?"EMERGENCIA": m_dailyLimitHit?"LIM.DIARIO":
                  m_cycleInPause?"PAUSA CICLO": m_isPaused?"PAUSADO":"ACTIVO";
   color stC = m_emergencyMode?cR: m_dailyLimitHit?clrOrange:
               m_cycleInPause?clrOrange: m_isPaused?cY:cG;

   Lbl("D6_T",  "══ "+VERSION_STR+" | XAUUSD ══", x, y, cY, 10); y+=lh+3;
   Lbl("D6_S",  "Estado: "+stStr+" | Ticks:"+IntegerToString((int)m_tickCount)+
                " | Streak:-"+IntegerToString(m_consecutiveLosses)+
                " | LotX:"+DoubleToString(m_lotMultiplier,2), x, y, stC); y+=lh;
   Lbl("D6_SES","Sesión: "+(m_inSession?"ACTIVA (Lon/NY)":"FUERA")+
                " | ADX:"+DoubleToString(m_mkt.adx,1)+
                " | HTF:"+(m_mkt.htfTrend==1?"BULL":m_mkt.htfTrend==-1?"BEAR":"NEUT"),
                x, y, sessC); y+=lh;
   Lbl("D6_BAL","Bal:$"+DoubleToString(bal,2)+
                " Eq:$"+DoubleToString(eq,2)+
                " Peak:$"+DoubleToString(m_bestEquity,2), x, y, cC); y+=lh;
   Lbl("D6_RR", "R:R FORZADO: 1:"+DoubleToString(rrActual,2)+
                " | SL:"+DoubleToString(Inp_SL_ATR,1)+"×ATR"+
                " | TP:"+DoubleToString(Inp_TP_ATR,1)+"×ATR"+
                " | Harvest>$"+DoubleToString(GetHarvestMin(),2),
                x, y, cY); y+=lh;
   Lbl("D6_PNL","P&L Abierto:$"+DoubleToString(m_port.totalProfit,2)+
                " | Realizado:$"+DoubleToString(m_totalPnL,2), x, y, pnlC); y+=lh;
   Lbl("D6_POS","Pos:"+IntegerToString(m_port.totalPos)+
                " B:"+IntegerToString(m_port.buyCount)+" $"+DoubleToString(m_port.buyProfit,2)+
                " | S:"+IntegerToString(m_port.sellCount)+" $"+DoubleToString(m_port.sellProfit,2)+
                " | CT:"+IntegerToString(m_port.ctCount), x, y, cC); y+=lh;
   Lbl("D6_CYCLE","Ciclo: Win=$"+DoubleToString(m_cycleWinsSum,2)+
                  "("+IntegerToString(m_cycleWinsCount)+")"+
                  " Lss=$"+DoubleToString(m_cycleLossSum,2)+
                  " | BasketTP@$"+DoubleToString(
                     MathMax(Inp_BasketTPFactor,
                        (m_cycleWinsCount>0?m_cycleWinsSum/m_cycleWinsCount:Inp_BasketTPFactor)*Inp_BasketTPRatio),2),
                x, y, cN); y+=lh;
   Lbl("D6_MKT","ATR:"+DoubleToString(m_mkt.atr,_Digits)+
                " RSI:"+DoubleToString(m_mkt.rsi,0)+
                " Sprd:"+IntegerToString((int)m_mkt.spread)+
                " "+(m_mkt.isBullish?"ALCISTA":m_mkt.isBearish?"BAJISTA":"LATERAL"),
                x, y, m_mkt.isBullish?cG:m_mkt.isBearish?cR:cN); y+=lh;
   Lbl("D6_PERF","Open:"+IntegerToString(m_tradesOpened)+
                 " Cls:"+IntegerToString(m_tradesClosed)+
                 " Best:$"+DoubleToString(m_bestClosed,2)+
                 " Worst:$"+DoubleToString(m_worstClosed,2), x, y, cC); y+=lh;
   Lbl("D6_DD", "DD:"+DoubleToString(m_port.currentDD*100,1)+"%"+
                " Emg<$"+DoubleToString(Inp_EmergencyLossUSD,1)+
                " MaxDD:"+DoubleToString(Inp_MaxDrawdownPct*100,0)+"%",
                x, y, ddC); y+=lh+4;
   Btn("D6_BTN1", m_isPaused?"REANUDAR":"PAUSAR", x, y, 80, 20,
       m_isPaused?clrGoldenrod:clrDarkGreen);
   Btn("D6_BTN2", "CERRAR TODO", x+88, y, 95, 20, clrDarkRed);
   ChartRedraw(0);
}

//=================================================================
//  OnInit
//=================================================================
int OnInit() {
   Print("══════════════════════════════════════════════════════");
   Print("  ", VERSION_STR, " - INICIANDO...");
   Print("  CORRECCIÓN R:R: SL=", Inp_SL_ATR, "×ATR | TP=", Inp_TP_ATR, "×ATR | R:R=1:",
         NormalizeDouble(Inp_TP_ATR/Inp_SL_ATR, 2));
   Print("══════════════════════════════════════════════════════");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);

   h_ATR    = iATR(_Symbol, PERIOD_M1, Inp_ATRPeriod);
   h_EMAFast= iMA(_Symbol, PERIOD_M1, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMASlow= iMA(_Symbol, PERIOD_M1, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI    = iRSI(_Symbol, PERIOD_M1, Inp_RSIPeriod, PRICE_CLOSE);
   h_MACD   = iMACD(_Symbol, PERIOD_M1, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);

   if(h_ATR==INVALID_HANDLE||h_EMAFast==INVALID_HANDLE||h_EMASlow==INVALID_HANDLE||
      h_RSI==INVALID_HANDLE||h_MACD==INVALID_HANDLE) {
      Print(">>> ERROR: Handles fallidos"); return INIT_FAILED;
   }

   h_ADX         = iADX(_Symbol, PERIOD_M1, Inp_ADXPeriod);
   h_HTFEMAFast  = iMA(_Symbol, Inp_HTFTF, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_HTFEMASlow  = iMA(_Symbol, Inp_HTFTF, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);

   for(int i=0;i<MAX_RECORDS;i++) ZeroMemory(m_rec[i]);

   m_initialBalance  = AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity      = AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance    = m_initialBalance;
   m_lastDailyReset  = TimeCurrent();

   SyncPositions();
   if(Inp_ShowDashboard) { DeleteDash(); UpdateDash(); }

   Print("Balance: $", m_initialBalance, " | Lote base: ", Inp_LotBase);
   Print("SL=", Inp_SL_ATR, "xATR | TP=", Inp_TP_ATR, "xATR | R:R=1:",
         NormalizeDouble(Inp_TP_ATR/Inp_SL_ATR,2));
   Print("Sesiones: SOLO Londres (",Inp_LondonOpen,"-",Inp_LondonClose,"h GMT) y NY (",Inp_NYOpen,"-",Inp_NYClose,"h GMT)");
   Print("MaxPos=", Inp_MaxPositionsTotal, " | CTMaxDir=", Inp_CTMaxSameDir);
   Print("HarvestMin=$", Inp_HarvestMinUSD, " | BasketTPFactor=$", Inp_BasketTPFactor);
   Print(">>> V6.0 INICIALIZADO - R:R CORREGIDO");
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason) {
   Print(">>> DEINIT V6.0 | PnL=$", NormalizeDouble(m_totalPnL,2),
         " | Open:", m_tradesOpened, " Cls:", m_tradesClosed);
   IndicatorRelease(h_ATR); IndicatorRelease(h_EMAFast); IndicatorRelease(h_EMASlow);
   IndicatorRelease(h_RSI); IndicatorRelease(h_MACD);
   if(h_ADX!=INVALID_HANDLE) IndicatorRelease(h_ADX);
   if(h_HTFEMAFast!=INVALID_HANDLE) IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow!=INVALID_HANDLE) IndicatorRelease(h_HTFEMASlow);
   if(Inp_ShowDashboard) DeleteDash();
}

//=================================================================
//  OnTick — NÚCLEO PRINCIPAL
//=================================================================
void OnTick() {
   m_tickCount++;

   // 1. Datos del mercado
   UpdateMarket();
   UpdateKalman();
   UpdatePortfolio();

   // 2. Equity Guard (máxima prioridad)
   if(CheckEquityGuard()) return;

   // 3. Sesión y límite diario
   m_inSession = IsInSession();
   ResetDailyIfNeeded();
   if(DailyLimitReached()) return;

   // 4. Pausa de ciclo
   CheckCyclePause();
   if(m_cycleInPause) { if(Inp_ShowDashboard) UpdateDash(); return; }

   // 5. Modo emergencia con cooldown
   if(m_emergencyMode) {
      static datetime emgTime = 0;
      if(m_port.totalPos == 0 && emgTime == 0) emgTime = TimeCurrent();
      if(emgTime > 0 && TimeCurrent() - emgTime >= Inp_EmergencyCooldown) {
         m_emergencyMode = false; emgTime = 0;
         Print(">>> EMG RESET: cooldown cumplido");
      }
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // 6. Limpieza y sincronización
   if(TimeCurrent() - m_lastCleanupTime > 5) {
      CleanupRecs(); SyncPositions(); m_lastCleanupTime = TimeCurrent();
   }

   // 7. Gestión individual (trailing, BE, partial)
   ManagePositions();

   // 8. Basket TP
   RunBasketTP();

   // 9. Cycle Max Loss
   CheckCycleMaxLoss();

   // 10. Harvest continuo
   RunHarvest();

   // 11. Cluster Optimizer
   RunCluster();

   // 12. Counter-Trade Engine
   if(!m_isPaused) RunCTEngine();

   // 13. Dashboard
   if(Inp_ShowDashboard) UpdateDash();
}

//=================================================================
//  OnChartEvent
//=================================================================
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp) {
   if(id == CHARTEVENT_OBJECT_CLICK) {
      if(sp == "D6_BTN1") {
         m_isPaused = !m_isPaused;
         if(!m_isPaused) {
            m_emergencyMode = false; m_dailyLimitHit = false;
            Print(">>> EA REANUDADO");
         } else Print(">>> EA PAUSADO");
      }
      if(sp == "D6_BTN2") {
         int closed = 0;
         for(int i = PositionsTotal()-1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
            if(ClosePos(t, "Manual")) closed++;
         }
         m_lastCTBuyPrice = m_lastCTSellPrice = 0;
         m_consecutiveLosses = 0; m_lotMultiplier = 1.0;
         m_cycleInPause = false; m_cycleResetTime = 0;
         m_lastPrimaryDir = 0; m_lastPrimaryLost = false;
         Print(">>> CIERRE MANUAL: ", closed, " posiciones");
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+