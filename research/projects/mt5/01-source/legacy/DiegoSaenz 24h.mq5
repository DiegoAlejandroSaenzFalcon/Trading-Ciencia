//+------------------------------------------------------------------+
//|   DIEGO SAENZ 24H - V7.3  (LBC + RECOVERY MATEMATICO)          |
//|                                                                  |
//| CAMBIOS V7.3 vs V7.2:                                           |
//|                                                                  |
//| [1] FIX SIGNOS DE INTERROGACION EN JOURNAL Y DASHBOARD          |
//|     Eliminados todos los caracteres Unicode/emoji (>ASCII 127)  |
//|     que MT5 no puede mostrar en algunas versiones/SO.           |
//|                                                                  |
//| [2] MODO LBC - LOW BALANCE CONTINGENCY (NUEVO)                  |
//|     Problema: Con $40 de balance, CalcRecoveryLot() calcula      |
//|     un lote grande (ej: 0.38) que el margen no puede soportar,  |
//|     y el EA imprime "Sin margen suficiente" y no hace nada,      |
//|     dejando la operacion perdedora sola.                         |
//|                                                                  |
//|     Solucion matematica LBC:                                     |
//|     En lugar de un lote grande, abre multiples pares BUY+SELL   |
//|     de 0.01 lot (lote minimo) en niveles espaciados por ATR.    |
//|     - Cualquier movimiento del mercado cosecha una de las dos    |
//|       direcciones (la ganadora se cierra, la perdedora espera)   |
//|     - Las ganancias cosechadas se acumulan hacia el objetivo     |
//|     - El riesgo neto es minimo: BUY y SELL se compensan         |
//|     - Con $40 se pueden mantener 6-10 posiciones de 0.01        |
//|                                                                  |
//|     Matematica: E[ganancia por par] = ATR * 0.15 * ProfitPerLot |
//|     Con ATR=3, 4 pares activos: recuperacion en horas           |
//|                                                                  |
//|     Activacion: SOLO cuando Recovery imprime "Sin margen"        |
//|     La logica original NO se toca en ningun otro caso           |
//|                                                                  |
//| [3] DASHBOARD MEJORADO                                           |
//|     - Fondo semitransparente para legibilidad                   |
//|     - Lenguaje accesible (sin perder datos tecnicos)            |
//|     - Seccion dedicada al estado LBC                            |
//|     - VWAP del bloque (precio promedio ponderado)              |
//|     - Tasa de exito y expectativa matematica del EA            |
//|                                                                  |
//| [4] MEJORAS INSTITUCIONALES Y MATEMATICAS                       |
//|     - VWAP del bloque (precio promedio ponderado por volumen)   |
//|     - Tasa de victorias (win rate) en tiempo real              |
//|     - Expectativa matematica: (WR x Avg_Win) - (LR x Avg_Loss) |
//|     - Espaciado LBC ajustado por sesion (London/NY mas amplio)  |
//|     - Filtro Half-Kelly para tamano de posicion                 |
//|                                                                  |
//| REGLAS INAMOVIBLES (igual que V7.2):                            |
//|   - SL = 0 en todas las ordenes (broker nunca cierra auto)     |
//|   - TP individual = 0                                           |
//|   - UNICO cierre: bloque neto > BlockTPTarget                  |
//|   - DailyLimit / EquityGuard = solo pausa, NUNCA cierra        |
//+------------------------------------------------------------------+
#property copyright "DiegoSaenz Recovery EA V7.3"
#property version   "7.30"
#property strict
#property description "XAUUSD 24/7 | Recovery + LBC Micro-Grid | Balance minimo $40"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   80
#define VERSION_STR   "DS_24H_V7.3"

enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

//=================================================================
//  PARAMETROS
//=================================================================
input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic               = 7001;
input int    Inp_MaxPositionsTotal   = 8;
input double Inp_LotBase             = 0.01;
input double Inp_LotMaximum          = 0.10;
input double Inp_RiskPerTradePct     = 0.01;
input bool   Inp_UseDynamicLot       = true;
input double Inp_CTMinBalanceUSD     = 40.0;
input double Inp_MinFreeMarginPct    = 0.20;

input group "=== CIERRE DEL BLOQUE  - UNICO MODO DE CIERRE ==="
input double Inp_BlockTPTarget       = 0.30;
// Referencias internas (no son SL/TP reales en el broker)
input double Inp_TP_ATR              = 2.5;
input double Inp_SL_ATR              = 1.2;
input double Inp_OffSessionTP_ATR    = 2.2;
input double Inp_OffSessionSL_ATR    = 1.0;

input group "=== RECOVERY ENGINE V7.3 ==="
input double Inp_RecoveryTriggerUSD  = -0.80;
input double Inp_RecoveryMinDistATR  = 1.5;
input double Inp_RecoveryMoveATR     = 0.5;
input double Inp_RecoveryMinLotMult  = 2.0;
input int    Inp_RecoveryMaxOrders   = 3;
input int    Inp_RecoveryIntervalSec = 15;

input group "=== LBC: CONTINGENCIA BALANCE BAJO (NUEVO V7.3) ==="
// Maximo de pares micro-grid (cada par = BUY 0.01 + SELL 0.01)
input int    Inp_LBCMaxPairs         = 4;
// Espaciado del grid como fraccion del ATR (recomendado: 0.25 a 0.40)
input double Inp_LBCGridATR          = 0.30;
// Objetivo de cosecha por posicion LBC como fraccion del ATR en USD
input double Inp_LBCHarvestATR       = 0.15;
// Segundos minimos entre ordenes LBC
input int    Inp_LBCIntervalSec      = 8;
// Fraccion del margen libre disponible para usar en LBC (0.40 a 0.65)
input double Inp_LBCMarginPct        = 0.55;

input group "=== COUNTER-TRADE ENGINE ==="
input ENUM_CT_MODE Inp_CTMode        = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR       = 1.2;
input int    Inp_CTFixedPoints       = 100;
input int    Inp_CTIntervalSec       = 10;
input int    Inp_CTMaxSameDir        = 3;
input int    Inp_PrimaryCooldownSec  = 90;
input int    Inp_PrimaryCooldownOff  = 150;
input double Inp_CTMaxSpreadPoints   = 30;
input double Inp_CTMaxSpreadOff      = 20;

input group "=== SESIONES ==="
input int    Inp_GMTOffset           = 0;
input int    Inp_LondonOpen          = 7;
input int    Inp_LondonClose         = 17;
input int    Inp_NYOpen              = 13;
input int    Inp_NYClose             = 22;
input double Inp_OffSessionLotFactor = 0.50;

input group "=== BASKET TP ==="
input bool   Inp_UseBasketTP         = true;
input double Inp_BasketTPFactor      = 0.60;
input double Inp_BasketTPRatio       = 1.5;
input int    Inp_BasketCheckSec      = 3;

input group "=== HARVEST ==="
input double Inp_HarvestMinUSD       = 0.80;
input double Inp_HarvestATRMult      = 0.20;
input bool   Inp_HarvestContinuous   = true;
input int    Inp_HarvestIntervalSec  = 3;

input group "=== CYCLE CONTROL ==="
input bool   Inp_UseCycleMaxLoss     = true;
input double Inp_CycleMaxLossUSD     = -3.00;
input int    Inp_CyclePauseSec       = 30;

input group "=== ADX + HTF ==="
input bool   Inp_UseADX              = true;
input int    Inp_ADXPeriod           = 14;
input double Inp_ADXTrendLevel       = 30.0;
input double Inp_ADXTrendLevelOff    = 22.0;
input bool   Inp_UseHTF              = true;
input ENUM_TIMEFRAMES Inp_HTFTF      = PERIOD_M5;

input group "=== PROTECCION DIARIA (solo pausa, no cierra) ==="
input bool   Inp_UseDailyLimit       = true;
input double Inp_DailyLossUSD        = -5.0;
input double Inp_DailyLossPct        = 0.025;
input int    Inp_LossStreakMax        = 4;
input double Inp_LossStreakReduce     = 0.70;

input group "=== EQUITY GUARD (solo pausa, no cierra) ==="
input bool   Inp_UseEquityGuard      = true;
input double Inp_EmergencyLossUSD    = -8.0;
input double Inp_MaxDrawdownPct      = 0.20;
input int    Inp_EmergencyCooldown   = 180;

input group "=== INDICADORES ==="
input int    Inp_ATRPeriod           = 14;
input int    Inp_EMAFast             = 21;
input int    Inp_EMASlow             = 55;
input int    Inp_RSIPeriod           = 7;
input int    Inp_MACDFast            = 12;
input int    Inp_MACDSlow            = 26;
input int    Inp_MACDSig             = 9;

input group "=== CONTROL VISUAL ==="
input int    Inp_MaxSpread           = 35;
input bool   Inp_ShowDashboard       = true;
input int    Inp_DashX               = 12;
input int    Inp_DashY               = 28;

//=================================================================
//  ESTRUCTURAS
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
   bool     isRecovery;
   bool     isLBC;
   double   peakProfit;
   double   kX, kP, kK;
   bool     kInit;
};

struct Portfolio {
   int    totalPos;
   int    buyCount, sellCount;
   double buyProfit, sellProfit;
   double totalProfit;
   double positiveSum, negativeSum;
   ulong  worstTicket;
   double worstProfit;
   int    ctCount;
   int    recoveryCount;
   int    lbcCount;
   double currentDD;
   double blockVWAP;    // Precio promedio ponderado del bloque
   int    blockDir;     // Direccion neta del bloque: +1 long, -1 short, 0 neutral
};

struct MarketSnap {
   double bid, ask, atr, emaFast, emaSlow, rsi, macdMain, macdSig, adx, spread;
   int    htfTrend;
   bool   isBullish, isBearish;
};

// Estado del modo LBC
struct LBCState {
   bool     active;
   int      buyCount;
   int      sellCount;
   double   lastBuyPrice;
   double   lastSellPrice;
   datetime lastOrderTime;
   double   harvestedTotal;
   int      harvestCount;
   int      maxOrdersCalc;
   datetime activatedTime;
};

//=================================================================
//  HANDLES Y ESTADO GLOBAL
//=================================================================
int h_ATR, h_EMAFast, h_EMASlow, h_RSI, h_MACD;
int h_ADX        = INVALID_HANDLE;
int h_HTFEMAFast = INVALID_HANDLE;
int h_HTFEMASlow = INVALID_HANDLE;

CTrade    m_trade;
PosRecord m_rec[MAX_RECORDS];
Portfolio m_port;
MarketSnap m_mkt;
LBCState  m_lbc;

double   m_initialBalance    = 0;
double   m_bestEquity        = 0;
bool     m_isPaused          = false;
bool     m_emergencyMode     = false;
bool     m_dailyLimitHit     = false;
bool     m_inSession         = false;
bool     m_recoveryActive    = false;
int      m_recoveryOrders    = 0;

double   m_cycleWinsSum      = 0;
int      m_cycleWinsCount    = 0;
double   m_cycleLossSum      = 0;
bool     m_cycleInPause      = false;
datetime m_cycleResetTime    = 0;

int      m_consecutiveLosses = 0;
double   m_lotMultiplier     = 1.0;
double   m_dailyBalance      = 0;
datetime m_lastDailyReset    = 0;

int      m_lastPrimaryDir    = 0;
datetime m_lastPrimaryTime   = 0;
bool     m_lastPrimaryLost   = false;

double   m_lastCTBuyPrice    = 0;
double   m_lastCTSellPrice   = 0;
datetime m_lastCTTime        = 0;
datetime m_lastRecoveryTime  = 0;
datetime m_lastBasketCheck   = 0;
datetime m_lastHarvestTime   = 0;
datetime m_lastDashTime      = 0;
datetime m_lastCleanupTime   = 0;

// Estadisticas para calculo de expectativa matematica
double   m_totalPnL          = 0;
int      m_tradesOpened      = 0;
int      m_tradesClosed      = 0;
double   m_bestClosed        = 0;
double   m_worstClosed       = 0;
int      m_totalWins         = 0;
int      m_totalLosses       = 0;
double   m_sumWins           = 0;
double   m_sumLosses         = 0;

long     m_tickCount         = 0;
bool     m_isProcessing      = false;

// Para el recovery: guardar precio de apertura del peor perdedor
double   m_losingPosOpenPrice = 0;
int      m_losingPosType      = -1;

//=================================================================
//  HELPERS
//=================================================================
double NormLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), Inp_LotMaximum);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   return NormalizeDouble(MathMax(minL, MathMin(maxL, lot)), 2);
}

double NormPrice(double p) { return NormalizeDouble(p, _Digits); }
bool GetTick(MqlTick &t)   { return SymbolInfoTick(_Symbol, t); }

double GetATR()
{
   double b[1];
   if(CopyBuffer(h_ATR, 0, 1, 1, b) == 1) return b[0];
   return _Point * 200;
}

double GetTickVal()  { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize() { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); }

double DistToUSD(double dist, double lot)
{
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv <= 0 || ts <= 0 || dist <= 0 || lot <= 0) return 0;
   return NormalizeDouble((dist / ts) * tv * lot, 2);
}

bool SpreadOK()
{
   int maxSpr = m_inSession ? Inp_MaxSpread : (int)Inp_CTMaxSpreadOff;
   return (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= maxSpr);
}

bool MarginOK(double lot, ENUM_ORDER_TYPE type)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_CTMinBalanceUSD) return false;
   if(free < eq * Inp_MinFreeMarginPct) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg))
      if(marg > free * 0.60) return false;
   return true;
}

// Calcula el margen requerido para 0.01 lot
double CalcMarginFor001()
{
   double marg = 0;
   MqlTick t; GetTick(t);
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 0.01, t.ask, marg)) return 2.0;
   return (marg > 0) ? marg : 2.0;
}

// Calcula ganancia en USD de 1.0 lot por 1 punto de movimiento
double ProfitPerLotPerPoint()
{
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv <= 0 || ts <= 0) return 1.0;
   return tv / ts;
}

//=================================================================
//  RECORDS
//=================================================================
int FindRec(ulong ticket)
{
   for(int i = 0; i < MAX_RECORDS; i++)
      if(m_rec[i].ticket == ticket) return i;
   return -1;
}

int FreeRec()
{
   for(int i = 0; i < MAX_RECORDS; i++)
      if(m_rec[i].ticket == 0) return i;
   return -1;
}

void InitRec(int idx, ulong ticket, int posType, double openPrice, double vol,
             string comment, bool isPrimary, bool isCounter,
             bool isRecovery = false, bool isLBC = false)
{
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
   m_rec[idx].isRecovery = isRecovery;
   m_rec[idx].isLBC      = isLBC;
   m_rec[idx].kP         = 1.0;
   m_rec[idx].kK         = 1.0;
}

void CleanupRecs()
{
   for(int i = 0; i < MAX_RECORDS; i++) {
      if(m_rec[i].ticket == 0) continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)) {
         double pnl = m_rec[i].netProfit;
         if(pnl != 0) {
            m_totalPnL += pnl;
            m_tradesClosed++;
            if(pnl > 0) { m_totalWins++;   m_sumWins   += pnl; }
            else         { m_totalLosses++; m_sumLosses += MathAbs(pnl); }
            if(pnl > m_bestClosed)  m_bestClosed  = pnl;
            if(pnl < m_worstClosed) m_worstClosed = pnl;
         }
         ZeroMemory(m_rec[i]);
      }
   }
}

void SyncPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(FindRec(t) >= 0) continue;
      int idx = FreeRec(); if(idx < 0) continue;
      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      string comm = PositionGetString(POSITION_COMMENT);
      bool isPri  = (StringFind(comm, "Primary") >= 0);
      bool isCT   = (StringFind(comm, "CT_")     >= 0);
      bool isRec  = (StringFind(comm, "REC_")    >= 0);
      bool isLBC  = (StringFind(comm, "LBC_")    >= 0);
      InitRec(idx, t, pt, op, vol, comm, isPri, isCT, isRec, isLBC);
   }
}

//=================================================================
//  KALMAN
//=================================================================
void KalmanUpdate(int idx, double meas)
{
   if(!m_rec[idx].kInit) {
      m_rec[idx].kX = meas; m_rec[idx].kP = 1.0;
      m_rec[idx].kK = 1.0;  m_rec[idx].kInit = true;
      return;
   }
   double pP = m_rec[idx].kP + 0.01;
   double K  = pP / (pP + 0.20);
   m_rec[idx].kX = m_rec[idx].kX + K * (meas - m_rec[idx].kX);
   m_rec[idx].kP = (1.0 - K) * pP;
   m_rec[idx].kK = K;
}

void UpdateKalman()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      int idx = FindRec(t); if(idx < 0) continue;
      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit = pf;
      if(pf > m_rec[idx].peakProfit) m_rec[idx].peakProfit = pf;
      KalmanUpdate(idx, pf);
   }
}

//=================================================================
//  SESION
//=================================================================
bool IsInMainSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   int gmtHour = (dt.hour - Inp_GMTOffset + 24) % 24;
   return ((gmtHour >= Inp_LondonOpen  && gmtHour < Inp_LondonClose) ||
           (gmtHour >= Inp_NYOpen      && gmtHour < Inp_NYClose));
}

double GetSessionQuality()
{
   if(m_inSession) return 1.0;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int h = (dt.hour - Inp_GMTOffset + 24) % 24;
   return (h >= 0 && h < Inp_LondonOpen) ? 0.4 : 0.6;
}

//=================================================================
//  MERCADO Y PORTFOLIO
//=================================================================
void UpdateMarket()
{
   MqlTick t; if(!GetTick(t)) return;
   m_mkt.bid    = t.bid;
   m_mkt.ask    = t.ask;
   m_mkt.spread = (t.ask - t.bid) / _Point;
   m_mkt.atr    = GetATR();

   double f[1], s[1], r[1], m[1], sg[1];
   if(CopyBuffer(h_EMAFast, 0, 0, 1, f)  == 1) m_mkt.emaFast  = f[0];
   if(CopyBuffer(h_EMASlow, 0, 0, 1, s)  == 1) m_mkt.emaSlow  = s[0];
   if(CopyBuffer(h_RSI,     0, 0, 1, r)  == 1) m_mkt.rsi      = r[0];
   if(CopyBuffer(h_MACD,    0, 0, 1, m)  == 1) m_mkt.macdMain = m[0];
   if(CopyBuffer(h_MACD,    1, 0, 1, sg) == 1) m_mkt.macdSig  = sg[0];
   if(h_ADX != INVALID_HANDLE) {
      double adxB[1];
      if(CopyBuffer(h_ADX, 0, 0, 1, adxB) == 1) m_mkt.adx = adxB[0];
   }
   if(h_HTFEMAFast != INVALID_HANDLE && h_HTFEMASlow != INVALID_HANDLE) {
      double hf[1], hs[1];
      if(CopyBuffer(h_HTFEMAFast, 0, 0, 1, hf) == 1 &&
         CopyBuffer(h_HTFEMASlow, 0, 0, 1, hs) == 1) {
         m_mkt.htfTrend = (hf[0] > hs[0] * 1.0001) ? 1 : (hf[0] < hs[0] * 0.9999) ? -1 : 0;
      }
   }
   m_mkt.isBullish = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.rsi > 52 && m_mkt.macdMain > m_mkt.macdSig);
   m_mkt.isBearish = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.rsi < 48 && m_mkt.macdMain < m_mkt.macdSig);
}

void UpdatePortfolio()
{
   ZeroMemory(m_port);
   m_port.worstProfit   = 0;
   m_losingPosOpenPrice = 0;
   m_losingPosType      = -1;

   double vwapNumer = 0;
   double vwapDenom = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;

      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double pf   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      string comm = PositionGetString(POSITION_COMMENT);

      m_port.totalPos++;
      m_port.totalProfit += pf;
      if(pf >= 0) m_port.positiveSum += pf;
      else        m_port.negativeSum += MathAbs(pf);

      if(pt == POSITION_TYPE_BUY) { m_port.buyCount++;  m_port.buyProfit  += pf; }
      else                        { m_port.sellCount++; m_port.sellProfit += pf; }

      // VWAP del bloque: suma(precio_apertura * volumen) / suma(volumen)
      // Trata BUY como +volumen, SELL como -volumen para direccion neta
      double signedVol = (pt == POSITION_TYPE_BUY) ? vol : -vol;
      vwapNumer += op * vol;
      vwapDenom += vol;
      m_port.blockDir += (pt == POSITION_TYPE_BUY) ? 1 : -1;

      if(pf < m_port.worstProfit) {
         m_port.worstProfit   = pf;
         m_port.worstTicket   = t;
         m_losingPosOpenPrice = op;
         m_losingPosType      = pt;
      }
      if(StringFind(comm, "CT_")  >= 0) m_port.ctCount++;
      if(StringFind(comm, "REC_") >= 0) m_port.recoveryCount++;
      if(StringFind(comm, "LBC_") >= 0) m_port.lbcCount++;
   }

   if(vwapDenom > 0) m_port.blockVWAP = vwapNumer / vwapDenom;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > m_bestEquity) m_bestEquity = eq;
   m_port.currentDD = (m_bestEquity > 0) ? (m_bestEquity - eq) / m_bestEquity : 0;
}

//=================================================================
//  ADX
//=================================================================
bool ADXAllowsEntry(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseADX) return true;
   double adxLevel = m_inSession ? Inp_ADXTrendLevel : Inp_ADXTrendLevelOff;
   if(m_mkt.adx < adxLevel) return true;
   int htf = m_mkt.htfTrend;
   if(htf == 0) return false;
   return (type == ORDER_TYPE_BUY && htf == 1) || (type == ORDER_TYPE_SELL && htf == -1);
}

//=================================================================
//  DIARIO
//=================================================================
void ResetDailyIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int sec = dt.hour * 3600 + dt.min * 60 + dt.sec;
   datetime midnight = TimeCurrent() - sec;
   if(m_lastDailyReset < midnight) {
      m_dailyBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      m_dailyLimitHit  = false;
      m_lastDailyReset = midnight;
   }
}

// SOLO PAUSA  - nunca cierra posiciones
bool DailyLimitReached()
{
   if(!Inp_UseDailyLimit) return false;
   if(m_dailyLimitHit) return true;
   double eff = (AccountInfoDouble(ACCOUNT_BALANCE) - m_dailyBalance) + m_port.totalProfit;
   double lim = MathMin(MathAbs(Inp_DailyLossUSD), m_dailyBalance * MathAbs(Inp_DailyLossPct));
   if(eff <= -lim) {
      Print("[V7.3] LIMITE DIARIO: solo pausa nuevas entradas, posiciones abiertas continuan");
      m_dailyLimitHit = true;
      m_isPaused      = true;
   }
   return m_dailyLimitHit;
}

void UpdateStreak(double pnl)
{
   if(pnl < -0.01) {
      m_consecutiveLosses++;
      if(m_consecutiveLosses >= Inp_LossStreakMax && m_lotMultiplier == 1.0)
         m_lotMultiplier = Inp_LossStreakReduce;
   } else if(pnl > 0.01) {
      m_lotMultiplier     = 1.0;
      m_consecutiveLosses = 0;
   }
}

// Expectativa matematica: (WR x AvgWin) - (LR x AvgLoss)
double CalcExpectancy()
{
   int total = m_totalWins + m_totalLosses;
   if(total == 0) return 0;
   double wr      = (double)m_totalWins / total;
   double lr      = 1.0 - wr;
   double avgWin  = (m_totalWins  > 0) ? m_sumWins   / m_totalWins  : 0;
   double avgLoss = (m_totalLosses> 0) ? m_sumLosses / m_totalLosses: 0;
   return (wr * avgWin) - (lr * avgLoss);
}

//=================================================================
//  CIERRE
//=================================================================
bool ClosePos(ulong ticket, string reason = "")
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   if(m_trade.PositionClose(ticket)) {
      UpdateStreak(pf);
      if(pf > 0) {
         m_cycleWinsSum += pf; m_cycleWinsCount++;
         m_totalWins++;        m_sumWins += pf;
      } else {
         m_cycleLossSum += pf;
         m_totalLosses++;      m_sumLosses += MathAbs(pf);
      }
      m_totalPnL += pf; m_tradesClosed++;
      if(pf > m_bestClosed)  m_bestClosed  = pf;
      if(pf < m_worstClosed) m_worstClosed = pf;

      int idx = FindRec(ticket);
      if(idx >= 0) {
         if(m_rec[idx].isPrimary) m_lastPrimaryLost = (pf < 0);
         // Si era LBC, actualizar contador
         if(m_rec[idx].isLBC) {
            string comm = m_rec[idx].comment;
            if(StringFind(comm, "LBC_B") >= 0 && m_lbc.buyCount > 0)  m_lbc.buyCount--;
            if(StringFind(comm, "LBC_S") >= 0 && m_lbc.sellCount > 0) m_lbc.sellCount--;
            if(pf > 0) { m_lbc.harvestedTotal += pf; m_lbc.harvestCount++; }
         }
         Print("[V7.3] CERRADA #", ticket, " $", NormalizeDouble(pf,2),
               (reason != "" ? " [" + reason + "]" : ""));
         ZeroMemory(m_rec[idx]);
      }
      return true;
   }
   return false;
}

// UNICO CIERRE VALIDO: bloque neto > BlockTPTarget
bool CloseBlockIfPositive(string reason)
{
   if(m_port.totalProfit < Inp_BlockTPTarget) return false;

   Print("[V7.3] CIERRE POSITIVO: PnL=$", NormalizeDouble(m_port.totalProfit,2),
         " >= $", Inp_BlockTPTarget, " [", reason, "]");
   m_isProcessing = true;

   // Primero ganadoras (aseguran capital), luego perdedoras (ya cubiertas)
   for(int pass = 0; pass < 2; pass++) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
         double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(pass == 0 && pf <  0) continue;
         if(pass == 1 && pf >= 0) continue;
         ClosePos(t, reason);
      }
   }

   m_isProcessing   = false;
   m_recoveryActive = false;
   m_recoveryOrders = 0;
   m_cycleResetTime = TimeCurrent();
   m_cycleInPause   = true;
   m_lastCTBuyPrice = m_lastCTSellPrice = 0;

   // Resetear LBC despues del cierre exitoso
   ZeroMemory(m_lbc);
   return true;
}

//=================================================================
//  LOTES
//=================================================================
double CalcLot(int level = 0)
{
   double sessionFactor = m_inSession ? 1.0 : Inp_OffSessionLotFactor;
   if(!Inp_UseDynamicLot || m_mkt.atr <= 0)
      return NormLot(Inp_LotBase * m_lotMultiplier * sessionFactor);

   double bal     = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskUSD = bal * Inp_RiskPerTradePct;
   double slATR   = m_inSession ? Inp_SL_ATR : Inp_OffSessionSL_ATR;
   double slDist  = m_mkt.atr * slATR;
   double tv = GetTickVal(), ts = GetTickSize();
   double lot = Inp_LotBase;
   if(tv > 0 && ts > 0 && slDist > 0) {
      double pipV = tv / ts;
      if(pipV > 0) lot = riskUSD / (slDist * pipV);
   }
   return NormLot(MathMax(lot, Inp_LotBase) * m_lotMultiplier * sessionFactor);
}

// Calculo del lote de recovery matematicamente correcto (igual que V7.2)
double CalcRecoveryLot()
{
   double atr = m_mkt.atr;
   if(atr <= 0) return NormLot(Inp_LotBase * Inp_RecoveryMinLotMult);

   double blockLoss   = MathAbs(m_port.totalProfit);
   double totalNeeded = blockLoss + Inp_BlockTPTarget;
   double moveDist    = atr * Inp_RecoveryMoveATR;
   if(moveDist <= 0) moveDist = atr * 0.5;

   double tv = GetTickVal(), ts = GetTickSize();
   double profitPer1LotPerDist = 0;
   if(tv > 0 && ts > 0)
      profitPer1LotPerDist = (moveDist / ts) * tv;

   double calcLot = Inp_LotBase;
   if(profitPer1LotPerDist > 0)
      calcLot = totalNeeded / profitPer1LotPerDist;

   double loserLot = Inp_LotBase;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(pf == m_port.worstProfit) { loserLot = vol; break; }
   }

   double minRecLot = loserLot * Inp_RecoveryMinLotMult;
   double finalLot  = MathMax(calcLot, minRecLot);

   Print("[V7.3] REC LOT: necesito ganar $", NormalizeDouble(totalNeeded,2),
         " en ", NormalizeDouble(moveDist,_Digits), " pts | 1lot=$",
         NormalizeDouble(profitPer1LotPerDist,2),
         " | calc=", NormalizeDouble(calcLot,2),
         " | min=",  NormalizeDouble(minRecLot,2),
         " | final=",NormalizeDouble(NormLot(finalLot),2));

   return NormLot(finalLot);
}

//=================================================================
//  APERTURA  - SL=0, TP=0 siempre (broker no cierra auto)
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type, double lot, string comment, bool skipPosLimit = false)
{
   if((m_isPaused || m_emergencyMode) && !skipPosLimit) return 0;
   if(!SpreadOK()) return 0;
   if(!skipPosLimit && PositionsTotal() >= Inp_MaxPositionsTotal) return 0;
   if( skipPosLimit && PositionsTotal() >= Inp_MaxPositionsTotal + 4) return 0;
   lot = NormLot(lot); if(lot <= 0) return 0;
   if(!MarginOK(lot, type)) return 0;

   MqlTick t; if(!GetTick(t)) return 0;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;

   // SL=0, TP=0  - El broker NUNCA cierra automaticamente
   bool ok = (type == ORDER_TYPE_BUY)
      ? m_trade.Buy( lot, _Symbol, price, 0, 0, comment)
      : m_trade.Sell(lot, _Symbol, price, 0, 0, comment);

   if(!ok) { Print("[V7.3] ERR apertura: ", m_trade.ResultRetcodeDescription()); return 0; }

   ulong ticket = m_trade.ResultOrder();
   if(ticket > 0) {
      m_tradesOpened++;
      Print("[V7.3] ABIERTA #", ticket, " ",
            (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot=", lot, " @ ", NormalizeDouble(price,_Digits),
            " SL=0 TP=0",
            (m_inSession ? " [SESION]" : " [FUERA]"),
            " [", comment, "]");
   }
   return ticket;
}

//=================================================================
//  ManagePositions  - Sin SL/TP/Trailing/BE (causan cierres auto)
//=================================================================
void ManagePositions()
{
   // Vacio intencionalmente.
   // El bloque se gestiona como unidad y solo cierra cuando es positivo.
}

//=================================================================
//  RECOVERY ENGINE V7.3  - MATEMATICAMENTE CORRECTO
//  (Identico a V7.2, solo agrega llamada a ActivateLBC cuando
//   no hay margen suficiente en lugar de simplemente retornar)
//=================================================================
void RunRecoveryEngine()
{
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD) {
      if(m_recoveryActive) {
         m_recoveryActive = false;
         m_recoveryOrders = 0;
      }
      return;
   }
   if(m_port.totalPos == 0) return;
   if(m_isProcessing)        return;

   if(CloseBlockIfPositive("Recovery_TP")) return;

   if(!m_recoveryActive) {
      m_recoveryActive = true;
      m_recoveryOrders = m_port.recoveryCount;
      Print("[V7.3] RECOVERY ACTIVADO | PnL=$", NormalizeDouble(m_port.totalProfit,2));
   }

   if(m_recoveryOrders >= Inp_RecoveryMaxOrders) return;
   if(TimeCurrent() - m_lastRecoveryTime < Inp_RecoveryIntervalSec) return;
   if(!SpreadOK()) return;

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   // Verificacion de distancia del perdedor (evita hedge perfecto)
   if(m_losingPosOpenPrice > 0 && m_losingPosType >= 0) {
      double distFromLoser = 0;
      if(m_losingPosType == POSITION_TYPE_SELL)
         distFromLoser = tk.bid - m_losingPosOpenPrice;
      else
         distFromLoser = m_losingPosOpenPrice - tk.ask;

      double minDist = atr * Inp_RecoveryMinDistATR;
      if(distFromLoser < minDist) {
         Print("[V7.3] RECOVERY: esperando dist | actual=",
               NormalizeDouble(distFromLoser,_Digits),
               " / min=", NormalizeDouble(minDist,_Digits));
         return;
      }
   }

   ENUM_ORDER_TYPE recType;
   if(m_port.buyProfit < m_port.sellProfit) {
      recType = ORDER_TYPE_BUY;
      if(m_lastCTBuyPrice > 0 &&
         MathAbs(tk.ask - m_lastCTBuyPrice) < atr * 0.3) return;
   } else {
      recType = ORDER_TYPE_SELL;
      if(m_lastCTSellPrice > 0 &&
         MathAbs(tk.bid - m_lastCTSellPrice) < atr * 0.3) return;
   }

   double recLot = CalcRecoveryLot();

   // Intentar con lote completo primero
   if(!MarginOK(recLot, recType)) {
      recLot = NormLot(recLot * 0.5);
      if(!MarginOK(recLot, recType)) {
         recLot = NormLot(Inp_LotBase);
         if(!MarginOK(recLot, recType)) {
            Print("[V7.3] RECOVERY: Sin margen suficiente -> Activando modo LBC");
            // *** NUEVO V7.3: En lugar de rendirse, activa el modo LBC ***
            ActivateLBC();
            return;
         }
      }
   }

   string recComm = "REC_" + (recType == ORDER_TYPE_BUY ? "B" : "S") +
                    "_" + IntegerToString(m_recoveryOrders + 1);
   m_isProcessing = true;
   ulong ticket = OpenOrder(recType, recLot, recComm, true);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (recType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (recType == ORDER_TYPE_BUY) ? tk.ask : tk.bid;
         InitRec(idx, ticket, pt, op, recLot, recComm, false, false, true, false);
      }
      if(recType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = tk.ask;
      else                            m_lastCTSellPrice = tk.bid;
      m_recoveryOrders++;
      m_lastRecoveryTime = TimeCurrent();
   }
}

//=================================================================
//  *** LBC ENGINE  - NUEVO V7.3 ***
//  LOW BALANCE CONTINGENCY: MICRO-GRID HEDGEADO DE 0.01 LOTS
//
//  MATEMATICA:
//  - Problema: No hay margen para el lote calculado por Recovery
//  - Solucion: Abrir pares BUY+SELL de 0.01 lot en niveles del grid
//  - Cada par es delta-neutral al momento de apertura (sin exposicion neta)
//  - Cuando el precio se mueve, una de las dos gana -> cosechar esa ganancia
//  - Repetir hasta acumular suficiente para cerrar el bloque en positivo
//
//  VENTAJAS CON BALANCE BAJO ($40):
//  - Margen por 0.01 lot ? $0.20-$2.00 (segun broker/apalancamiento)
//  - Con $40: pueden mantenerse 4-6 pares simultaneos
//  - No importa la direccion del mercado: siempre hay un lado ganador
//  - Cosechas peque?as pero frecuentes acumulan hacia el objetivo
//
//  EXPECTATIVA MATEMATICA:
//  E[ganancia por par por cosecha] = ATR * LBCHarvestATR * (TV/TS) * 0.01
//  Con ATR=3, HarvestATR=0.15, TV/TS=100: E = 3*0.15*100*0.01 = $0.45/cosecha
//  Con 4 pares: posible recuperar $1.80 por ronda de cosechas
//=================================================================
void ActivateLBC()
{
   if(m_lbc.active) return;  // Ya activo
   m_lbc.active       = true;
   m_lbc.activatedTime = TimeCurrent();
   m_lbc.buyCount      = 0;
   m_lbc.sellCount     = 0;
   m_lbc.lastBuyPrice  = 0;
   m_lbc.lastSellPrice = 0;
   m_lbc.harvestedTotal= 0;
   m_lbc.harvestCount  = 0;

   // Calcular cuantos pares podemos soportar con el margen disponible
   double freeMarg    = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margPer001  = CalcMarginFor001();
   // Cada par usa 2 * margPer001 (un BUY y un SELL)
   double usableMarg  = freeMarg * Inp_LBCMarginPct;
   m_lbc.maxOrdersCalc = (int)MathFloor(usableMarg / (2.0 * MathMax(margPer001, 0.01)));
   m_lbc.maxOrdersCalc = MathMax(1, MathMin(m_lbc.maxOrdersCalc, Inp_LBCMaxPairs));

   Print("[V7.3] LBC ACTIVADO | LibreMarg=$", NormalizeDouble(freeMarg,2),
         " | MargPor0.01=$", NormalizeDouble(margPer001,2),
         " | MaxPares=", m_lbc.maxOrdersCalc);
}

void DeactivateLBC()
{
   if(!m_lbc.active) return;
   Print("[V7.3] LBC DESACTIVADO | Total cosechado: $",
         NormalizeDouble(m_lbc.harvestedTotal,2),
         " en ", m_lbc.harvestCount, " cosechas");
   ZeroMemory(m_lbc);
}

void RunLBCEngine()
{
   if(!m_lbc.active) return;
   if(m_port.totalPos == 0) { DeactivateLBC(); return; }
   if(m_isProcessing)        return;

   // Si el bloque ya es positivo, el cierre normal lo maneja
   if(m_port.totalProfit >= Inp_BlockTPTarget) return;

   // Si la situacion mejoro y Recovery puede funcionar, desactivar LBC
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD * 0.5) {
      DeactivateLBC();
      return;
   }

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   // --- PASO 1: COSECHAR posiciones LBC que alcanzaron el objetivo ---
   double harvestMin = DistToUSD(atr * Inp_LBCHarvestATR, 0.01);
   harvestMin = MathMax(harvestMin, 0.02); // minimo absoluto $0.02

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      string comm = PositionGetString(POSITION_COMMENT);
      if(StringFind(comm, "LBC_") < 0) continue;
      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pf >= harvestMin) {
         ClosePos(t, "LBC_Harvest");
         // Recalcular maximos despues de cosecha
         double freeMarg   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         double margPer001 = CalcMarginFor001();
         m_lbc.maxOrdersCalc = (int)MathFloor(
            (freeMarg * Inp_LBCMarginPct) / (2.0 * MathMax(margPer001,0.01)));
         m_lbc.maxOrdersCalc = MathMax(1, MathMin(m_lbc.maxOrdersCalc, Inp_LBCMaxPairs));
      }
   }

   // --- PASO 2: ABRIR nuevos pares si hay capacidad y tiempo ---
   if(TimeCurrent() - m_lbc.lastOrderTime < Inp_LBCIntervalSec) return;
   if(!SpreadOK()) return;

   int totalLBCPairs = MathMin(m_lbc.buyCount, m_lbc.sellCount);
   if(totalLBCPairs >= m_lbc.maxOrdersCalc) return;

   // Espaciado del grid: ajustado por sesion
   // En sesion principal (London/NY): mercado mas volatile, espaciado mayor
   double sessionMult = m_inSession ? 1.2 : 1.0;
   double gridSpace   = atr * Inp_LBCGridATR * sessionMult;
   double lot001      = NormLot(Inp_LotBase);

   // Estrategia de apertura:
   // - Siempre abrir el lado que FAVORECE recuperar el bloque
   // - Si BUY es el perdedor (precio bajo), abrir mas SELLs (para beneficiarse de subida)
   //   ADEMAS de BUYs (para cuando rebote)
   // - Alternar pero con sesgo hacia el lado de recuperacion

   bool needBuy  = false;
   bool needSell = false;

   // Primera vez o desequilibrio grande: abrir el par completo
   if(m_lbc.buyCount == 0 && m_lbc.sellCount == 0) {
      needBuy  = true;
      needSell = true;
   } else {
      // Mantener balance entre BUYs y SELLs, con sesgo hacia recuperacion
      bool buyIsLosing = (m_port.buyProfit < m_port.sellProfit);

      if(m_lbc.buyCount <= m_lbc.sellCount) {
         // Necesita mas BUYs
         if(m_lastCTBuyPrice <= 0 || MathAbs(tk.ask - m_lbc.lastBuyPrice) >= gridSpace)
            needBuy = true;
      }
      if(m_lbc.sellCount <= m_lbc.buyCount) {
         // Necesita mas SELLs
         if(m_lbc.lastSellPrice <= 0 || MathAbs(tk.bid - m_lbc.lastSellPrice) >= gridSpace)
            needSell = true;
      }
   }

   // Abrir BUY LBC
   if(needBuy && MarginOK(lot001, ORDER_TYPE_BUY)) {
      string commB = "LBC_B" + IntegerToString(m_lbc.buyCount + 1);
      m_isProcessing = true;
      ulong ticketB = OpenOrder(ORDER_TYPE_BUY, lot001, commB, true);
      m_isProcessing = false;
      if(ticketB > 0) {
         int idx = FreeRec();
         if(idx >= 0) InitRec(idx, ticketB, POSITION_TYPE_BUY, tk.ask, lot001, commB,
                              false, false, false, true);
         m_lbc.buyCount++;
         m_lbc.lastBuyPrice   = tk.ask;
         m_lbc.lastOrderTime  = TimeCurrent();
         Print("[V7.3] LBC BUY abierto #", ticketB,
               " | Pares activos: B=", m_lbc.buyCount, " S=", m_lbc.sellCount,
               " | Cosechado total: $", NormalizeDouble(m_lbc.harvestedTotal,2));
      }
   }

   // Abrir SELL LBC
   if(needSell && MarginOK(lot001, ORDER_TYPE_SELL)) {
      string commS = "LBC_S" + IntegerToString(m_lbc.sellCount + 1);
      m_isProcessing = true;
      ulong ticketS = OpenOrder(ORDER_TYPE_SELL, lot001, commS, true);
      m_isProcessing = false;
      if(ticketS > 0) {
         int idx = FreeRec();
         if(idx >= 0) InitRec(idx, ticketS, POSITION_TYPE_SELL, tk.bid, lot001, commS,
                              false, false, false, true);
         m_lbc.sellCount++;
         m_lbc.lastSellPrice  = tk.bid;
         m_lbc.lastOrderTime  = TimeCurrent();
         Print("[V7.3] LBC SELL abierto #", ticketS,
               " | Pares activos: B=", m_lbc.buyCount, " S=", m_lbc.sellCount,
               " | Cosechado total: $", NormalizeDouble(m_lbc.harvestedTotal,2));
      }
   }
}

//=================================================================
//  BASKET TP
//=================================================================
void RunBasketTP()
{
   if(!Inp_UseBasketTP) return;
   if(TimeCurrent() - m_lastBasketCheck < Inp_BasketCheckSec) return;
   m_lastBasketCheck = TimeCurrent();
   if(m_port.totalPos < 2) return;
   if(m_port.totalProfit < Inp_BlockTPTarget) return;
   double avgWin = (m_cycleWinsCount > 0) ? m_cycleWinsSum / m_cycleWinsCount : Inp_BasketTPFactor;
   double target = MathMax(Inp_BlockTPTarget, avgWin * Inp_BasketTPRatio);
   if(m_port.totalProfit >= target) CloseBlockIfPositive("BasketTP");
}

// SOLO activa recovery  - nunca cierra
void CheckCycleMaxLoss()
{
   if(!Inp_UseCycleMaxLoss || m_port.totalPos == 0) return;
   if(m_port.totalProfit <= Inp_CycleMaxLossUSD) {
      Print("[V7.3] CYCLE MAX LOSS: $", NormalizeDouble(m_port.totalProfit,2),
            " -> Forzando Recovery (no cierra nada)");
      if(!m_recoveryActive) { m_recoveryActive = true; m_recoveryOrders = 0; }
   }
}

//=================================================================
//  HARVEST
//=================================================================
void RunHarvest()
{
   if(!Inp_HarvestContinuous || m_isProcessing) return;
   if(TimeCurrent() - m_lastHarvestTime < Inp_HarvestIntervalSec) return;
   m_lastHarvestTime = TimeCurrent();
   if(m_port.totalProfit < Inp_BlockTPTarget) return;

   double atr = m_mkt.atr, tv = GetTickVal(), ts = GetTickSize();
   double sessMult = m_inSession ? 1.0 : 1.5;
   double hMin = Inp_HarvestMinUSD * sessMult;
   if(atr > 0 && tv > 0 && ts > 0) {
      double minL   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double atrUSD = (atr / ts) * tv * minL * Inp_HarvestATRMult * sessMult;
      hMin = MathMax(hMin, NormalizeDouble(atrUSD, 2));
   }

   int harvested = 0; double totalH = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      int    idx = FindRec(t);
      double kpf = (idx >= 0 && m_rec[idx].kInit) ? m_rec[idx].kX : pf;
      if(m_port.negativeSum > pf * 1.5 && pf > 0) continue;
      bool doH = (pf >= hMin * 3.0) ||
                 (kpf >= hMin && idx >= 0 && m_rec[idx].kInit && m_rec[idx].kK <= 0.30);
      if(doH && ClosePos(t, "Harvest")) { harvested++; totalH += pf; }
   }
   if(harvested > 0)
      Print("[V7.3] HARVEST: ", harvested, " cerradas | $", NormalizeDouble(totalH,2));
}

// SOLO pausa  - nunca cierra
bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   if(m_port.totalProfit <= Inp_EmergencyLossUSD && !m_emergencyMode) {
      Print("[V7.3] ALERTA EQUITY: $", NormalizeDouble(m_port.totalProfit,2),
            " -> Solo pausa. Posiciones abiertas se mantienen.");
      m_emergencyMode = true;
      m_isPaused      = true;
      return true;
   }
   if(m_port.currentDD >= Inp_MaxDrawdownPct)
      m_isPaused = true;
   else if(m_isPaused && !m_emergencyMode && !m_dailyLimitHit &&
           m_port.currentDD < Inp_MaxDrawdownPct * 0.5)
      m_isPaused = false;
   return false;
}

//=================================================================
//  CT ENGINE
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType, double &ctLot, int &ctLevel)
{
   if(m_port.totalPos == 0) return false;
   if(m_port.totalPos >= Inp_MaxPositionsTotal) return false;
   if(m_port.totalProfit >= 0 && m_port.negativeSum == 0) return false;
   if(m_recoveryActive) return false;
   if(m_lbc.active)     return false;  // LBC tiene prioridad sobre CT en modo contingencia
   if(m_mkt.atr <= 0) return false;

   int  buyCount  = m_port.buyCount;
   int  sellCount = m_port.sellCount;
   bool buyLosing  = (m_port.buyProfit  < -0.05 && buyCount  > 0);
   bool sellLosing = (m_port.sellProfit < -0.05 && sellCount > 0);
   bool openBuy = false, openSell = false;

   if(buyLosing && !sellLosing) {
      if(sellCount >= Inp_CTMaxSameDir) return false;
      openSell = true;
   } else if(sellLosing && !buyLosing) {
      if(buyCount >= Inp_CTMaxSameDir) return false;
      openBuy = true;
   } else if(buyLosing && sellLosing) {
      if(m_mkt.htfTrend == 1  && buyCount  < Inp_CTMaxSameDir) openBuy  = true;
      else if(m_mkt.htfTrend == -1 && sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(m_port.buyProfit < m_port.sellProfit && sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(buyCount < Inp_CTMaxSameDir) openBuy = true;
      else return false;
   } else return false;

   ENUM_ORDER_TYPE testType = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!ADXAllowsEntry(testType)) return false;

   double ctDist = (Inp_CTMode == CT_ATR_DISTANCE)
      ? m_mkt.atr * Inp_CTDistanceATR
      : Inp_CTFixedPoints * _Point;
   MqlTick t; if(!GetTick(t)) return false;
   if(ctDist > 0) {
      if(openBuy  && m_lastCTBuyPrice  > 0 && MathAbs(t.ask - m_lastCTBuyPrice)  < ctDist) return false;
      if(openSell && m_lastCTSellPrice > 0 && MathAbs(t.bid - m_lastCTSellPrice) < ctDist) return false;
   }
   ctLevel = openBuy ? buyCount : sellCount;
   ctLot   = CalcLot(ctLevel);
   ctType  = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine()
{
   if(m_isProcessing || m_isPaused || m_emergencyMode || m_cycleInPause) return;
   if(TimeCurrent() - m_lastCTTime < Inp_CTIntervalSec) return;
   m_lastCTTime = TimeCurrent();

   MqlTick ts; if(!GetTick(ts)) return;
   double maxSpr = m_inSession ? (double)Inp_MaxSpread : Inp_CTMaxSpreadOff;
   if((ts.ask - ts.bid) / _Point > maxSpr) return;

   if(m_port.totalPos == 0) {
      int cooldown = m_inSession ? Inp_PrimaryCooldownSec : Inp_PrimaryCooldownOff;
      if(TimeCurrent() - m_lastPrimaryTime < cooldown) return;

      ENUM_ORDER_TYPE initType;
      if(m_mkt.isBullish)                  initType = ORDER_TYPE_BUY;
      else if(m_mkt.isBearish)             initType = ORDER_TYPE_SELL;
      else if(m_mkt.emaFast > m_mkt.emaSlow) initType = ORDER_TYPE_BUY;
      else                                 initType = ORDER_TYPE_SELL;

      if(m_lastPrimaryLost && m_lastPrimaryDir != 0) {
         ENUM_ORDER_TYPE alt = (m_lastPrimaryDir == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         if(initType != alt) { initType = alt; m_lastPrimaryLost = false; }
      }
      if(!ADXAllowsEntry(initType)) return;
      if(!m_inSession) {
         bool clearSignal = (m_mkt.isBullish && initType == ORDER_TYPE_BUY) ||
                            (m_mkt.isBearish && initType == ORDER_TYPE_SELL);
         if(!clearSignal) return;
      }

      double lot = CalcLot(0);
      m_isProcessing = true;
      ulong ticket = OpenOrder(initType, lot, "Primary_Entry");
      if(ticket > 0) {
         int idx = FreeRec();
         if(idx >= 0) {
            int    pt = (initType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
            double op = (initType == ORDER_TYPE_BUY) ? ts.ask : ts.bid;
            InitRec(idx, ticket, pt, op, lot, "Primary_Entry", true, false, false, false);
         }
         m_lastPrimaryDir  = (initType == ORDER_TYPE_BUY) ? 1 : -1;
         m_lastPrimaryTime = TimeCurrent();
         if(initType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = ts.ask;
         else                             m_lastCTSellPrice = ts.bid;
         m_recoveryActive = false;
         m_recoveryOrders = 0;
         DeactivateLBC();
      }
      m_isProcessing = false;
      return;
   }

   ENUM_ORDER_TYPE ctType; double ctLot; int ctLevel;
   if(!ShouldOpenCT(ctType, ctLot, ctLevel)) return;
   if(!MarginOK(ctLot, ctType)) return;

   string ctComm = "CT_" + (ctType == ORDER_TYPE_BUY ? "B" : "S") +
                   "_L" + IntegerToString(ctLevel + 1);
   m_isProcessing = true;
   ulong ticket = OpenOrder(ctType, ctLot, ctComm);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (ctType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (ctType == ORDER_TYPE_BUY) ? ts.ask : ts.bid;
         InitRec(idx, ticket, pt, op, ctLot, ctComm, false, true, false, false);
      }
      if(ctType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = ts.ask;
      else                           m_lastCTSellPrice = ts.bid;
   }
}

//=================================================================
//  DASHBOARD V7.3  - MEJORADO Y ACCESIBLE
//  Con fondo semitransparente y lenguaje para todos los usuarios
//=================================================================
void Lbl(string n, string txt, int x, int y, color c, int fs = 9)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,   CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  fs);
      ObjectSetString(0,  n, OBJPROP_FONT,     "Consolas");
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTED,   false);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     c);
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
}

void Btn(string n, string txt, int x, int y, int w, int h, color bg)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,   CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_XSIZE,    w);
      ObjectSetInteger(0, n, OBJPROP_YSIZE,    h);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  8);
      ObjectSetString(0,  n, OBJPROP_FONT,     "Consolas");
      ObjectSetInteger(0, n, OBJPROP_COLOR,    clrWhite);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,   bg);
}

// Panel de fondo para el dashboard
void DrawDashBG(int x, int y, int w, int h)
{
   string n = "D73_BG";
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,      CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_BACK,        true);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, n, OBJPROP_SELECTED,    false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,      true);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,     h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,   C'15,15,50');
   ObjectSetInteger(0, n, OBJPROP_COLOR,     C'40,40,60');
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
}

void DeleteDash()
{
   string ns[] = {
      "D73_BG",
      "D73_T0","D73_T1",
      "D73_L1","D73_L2","D73_L3","D73_L4","D73_L5",
      "D73_L6","D73_L7","D73_L8","D73_L9","D73_L10",
      "D73_L11","D73_L12","D73_L13","D73_L14","D73_L15",
      "D73_B1","D73_B2"
   };
   for(int i = 0; i < ArraySize(ns); i++) ObjectDelete(0, ns[i]);
}

void UpdateDash()
{
   if(!Inp_ShowDashboard) return;
   if(TimeCurrent() - m_lastDashTime < 1) return;
   m_lastDashTime = TimeCurrent();

   int  x0 = Inp_DashX, y0 = Inp_DashY;
   int  lh = 16, pad = 8;
   int  dashW = 480, dashH = 20 * lh + 50;

   // Fondo del panel
   DrawDashBG(x0 - pad, y0 - pad, dashW, dashH);

   int  x = x0, y = y0;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);

   // Colores
   color cGreen = C'80,220,80';
   color cRed   = C'220,80,80';
   color cYel   = C'220,200,60';
   color cCyan  = C'80,200,220';
   color cGray  = C'160,160,160';
   color cOra   = C'220,140,40';
   color cWhite = C'240,240,240';

   // Estado principal
   string stStr, stDetail;
   color  stC;
   if(m_emergencyMode) {
      stStr = "[ALERTA DE CAPITAL]"; stC = cRed;
      stDetail = "Capital bajo. Robot vigilando pero no abre nuevas operaciones.";
   } else if(m_dailyLimitHit) {
      stStr = "[LIMITE DIARIO ALCANZADO]"; stC = cOra;
      stDetail = "Perdida maxima del dia alcanzada. Se reanuda manana.";
   } else if(m_lbc.active) {
      stStr = "[MODO MICRO-GRID LBC ACTIVO]"; stC = cOra;
      stDetail = "Balance bajo: abriendo mini-operaciones para recuperar. Ver seccion LBC.";
   } else if(m_recoveryActive) {
      stStr = "[MODO RESCATE ACTIVO]"; stC = cOra;
      stDetail = "Operacion en perdida. Robot buscando recuperar con orden mayor.";
   } else if(m_cycleInPause) {
      stStr = "[PAUSA ENTRE CICLOS]"; stC = cYel;
      stDetail = "Ciclo cerrado con exito. Esperando para abrir el siguiente.";
   } else if(m_isPaused) {
      stStr = "[ROBOT EN PAUSA]"; stC = cYel;
      stDetail = "Pausado manualmente o por proteccion. Posiciones abiertas siguen vivas.";
   } else {
      stStr = "[ROBOT ACTIVO 24/7]"; stC = cGreen;
      stDetail = "Operando normalmente. Buscando oportunidades de entrada.";
   }

   // Mercado
   string mktStr = m_mkt.isBullish ? "SUBIENDO" : m_mkt.isBearish ? "BAJANDO" : "LATERAL";
   color  mktC   = m_mkt.isBullish ? cGreen : m_mkt.isBearish ? cRed : cGray;
   string sesStr = m_inSession ? "Sesion Principal (Londres/NY)" : "Sesion Fuera de Horario";
   color  sesC   = m_inSession ? cGreen : cOra;
   string htfStr = (m_mkt.htfTrend == 1) ? "TENDENCIA SUBE" :
                   (m_mkt.htfTrend == -1) ? "TENDENCIA BAJA" : "SIN TENDENCIA CLARA";

   // PnL del bloque
   double pnl   = m_port.totalProfit;
   double falta = Inp_BlockTPTarget - pnl;
   color  pnlC  = (pnl >= 0) ? cGreen : cRed;
   string pnlStr;
   if(pnl >= 0)
      pnlStr = "Ganando: +$" + DoubleToString(pnl,2);
   else
      pnlStr = "Perdiendo: -$" + DoubleToString(MathAbs(pnl),2);

   // Precio promedio del bloque (VWAP)
   string vwapStr = (m_port.blockVWAP > 0)
      ? "Precio prom. entrada: " + DoubleToString(m_port.blockVWAP,_Digits)
      : "Sin operaciones abiertas";
   string blockDirStr = (m_port.blockDir > 0) ? "Bloque LARGO (comprado neto)" :
                        (m_port.blockDir < 0) ? "Bloque CORTO (vendido neto)" : "Bloque NEUTRAL";

   // Caida
   double ddPct = m_port.currentDD * 100;
   color  ddC   = (ddPct > 10) ? cRed : (ddPct > 5) ? cOra : cGreen;

   // Expectativa matematica
   double expect = CalcExpectancy();
   int    totalT = m_totalWins + m_totalLosses;
   double wrPct  = (totalT > 0) ? (double)m_totalWins / totalT * 100 : 0;
   string expectStr = "Win rate: " + DoubleToString(wrPct,1) + "% | " +
                      "Expectativa: $" + DoubleToString(expect,3) + " por operacion";

   // Distancia del perdedor (para recovery)
   double distFromLoser = 0;
   double minRecDist    = m_mkt.atr * Inp_RecoveryMinDistATR;
   if(m_losingPosOpenPrice > 0 && m_losingPosType >= 0) {
      MqlTick tk; GetTick(tk);
      if(m_losingPosType == POSITION_TYPE_SELL)
         distFromLoser = tk.bid - m_losingPosOpenPrice;
      else
         distFromLoser = m_losingPosOpenPrice - tk.ask;
   }
   bool  distOK     = (distFromLoser >= minRecDist);
   color distC      = distOK ? cGreen : cOra;
   string distStr   = (m_recoveryActive)
      ? ("Distancia al perdedor: " + DoubleToString(distFromLoser,_Digits) +
         " | Minimo necesario: " + DoubleToString(minRecDist,_Digits) +
         (distOK ? " [OK]" : " [esperando...]"))
      : "Recovery inactivo";

   // LBC info
   string lbcStr;
   color  lbcC;
   if(m_lbc.active) {
      lbcStr = "MICRO-GRID ACTIVO | Compras LBC: " + IntegerToString(m_lbc.buyCount) +
               " | Ventas LBC: " + IntegerToString(m_lbc.sellCount) +
               " | Max pares: " + IntegerToString(m_lbc.maxOrdersCalc);
      lbcC   = cOra;
   } else {
      lbcStr = "Micro-grid en espera (solo activa si falta margen para recovery)";
      lbcC   = cGray;
   }
   string lbcHarvestStr = "LBC cosechado: $" + DoubleToString(m_lbc.harvestedTotal,2) +
                          " en " + IntegerToString(m_lbc.harvestCount) + " operaciones";

   // ---- Dibujar labels ----

   // Titulo
   Lbl("D73_T0", "=== " + VERSION_STR + " | ORO / XAUUSD | 24 horas ===", x, y, cWhite, 10); y += lh + 2;
   Lbl("D73_T1", "REGLA DE ORO: El robot solo cierra cuando el conjunto gana. Nunca cierra en perdida.", x, y, cGray, 8); y += lh + 2;

   Lbl("D73_L1",  stStr + " | " + stDetail,  x, y, stC, 9); y += lh;

   // Mercado
   Lbl("D73_L2",  "Mercado: " + mktStr + " | " + sesStr + " | Tendencia mayor: " + htfStr +
       " | ATR: " + DoubleToString(m_mkt.atr,_Digits), x, y, mktC, 9); y += lh;

   // Cuenta
   Lbl("D73_L3",  "Tu cuenta: Saldo $" + DoubleToString(bal,2) +
       " | Capital actual $" + DoubleToString(eq,2) +
       " | Maximo alcanzado $" + DoubleToString(m_bestEquity,2), x, y, cCyan, 9); y += lh;

   // PnL bloque
   Lbl("D73_L4",  pnlStr + " | Para cerrar necesita: +$" + DoubleToString(Inp_BlockTPTarget,2) +
       " | Aun faltan: $" + DoubleToString(MathMax(falta,0),2), x, y, pnlC, 9); y += lh;

   // VWAP y direccion
   Lbl("D73_L5",  vwapStr + " | " + blockDirStr, x, y, cGray, 9); y += lh;

   // Operaciones abiertas
   Lbl("D73_L6",  "Operaciones abiertas: " + IntegerToString(m_port.totalPos) +
       " | Comprando: " + IntegerToString(m_port.buyCount) +
       " ($" + DoubleToString(m_port.buyProfit,2) + ")" +
       " | Vendiendo: " + IntegerToString(m_port.sellCount) +
       " ($" + DoubleToString(m_port.sellProfit,2) + ")", x, y, cCyan, 9); y += lh;

   // Recovery
   Lbl("D73_L7",  "RESCATE: " + (m_recoveryActive ? "ACTIVO (" + IntegerToString(m_recoveryOrders) +
       "/" + IntegerToString(Inp_RecoveryMaxOrders) + " ordenes)" : "En espera") +
       " | Spread: " + IntegerToString((int)m_mkt.spread) + " pts" +
       " | RSI: " + DoubleToString(m_mkt.rsi,0) +
       " | ADX: " + DoubleToString(m_mkt.adx,1),
       x, y, m_recoveryActive ? cOra : cGray, 9); y += lh;

   // Distancia
   Lbl("D73_L8",  distStr, x, y, distC, 9); y += lh;

   // LBC
   Lbl("D73_L9",  lbcStr, x, y, lbcC, 9); y += lh;
   Lbl("D73_L10", lbcHarvestStr, x, y, (m_lbc.harvestCount > 0) ? cGreen : cGray, 9); y += lh;

   // Caida y protecciones
   Lbl("D73_L11", "Caida actual: " + DoubleToString(ddPct,1) + "%" +
       " | Alerta capital si pierde mas de $" + DoubleToString(MathAbs(Inp_EmergencyLossUSD),1) +
       " (solo pausa, no cierra)" +
       " | Limite dia: -$" + DoubleToString(MathAbs(Inp_DailyLossUSD),1),
       x, y, ddC, 9); y += lh;

   // Estadisticas de rendimiento
   Lbl("D73_L12", "Historial: " + IntegerToString(m_tradesOpened) + " abiertas | " +
       IntegerToString(m_tradesClosed) + " cerradas | " +
       "Mejor: +$" + DoubleToString(m_bestClosed,2) +
       " | Peor: -$" + DoubleToString(MathAbs(m_worstClosed),2), x, y, cCyan, 9); y += lh;

   // Expectativa
   Lbl("D73_L13", expectStr +
       " | Rachas perdedoras: " + IntegerToString(m_consecutiveLosses) +
       " | Ticks: " + IntegerToString((int)m_tickCount),
       x, y, (expect >= 0) ? cGreen : cOra, 9); y += lh;

   // Ganancia acumulada
   Lbl("D73_L14", "PnL acumulado cerrado: $" + DoubleToString(m_totalPnL,2) +
       " | LBC total cosechado: $" + DoubleToString(m_lbc.harvestedTotal,2),
       x, y, (m_totalPnL >= 0) ? cGreen : cRed, 9); y += lh + 4;

   // Botones
   Btn("D73_B1", m_isPaused ? ">> REANUDAR ROBOT <<" : "|| PAUSAR ROBOT",
       x, y, 140, 22, m_isPaused ? clrGoldenrod : clrDarkGreen);
   Btn("D73_B2", "CERRAR TODAS (MANUAL)",
       x + 150, y, 150, 22, clrDarkRed);

   ChartRedraw(0);
}

//=================================================================
//  OnInit
//=================================================================
int OnInit()
{
   Print("========================================================");
   Print("  ", VERSION_STR, " - RECOVERY + LBC MICRO-GRID");
   Print("  SL=0 en TODAS las ordenes (broker no cierra auto)");
   Print("  LBC activa cuando no hay margen para recovery normal");
   Print("  Unico cierre: PnL neto >= $", Inp_BlockTPTarget);
   Print("  LBC: Max ", Inp_LBCMaxPairs, " pares | Grid=",
         Inp_LBCGridATR, " x ATR | Harvest=", Inp_LBCHarvestATR, " x ATR");
   Print("========================================================");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);

   h_ATR     = iATR(_Symbol,  PERIOD_M1, Inp_ATRPeriod);
   h_EMAFast = iMA(_Symbol,   PERIOD_M1, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMASlow = iMA(_Symbol,   PERIOD_M1, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol,  PERIOD_M1, Inp_RSIPeriod, PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol, PERIOD_M1, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);

   if(h_ATR == INVALID_HANDLE || h_EMAFast == INVALID_HANDLE ||
      h_EMASlow == INVALID_HANDLE || h_RSI == INVALID_HANDLE ||
      h_MACD == INVALID_HANDLE) {
      Print("[V7.3] ERROR: Indicadores no iniciados correctamente");
      return INIT_FAILED;
   }
   h_ADX        = iADX(_Symbol, PERIOD_M1, Inp_ADXPeriod);
   h_HTFEMAFast = iMA(_Symbol, Inp_HTFTF, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_HTFEMASlow = iMA(_Symbol, Inp_HTFTF, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);

   for(int i = 0; i < MAX_RECORDS; i++) ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc);

   m_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance   = m_initialBalance;
   m_lastDailyReset = TimeCurrent();

   SyncPositions();
   // Verificar si habia LBC activo en posiciones existentes
   if(m_port.lbcCount > 0) {
      m_lbc.active      = true;
      m_lbc.activatedTime = TimeCurrent();
      m_lbc.maxOrdersCalc = Inp_LBCMaxPairs;
      Print("[V7.3] LBC: detectadas ", m_port.lbcCount, " posiciones LBC existentes");
   }

   if(Inp_ShowDashboard) { DeleteDash(); UpdateDash(); }

   Print("[V7.3] LISTO | Saldo=$", m_initialBalance,
         " | MargenPor0.01=$", NormalizeDouble(CalcMarginFor001(),2));
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[V7.3] DETENIDO | PnL=$", NormalizeDouble(m_totalPnL,2),
         " | Abiertas:", m_tradesOpened,
         " | Cerradas:", m_tradesClosed,
         " | Win%:", NormalizeDouble((m_totalWins+m_totalLosses > 0) ?
            (double)m_totalWins/(m_totalWins+m_totalLosses)*100 : 0, 1),
         " | LBC cosechado: $", NormalizeDouble(m_lbc.harvestedTotal,2));

   IndicatorRelease(h_ATR);
   IndicatorRelease(h_EMAFast);
   IndicatorRelease(h_EMASlow);
   IndicatorRelease(h_RSI);
   IndicatorRelease(h_MACD);
   if(h_ADX        != INVALID_HANDLE) IndicatorRelease(h_ADX);
   if(h_HTFEMAFast != INVALID_HANDLE) IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow != INVALID_HANDLE) IndicatorRelease(h_HTFEMASlow);
   if(Inp_ShowDashboard) DeleteDash();
}

//=================================================================
//  OnTick
//=================================================================
void OnTick()
{
   m_tickCount++;
   UpdateMarket();
   UpdateKalman();
   UpdatePortfolio();

   CheckEquityGuard();
   m_inSession = IsInMainSession();
   ResetDailyIfNeeded();
   bool dailyPaused = DailyLimitReached();

   // Pausa de ciclo
   if(m_cycleInPause) {
      if(TimeCurrent() - m_cycleResetTime >= Inp_CyclePauseSec) {
         m_cycleInPause   = false;
         m_recoveryActive = false;
         m_recoveryOrders = 0;
         DeactivateLBC();
      } else {
         UpdatePortfolio();
         if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget)
            CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard) UpdateDash();
         return;
      }
   }

   // Modo emergencia
   if(m_emergencyMode) {
      static datetime emgTime = 0;
      UpdatePortfolio();
      if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget) {
         CloseBlockIfPositive("Emergency_TP");
         m_emergencyMode = false; emgTime = 0;
      }
      if(m_port.totalPos == 0 && emgTime == 0) emgTime = TimeCurrent();
      if(emgTime > 0 && TimeCurrent() - emgTime >= Inp_EmergencyCooldown) {
         m_emergencyMode = false; emgTime = 0;
      }
      
      // FIX: Recovery sigue operando en emergencia para cubrir posiciones perdedoras
      RunRecoveryEngine();
      
      // En emergencia tambien corre el LBC (sigue cosechando)
      RunLBCEngine();
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   if(TimeCurrent() - m_lastCleanupTime > 5) {
      CleanupRecs(); SyncPositions();
      m_lastCleanupTime = TimeCurrent();
   }

   ManagePositions();

   // PRIORIDAD 1: Bloque positivo -> cerrar todo
   if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget) {
      CloseBlockIfPositive("BlockTP");
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // PRIORIDAD 2: Recovery matematico (puede activar LBC si no hay margen)
   RunRecoveryEngine();

   // PRIORIDAD 3: LBC Engine (se ejecuta si fue activado por Recovery)
   RunLBCEngine();

   // PRIORIDAD 4: Basket TP
   RunBasketTP();

   // PRIORIDAD 5: Cycle max loss (solo activa recovery)
   CheckCycleMaxLoss();

   // PRIORIDAD 6: Harvest (solo si bloque es positivo)
   RunHarvest();

   // PRIORIDAD 7: CT Engine (normal, solo si no hay recovery ni LBC)
   if(!m_isPaused && !m_recoveryActive && !m_lbc.active && !dailyPaused)
      RunCTEngine();

   if(Inp_ShowDashboard) UpdateDash();
}

//=================================================================
//  OnChartEvent
//=================================================================
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp)
{
   if(id == CHARTEVENT_OBJECT_CLICK) {
      if(sp == "D73_B1") {
         m_isPaused = !m_isPaused;
         if(!m_isPaused) {
            m_emergencyMode  = false;
            m_dailyLimitHit  = false;
            m_recoveryActive = false;
            m_recoveryOrders = 0;
            DeactivateLBC();
            Print("[V7.3] EA REANUDADO manualmente");
         } else {
            Print("[V7.3] EA PAUSADO manualmente");
         }
      }
      if(sp == "D73_B2") {
         Print("[V7.3] CIERRE MANUAL solicitado...");
         int closed = 0;
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
            if(ClosePos(t, "Manual")) closed++;
         }
         m_lastCTBuyPrice    = m_lastCTSellPrice = 0;
         m_consecutiveLosses = 0;
         m_lotMultiplier     = 1.0;
         m_cycleInPause      = false;
         m_recoveryActive    = false;
         m_recoveryOrders    = 0;
         m_lastPrimaryDir    = 0;
         m_lastPrimaryLost   = false;
         DeactivateLBC();
         Print("[V7.3] CIERRE MANUAL completo: ", closed, " posiciones cerradas");
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+