//+------------------------------------------------------------------+
//|   NEURALGO V7.7.1-OPT  "ZERO-SURRENDER ENGINE"                  |
//|                                                                  |
//| PARADIGMA: El EA NUNCA cierra un bloque con perdida neta.        |
//| La unica perdida aceptable es un Margin Call del broker.         |
//| El EA utiliza el 100% del balance disponible para sobrevivir     |
//| y conquistar cualquier movimiento del mercado.                   |
//|                                                                  |
//| CAMBIOS EN V7.7.1-OPT (sobre V7.7-PRO):                         |
//| [OPT-1] PARAMETROS RESINTONIZADOS PARA XAUUSD M1 PEPPERSTONE:   |
//|   - HedgeLockTrigger: -2.50 → -2.00 (hedge antes del daño)      |
//|   - RecoveryTriggerUSD: -1.50 → -1.20 (recovery mas temprano)   |
//|   - RecoveryMinDistATR: 3.0 → 2.5 (grid mas adaptado al ATR M1) |
//|   - RecoveryMoveATR: 0.5 → 0.7 (mayor swing esperado en Oro)    |
//|   - RecoveryMinLotMult: 1.2 → 1.3 (recuperacion levemente mas   |
//|     agresiva para cubrir comisiones Razor)                       |
//|   - CTDistanceATR: 2.0 → 1.8 (CT grid adaptado al ATR M1 Oro)   |
//|   - ThirdOrderConfirmTicks: 5 → 8 (mas confirmacion requerida)   |
//|   - TEMAFastPeriod: 8 → 6 (mas reactivo en M1)                  |
//|   - TEMASlowPeriod: 21 → 15 (tendencia media M1 ajustada)        |
//|   - PrimaryCooldownSec: 60 → 45 (reentrada levemente mas agil)   |
//|   - LotMaximum: 0.03 → 0.05 (mayor poder de recovery)           |
//|   - PostMBMaxCT: 2 → 3 (un CT extra post-mini-block)             |
//| [OPT-2] TRAILING STOP PRIMARIO (NUEVO — NO AFECTA BLOQUE):       |
//|   - Activo SOLO cuando hay 1 posicion abierta Y es Primary.      |
//|   - Si hay MAS posiciones abiertas: INACTIVO (rige cierre bloque) |
//|   - Distancia del trail: $0.50 USD desde el pico de profit.      |
//|   - Se activa cuando el profit alcanza Inp_PrimaryTrailActivation.|
//|   - Funcion RunPrimaryTrailing() en OnTick, Prioridad 0.5.       |
//|                                                                  |
//| INVARIANTES HEREDADOS DE V7.6C / V7.7-PRO:                      |
//|   - SL = 0 en TODAS las ordenes                                  |
//|   - TP individual = 0                                            |
//|   - CalcRecoveryLot:   INTOCABLE                                 |
//|   - DeactivateLBC:     INTOCABLE                                 |
//|   - Magic Number por defecto: 1212                               |
//+------------------------------------------------------------------+
#property copyright "NeurAlgo V7.7.1-OPT - Zero-Surrender Engine"
#property version   "7.71"
#property strict
#property description "XAUUSD 24/7 | V7.7.1-OPT | Zero-Surrender | TEMA+Kalman | Hedge Lock | Primary Trail"

#define VERSION_STR        "NEURALGO_V7.7.1-OPT"
#define MAX_RECORDS        120
#define HEDGE_TRIGGER_USD  (-2.00)
#define HEDGE_CAP_USD      (-15.00)
#define MINI_BLOCK_BUFFER  (0.50)
#define KALMAN_Q           (0.0001)
#define KALMAN_R           (0.005)
#define TEMA_FAST          6
#define TEMA_SLOW          15
#define LOT_SCALE_THRESHOLD 200.0

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

//=================================================================
//  ENUMERACIONES
//=================================================================
enum ENUM_CT_MODE       { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };
enum ENUM_RECOVERY_MODE { REC_CLASSIC=0, REC_TREND_HEDGE=1, REC_MINI_BLOCK=2 };

//=================================================================
//  PARAMETROS DE ENTRADA (OPTIMIZADOS V7.7.1 XAUUSD M1 $140)
//=================================================================
input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic               = 1212;
input int    Inp_MaxPositionsTotal   = 10;
input double Inp_LotBase             = 0.01;
// OPT: Ampliado a 0.05 para dar mas potencia de recovery en Oro
input double Inp_LotMaximum          = 0.05;
input double Inp_RiskPerTradePct     = 0.01;
input bool   Inp_UseDynamicLot       = true;
input double Inp_CTMinBalanceUSD     = 20.0;
input double Inp_MinFreeMarginPct    = 0.05;

input group "=== CIERRE DEL BLOQUE ==="
input double Inp_BlockTPTarget       = 1.50;
input double Inp_TP_ATR              = 2.5;
input double Inp_SL_ATR              = 1.2;

input group "=== [V7.7] DRAWDOWN LOCK - HEDGE INMEDIATO ==="
// OPT: -2.00 en lugar de -2.50 — hedge mas temprano, menos daño acumulado
input double Inp_HedgeLockTrigger    = -2.00;
input double Inp_HedgeCapUSD         = -15.00;
input int    Inp_HedgeLockIntervalSec= 3;

input group "=== [V7.7] 3ER ORDEN - DOBLE CONFIRMACION TEMA+KALMAN ==="
// OPT: Periodos mas cortos para mayor reactividad en M1 Oro
input int    Inp_TEMAFastPeriod      = 6;
input int    Inp_TEMASlowPeriod      = 15;
input double Inp_KalmanQ             = 0.0001;
input double Inp_KalmanR             = 0.005;
// OPT: 8 ticks en lugar de 5 — evita falsos breakouts en Oro volátil
input int    Inp_ThirdOrderConfirmTicks = 8;
input double Inp_ThirdOrderLotMult   = 1.4;

input group "=== [V7.7] MINI-BLOCK PARTIAL NETTING ==="
input double Inp_MiniBlockBuffer     = 0.50;
input int    Inp_MiniBlockIntervalSec= 10;
input double Inp_MiniBlockMarginThreshold = 15.0;

input group "=== [V7.7] POST MINI-BLOCK COUNTER TRADE ==="
input double Inp_PostMBCTDistMult    = 0.50;
// OPT: 3 en lugar de 2 — un CT extra para cubrir mejor la perdida restante
input int    Inp_PostMBMaxCT         = 3;

input group "=== [V7.7] AUTO-SCALING DE LOTE ==="
input double Inp_ScaleBalance1       = 200.0;
input double Inp_ScaleBalance2       = 400.0;
input double Inp_ScaleBalance3       = 700.0;

input group "=== RECOVERY ENGINE ==="
// OPT: -1.20 en lugar de -1.50 — recovery actua antes en Oro
input double Inp_RecoveryTriggerUSD  = -1.20;
// OPT: 2.5 ATR de distancia minima entre ordenes recovery (era 3.0)
// Con ATR M1 Oro ~0.5, esto da ~1.25 puntos de separacion real
// Suficiente para que el precio respire sin apilar ordenes
input double Inp_RecoveryMinDistATR  = 2.5;
// OPT: 0.7 — el Oro tiene swings mas amplios que otros activos en M1
input double Inp_RecoveryMoveATR     = 0.7;
// OPT: 1.3 en lugar de 1.2 — martingala ligeramente mas firme para cubrir
// las comisiones Razor (aprox $0.007 por 0.01 lot en XAUUSD)
input double Inp_RecoveryMinLotMult  = 1.3;
input int    Inp_RecoveryMaxOrders   = 3;
input int    Inp_RecoveryIntervalSec = 10;

input group "=== LBC: CONTINGENCIA BALANCE BAJO ==="
input int    Inp_LBCMaxPairs         = 4;
input double Inp_LBCGridATR          = 0.30;
input double Inp_LBCHarvestATR       = 0.15;
input int    Inp_LBCIntervalSec      = 3;
input double Inp_LBCMarginPct        = 0.55;

input group "=== COUNTER-TRADE ENGINE ==="
input ENUM_CT_MODE Inp_CTMode        = CT_ATR_DISTANCE;
// OPT: 1.8 ATR en lugar de 2.0 — grid CT levemente mas ajustado al Oro M1
input double Inp_CTDistanceATR       = 1.8;
input int    Inp_CTFixedPoints       = 100;
input int    Inp_CTIntervalSec       = 10;
input int    Inp_CTMaxSameDir        = 4;
// OPT: 45 seg en lugar de 60 — reentrada primaria levemente mas agil
input int    Inp_PrimaryCooldownSec  = 45;
input double Inp_CTMaxSpreadPoints   = 60.0;

input group "=== BASKET TP ==="
input bool   Inp_UseBasketTP         = true;
input double Inp_BasketTPFactor      = 0.60;
input double Inp_BasketTPRatio       = 1.5;
input int    Inp_BasketCheckSec      = 3;

input group "=== HARVEST ==="
input double Inp_HarvestMinUSD       = 0.50;
input double Inp_HarvestATRMult      = 0.20;
input bool   Inp_HarvestContinuous   = true;
input int    Inp_HarvestIntervalSec  = 3;

input group "=== ADX ==="
input bool   Inp_UseADX              = true;
input int    Inp_ADXPeriod           = 14;
input double Inp_ADXTrendLevel       = 25.0;
input bool   Inp_UseHTF              = true;
input ENUM_TIMEFRAMES Inp_HTFTF      = PERIOD_M5;

input group "=== EQUITY GUARD (solo informa, no pausa) ==="
input bool   Inp_UseEquityGuard      = true;
input double Inp_EmergencyLossUSD    = -120.0;
input double Inp_MaxDrawdownPct      = 0.90;

input group "=== INDICADORES BASE ==="
input int    Inp_ATRPeriod           = 14;
input int    Inp_EMAFast             = 21;
input int    Inp_EMASlow             = 55;
input int    Inp_RSIPeriod           = 7;
input int    Inp_MACDFast            = 12;
input int    Inp_MACDSlow            = 26;
input int    Inp_MACDSig             = 9;

input group "=== RESCATE UNIVERSAL ==="
input bool   Inp_RescueAllTrades     = true;

input group "=== SENSOR GMT (solo info, no bloquea) ==="
input int    Inp_UserGMT             = -5;
input int    Inp_BrokerGMT           = 2;
input string Inp_StartTime           = "07:30";
input string Inp_EndTime             = "15:00";

input group "=== CONTROL VISUAL ==="
input int    Inp_MaxSpread           = 80;
input bool   Inp_ShowDashboard       = true;
input int    Inp_DashX               = 12;
input int    Inp_DashY               = 28;

// *** NUEVO EN V7.7.1-OPT ***
input group "=== TRAILING STOP (SOLO POSICION PRIMARIA SOLA) ==="
// Activar trailing unicamente cuando haya 1 posicion y sea Primary
input bool   Inp_PrimaryTrailEnable      = true;
// Profit minimo para activar el trailing (el trail NO actua antes)
// $0.50 = la posicion debe estar al menos $0.50 en ganancia
input double Inp_PrimaryTrailActivation  = 0.50;
// Distancia del trailing desde el pico de profit
// Si peak=$1.20 y trail=$0.50 → cierra si profit baja a $0.70
input double Inp_PrimaryTrailDist        = 0.50;
// Intervalo minimo entre verificaciones del trailing (segundos)
input int    Inp_PrimaryTrailIntervalSec = 2;

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
   bool     isHedgeLock;
   bool     isThirdOrder;
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
   ulong  bestTicket;
   double bestProfit;
   int    ctCount;
   int    recoveryCount;
   int    lbcCount;
   int    hedgeLockCount;
   double currentDD;
   double blockVWAP;
   int    blockDir;
   int    rescueCount;
   double rescueProfit;
   double buyVolume;
   double sellVolume;
};

struct MarketSnap {
   double bid, ask, atr, emaFast, emaSlow, rsi, macdMain, macdSig, adx, spread;
   int    htfTrend;
   bool   isBullish, isBearish;
   double ema200;
   double atrSlow;
   double temaFast;
   double temaSlow;
   double kalmanPrice;
   double kalmanTrend;
   bool   temaAlignBull;
   bool   kalmanAlignBull;
   bool   dualConfirmBull;
   bool   dualConfirmBear;
   bool   stormActive;
   double atrRatio;
};

struct LBCState {
   bool     active;
   int      buyCount, sellCount;
   double   lastBuyPrice, lastSellPrice;
   datetime lastOrderTime;
   double   harvestedTotal;
   int      harvestCount;
   int      maxOrdersCalc;
   datetime activatedTime;
};

struct KalmanState {
   double x;
   double p;
   double v;
   double pv;
   bool   init;
};

struct TEMAState {
   double ema1;
   double ema2;
   double ema3;
   double tema;
   bool   init;
};

struct HedgeLockState {
   ulong  primaryTicket;
   ulong  hedgeTicket;
   double lockPnL;
   bool   active;
};

struct MiniBlockState {
   bool     active;
   datetime lastAttemptTime;
   int      iterationCount;
   double   totalNetted;
};

//=================================================================
//  HANDLES DE INDICADORES
//=================================================================
int h_ATR        = INVALID_HANDLE;
int h_EMAFast    = INVALID_HANDLE;
int h_EMASlow    = INVALID_HANDLE;
int h_RSI        = INVALID_HANDLE;
int h_MACD       = INVALID_HANDLE;
int h_ADX        = INVALID_HANDLE;
int h_HTFEMAFast = INVALID_HANDLE;
int h_HTFEMASlow = INVALID_HANDLE;
int h_ATRSlow    = INVALID_HANDLE;
int h_EMA200     = INVALID_HANDLE;

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade      m_trade;
PosRecord   m_rec[MAX_RECORDS];
Portfolio   m_port;
MarketSnap  m_mkt;
LBCState    m_lbc;

KalmanState  m_kalmanFast;
TEMAState    m_temaFast;
TEMAState    m_temaSlow;
MiniBlockState m_miniBlock;

HedgeLockState m_hedgeLocks[MAX_RECORDS];
int            m_hedgeLockCount = 0;

int      m_thirdOrderBullTicks  = 0;
int      m_thirdOrderBearTicks  = 0;
bool     m_thirdOrderReady      = false;
ENUM_ORDER_TYPE m_thirdOrderDir = ORDER_TYPE_BUY;

bool     m_postMiniBlockActive   = false;
int      m_postMiniBlockCTCount  = 0;

double   m_initialBalance    = 0;
double   m_bestEquity        = 0;
double   m_lotBaseEffective  = 0;
bool     m_isPaused          = false;
bool     m_emergencyMode     = false;
bool     m_inSession         = true;
bool     m_recoveryActive    = false;
int      m_recoveryOrders    = 0;
ENUM_RECOVERY_MODE m_recoveryMode = REC_CLASSIC;

datetime m_lastHedgeLockTime    = 0;
datetime m_lastRecoveryTime     = 0;
datetime m_lastCTTime           = 0;
datetime m_lastBasketCheck      = 0;
datetime m_lastHarvestTime      = 0;
datetime m_lastDashTime         = 0;
datetime m_lastCleanupTime      = 0;
datetime m_lastMiniBlockTime    = 0;
datetime m_lastPrimaryTime      = 0;
// V7.7.1: Timer para trailing stop primario
datetime m_lastTrailTime        = 0;

double   m_lastCTBuyPrice    = 0;
double   m_lastCTSellPrice   = 0;

double   m_totalPnL          = 0;
int      m_tradesOpened      = 0;
int      m_tradesClosed      = 0;
double   m_bestClosed        = 0;
double   m_worstClosed       = 0;
int      m_totalWins         = 0;
int      m_totalLosses       = 0;
double   m_sumWins           = 0;
double   m_sumLosses         = 0;

double   m_losingPosOpenPrice = 0;
int      m_losingPosType      = -1;
int      m_lastPrimaryDir     = 0;
bool     m_lastPrimaryLost    = false;

long     m_tickCount         = 0;
bool     m_isProcessing      = false;

double   m_cycleWinsSum      = 0;
int      m_cycleWinsCount    = 0;
bool     m_cycleInPause      = false;
datetime m_cycleResetTime    = 0;
int      m_consecutiveLosses = 0;
double   m_lotMultiplier     = 1.0;

bool     m_stormActive        = false;
datetime m_stormDetectedTime  = 0;

//=================================================================
//  HELPERS BASICOS
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
   if(h_ATR != INVALID_HANDLE && CopyBuffer(h_ATR, 0, 1, 1, b) == 1) return b[0];
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
   return (SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) <= Inp_MaxSpread);
}

bool MarginOK(double lot, ENUM_ORDER_TYPE type, double pctUsable = 0.85)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_CTMinBalanceUSD) return false;
   if(free < 0.50) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg)) {
      if(marg <= 0) return false;
      return (marg <= free * pctUsable);
   }
   return false;
}

bool MarginOK_Hedge(double lot, ENUM_ORDER_TYPE type)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free < 0.50) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg)) {
      if(marg <= 0) return false;
      return (marg <= free * 0.95);
   }
   return false;
}

double CalcMarginFor001()
{
   double marg = 0;
   MqlTick t; GetTick(t);
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 0.01, t.ask, marg)) return 9.40;
   return (marg > 0) ? marg : 9.40;
}

double ProfitPerLotPerPoint()
{
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv <= 0 || ts <= 0) return 1.0;
   return tv / ts;
}

//=================================================================
//  V7.7: AUTO-SCALING DE LOTE BASE
//=================================================================
double GetEffectiveLotBase()
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal >= Inp_ScaleBalance3) return NormLot(0.05);
   if(bal >= Inp_ScaleBalance2) return NormLot(0.03);
   if(bal >= Inp_ScaleBalance1) return NormLot(0.02);
   return NormLot(Inp_LotBase);
}

//=================================================================
//  V7.7: TEMA — Triple Exponential Moving Average (Zero-Lag)
//  Formula: TEMA = 3*EMA1 - 3*EMA2 + EMA3
//  Referencia: Patrick Mulloy (1994), TASC.
//=================================================================
double CalcEMAStep(double prevEMA, double price, int period)
{
   double k = 2.0 / (period + 1.0);
   return price * k + prevEMA * (1.0 - k);
}

void UpdateTEMA(TEMAState &state, double price, int period)
{
   if(!state.init) {
      state.ema1 = price;
      state.ema2 = price;
      state.ema3 = price;
      state.tema  = price;
      state.init  = true;
      return;
   }
   state.ema1 = CalcEMAStep(state.ema1, price, period);
   state.ema2 = CalcEMAStep(state.ema2, state.ema1, period);
   state.ema3 = CalcEMAStep(state.ema3, state.ema2, period);
   state.tema  = 3.0 * state.ema1 - 3.0 * state.ema2 + state.ema3;
}

//=================================================================
//  V7.7: KALMAN ADAPTATIVO SOBRE PRICE ACTION
//=================================================================
void UpdateKalmanAdaptive(KalmanState &state, double measurement)
{
   if(!state.init) {
      state.x  = measurement;
      state.p  = 1.0;
      state.v  = 0.0;
      state.pv = 1.0;
      state.init = true;
      return;
   }
   double x_prev  = state.x;
   double x_pred  = state.x + state.v;
   double p_pred  = state.p  + Inp_KalmanQ;

   double innov   = measurement - x_pred;
   double adaptQ  = Inp_KalmanQ * (1.0 + MathAbs(innov) * 10.0);
   p_pred         = state.p + adaptQ;

   double K       = p_pred / (p_pred + Inp_KalmanR);
   state.x        = x_pred + K * innov;
   state.p        = (1.0 - K) * p_pred;
   state.v        = state.x - x_prev;
}

//=================================================================
//  V7.7: ACTUALIZACION DE INDICADORES TEMA Y KALMAN
//=================================================================
void UpdateZeroLagIndicators()
{
   MqlTick tk; if(!GetTick(tk)) return;
   double mid = (tk.bid + tk.ask) / 2.0;

   UpdateTEMA(m_temaFast, mid, Inp_TEMAFastPeriod);
   UpdateTEMA(m_temaSlow, mid, Inp_TEMASlowPeriod);
   UpdateKalmanAdaptive(m_kalmanFast, mid);

   if(m_temaFast.init && m_temaSlow.init) {
      m_mkt.temaFast     = m_temaFast.tema;
      m_mkt.temaSlow     = m_temaSlow.tema;
      m_mkt.temaAlignBull = (m_temaFast.tema > m_temaSlow.tema * 1.000005);
   }

   if(m_kalmanFast.init) {
      m_mkt.kalmanPrice    = m_kalmanFast.x;
      m_mkt.kalmanTrend    = m_kalmanFast.v;
      m_mkt.kalmanAlignBull = (m_kalmanFast.v > 0);
   }

   m_mkt.dualConfirmBull = (m_mkt.temaAlignBull  && m_mkt.kalmanAlignBull);
   m_mkt.dualConfirmBear = (!m_mkt.temaAlignBull && !m_mkt.kalmanAlignBull);
}

//=================================================================
//  V7.7: CONTADORES DE CONFIRMACION PARA 3ER ORDEN
//=================================================================
void UpdateThirdOrderConfirmation()
{
   if(m_mkt.dualConfirmBull) {
      m_thirdOrderBullTicks++;
      m_thirdOrderBearTicks = 0;
   } else if(m_mkt.dualConfirmBear) {
      m_thirdOrderBearTicks++;
      m_thirdOrderBullTicks = 0;
   } else {
      m_thirdOrderBullTicks = 0;
      m_thirdOrderBearTicks = 0;
   }

   m_thirdOrderReady = false;
   if(m_thirdOrderBullTicks >= Inp_ThirdOrderConfirmTicks) {
      m_thirdOrderReady = true;
      m_thirdOrderDir   = ORDER_TYPE_BUY;
   } else if(m_thirdOrderBearTicks >= Inp_ThirdOrderConfirmTicks) {
      m_thirdOrderReady = true;
      m_thirdOrderDir   = ORDER_TYPE_SELL;
   }
}

//=================================================================
//  V7.7: STORM FILTER (solo para timing del 3er orden)
//=================================================================
bool IsStormActiveForThirdOrder()
{
   if(m_mkt.atr <= 0) return false;

   double buf[];
   ArraySetAsSeries(buf, true);
   double atrAvg = 0;
   if(h_ATR != INVALID_HANDLE && CopyBuffer(h_ATR, 0, 1, 20, buf) == 20) {
      for(int i = 0; i < 20; i++) atrAvg += buf[i];
      atrAvg /= 20.0;
   }
   if(atrAvg <= 0) return false;

   double atrRatio = m_mkt.atr / atrAvg;
   m_mkt.atrRatio  = atrRatio;
   m_mkt.stormActive = (atrRatio >= 2.0);

   if(m_mkt.stormActive && !m_stormActive) {
      m_stormActive        = true;
      m_stormDetectedTime = TimeCurrent();
   } else if(!m_mkt.stormActive && m_stormActive) {
      if(TimeCurrent() - m_stormDetectedTime >= 60) {
         m_stormActive = false;
      }
   }

   return m_stormActive;
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
             bool isRecovery=false, bool isLBC=false,
             bool isHedgeLock=false, bool isThirdOrder=false)
{
   if(idx < 0 || idx >= MAX_RECORDS) return;
   ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket       = ticket;
   m_rec[idx].posType      = posType;
   m_rec[idx].openPrice    = openPrice;
   m_rec[idx].volume       = vol;
   m_rec[idx].openTime     = TimeCurrent();
   m_rec[idx].comment      = comment;
   m_rec[idx].isPrimary    = isPrimary;
   m_rec[idx].isCounter    = isCounter;
   m_rec[idx].isRecovery   = isRecovery;
   m_rec[idx].isLBC        = isLBC;
   m_rec[idx].isHedgeLock  = isHedgeLock;
   m_rec[idx].isThirdOrder = isThirdOrder;
   m_rec[idx].kP           = 1.0;
   m_rec[idx].kK           = 1.0;
}

void CleanupRecs()
{
   for(int i = 0; i < MAX_RECORDS; i++) {
      if(m_rec[i].ticket == 0) continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)) {
         double pnl = m_rec[i].netProfit;
         if(pnl != 0) {
            m_totalPnL += pnl; m_tradesClosed++;
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
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long magic  = PositionGetInteger(POSITION_MAGIC);
      bool isOwn  = (magic == Inp_Magic);
      bool isExt  = (!isOwn && Inp_RescueAllTrades);
      if(!isOwn && !isExt) continue;

      if(FindRec(t) >= 0) continue;
      int idx = FreeRec(); if(idx < 0) continue;

      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      string comm = PositionGetString(POSITION_COMMENT);

      bool isPri   = (StringFind(comm, "Primary")   >= 0);
      bool isCT    = (StringFind(comm, "CT_")        >= 0);
      bool isRec   = (StringFind(comm, "REC_")       >= 0);
      bool isLBC   = (StringFind(comm, "LBC_")       >= 0);
      bool isHL    = (StringFind(comm, "HL_")        >= 0);
      bool isTh    = (StringFind(comm, "T3_")        >= 0);

      InitRec(idx, t, pt, op, vol, comm, isPri, isCT, isRec, isLBC, isHL, isTh);

      if(isRec) { m_recoveryActive = true; m_recoveryOrders++; }
   }
}

//=================================================================
//  KALMAN POR POSICION (suavizado de PnL)
//=================================================================
void KalmanUpdatePos(int idx, double meas)
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

void UpdateKalmanPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int idx = FindRec(t); if(idx < 0) continue;
      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit = pf;
      if(pf > m_rec[idx].peakProfit) m_rec[idx].peakProfit = pf;
      KalmanUpdatePos(idx, pf);
   }
}

//=================================================================
//  V7.7: UpdateMarket
//=================================================================
void UpdateMarket()
{
   MqlTick t; if(!GetTick(t)) return;
   m_mkt.bid    = t.bid;
   m_mkt.ask    = t.ask;
   m_mkt.spread = (t.ask - t.bid) / _Point;
   m_mkt.atr    = GetATR();

   double f[1], s[1], r[1], m[1], sg[1];
   if(h_EMAFast != INVALID_HANDLE && CopyBuffer(h_EMAFast, 0, 0, 1, f)  == 1) m_mkt.emaFast  = f[0];
   if(h_EMASlow != INVALID_HANDLE && CopyBuffer(h_EMASlow, 0, 0, 1, s)  == 1) m_mkt.emaSlow  = s[0];
   if(h_RSI     != INVALID_HANDLE && CopyBuffer(h_RSI,     0, 0, 1, r)  == 1) m_mkt.rsi      = r[0];
   if(h_MACD    != INVALID_HANDLE && CopyBuffer(h_MACD,    0, 0, 1, m)  == 1) m_mkt.macdMain = m[0];
   if(h_MACD    != INVALID_HANDLE && CopyBuffer(h_MACD,    1, 0, 1, sg) == 1) m_mkt.macdSig  = sg[0];
   if(h_ADX     != INVALID_HANDLE) {
      double adxB[1];
      if(CopyBuffer(h_ADX, 0, 0, 1, adxB) == 1) m_mkt.adx = adxB[0];
   }
   if(h_HTFEMAFast != INVALID_HANDLE && h_HTFEMASlow != INVALID_HANDLE) {
      double hf[1], hs[1];
      if(CopyBuffer(h_HTFEMAFast, 0, 0, 1, hf) == 1 &&
         CopyBuffer(h_HTFEMASlow, 0, 0, 1, hs) == 1)
         m_mkt.htfTrend = (hf[0] > hs[0] * 1.0001) ? 1 : (hf[0] < hs[0] * 0.9999) ? -1 : 0;
   }
   if(h_EMA200  != INVALID_HANDLE) {
      double e200[1];
      if(CopyBuffer(h_EMA200, 0, 1, 1, e200) == 1) m_mkt.ema200 = e200[0];
   }
   if(h_ATRSlow != INVALID_HANDLE) {
      double atrS[1];
      if(CopyBuffer(h_ATRSlow, 0, 1, 1, atrS) == 1) m_mkt.atrSlow = atrS[0];
   }

   m_mkt.isBullish = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.rsi > 52 && m_mkt.macdMain > m_mkt.macdSig);
   m_mkt.isBearish = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.rsi < 48 && m_mkt.macdMain < m_mkt.macdSig);

   UpdateZeroLagIndicators();
   UpdateThirdOrderConfirmation();
   IsStormActiveForThirdOrder();
}

//=================================================================
//  V7.7: UpdatePortfolio
//=================================================================
void UpdatePortfolio()
{
   ZeroMemory(m_port);
   m_port.worstProfit  = 0;
   m_port.bestProfit   = 0;
   m_losingPosOpenPrice = 0;
   m_losingPosType     = -1;

   double vwapNumer = 0, vwapDenom = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   magic = PositionGetInteger(POSITION_MAGIC);
      bool   isOwn = (magic == Inp_Magic);
      bool   isExt = (!isOwn && Inp_RescueAllTrades);
      if(!isOwn && !isExt) continue;

      int    pt  = (int)PositionGetInteger(POSITION_TYPE);
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      string comm= PositionGetString(POSITION_COMMENT);

      m_port.totalPos++;
      m_port.totalProfit += pf;
      if(pf >= 0) m_port.positiveSum += pf;
      else        m_port.negativeSum  += MathAbs(pf);

      if(pt == POSITION_TYPE_BUY) { m_port.buyCount++;  m_port.buyProfit  += pf; m_port.buyVolume  += vol; }
      else                        { m_port.sellCount++; m_port.sellProfit += pf; m_port.sellVolume += vol; }

      vwapNumer += op * vol;
      vwapDenom += vol;
      m_port.blockDir += (pt == POSITION_TYPE_BUY) ? 1 : -1;

      if(pf < m_port.worstProfit) {
         m_port.worstProfit   = pf;
         m_port.worstTicket   = t;
         m_losingPosOpenPrice = op;
         m_losingPosType      = pt;
      }
      if(pf > m_port.bestProfit) {
         m_port.bestProfit  = pf;
         m_port.bestTicket  = t;
      }

      if(isOwn) {
         if(StringFind(comm, "CT_")  >= 0) m_port.ctCount++;
         if(StringFind(comm, "REC_") >= 0 ||
            StringFind(comm, "HL_")  >= 0 ||
            StringFind(comm, "T3_")  >= 0) m_port.recoveryCount++;
         if(StringFind(comm, "LBC_") >= 0) m_port.lbcCount++;
         if(StringFind(comm, "HL_")  >= 0) m_port.hedgeLockCount++;
      }
      if(isExt) { m_port.rescueCount++; m_port.rescueProfit += pf; }
   }

   if(vwapDenom > 0) m_port.blockVWAP = vwapNumer / vwapDenom;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > m_bestEquity) m_bestEquity = eq;
   m_port.currentDD = (m_bestEquity > 0) ? (m_bestEquity - eq) / m_bestEquity : 0;
}

//=================================================================
//  CIERRE — ClosePos preservado
//=================================================================
bool ClosePos(ulong ticket, string reason = "")
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   int retries = 3;
   bool ok = false;
   while(retries-- > 0) {
      ok = m_trade.PositionClose(ticket);
      if(ok) break;
      int ret = (int)m_trade.ResultRetcode();
      if(ret == TRADE_RETCODE_CONNECTION || ret == TRADE_RETCODE_TIMEOUT) {
         Sleep(200);
         continue;
      }
      break;
   }

   if(!ok) {
      Print("[AQ V7.7.1] ERR cierre #", ticket, ": ", m_trade.ResultRetcodeDescription());
      return false;
   }

   if(pf > 0) { m_cycleWinsSum += pf; m_cycleWinsCount++; m_totalWins++;   m_sumWins   += pf; }
   else        { m_totalLosses++;      m_sumLosses += MathAbs(pf); }
   m_totalPnL += pf; m_tradesClosed++;
   if(pf > m_bestClosed)  m_bestClosed  = pf;
   if(pf < m_worstClosed) m_worstClosed = pf;

   int idx = FindRec(ticket);
   if(idx >= 0) {
      if(m_rec[idx].isPrimary) m_lastPrimaryLost = (pf < 0);
      if(m_rec[idx].isLBC) {
         string comm = m_rec[idx].comment;
         if(StringFind(comm, "LBC_B") >= 0 && m_lbc.buyCount > 0)  m_lbc.buyCount--;
         if(StringFind(comm, "LBC_S") >= 0 && m_lbc.sellCount > 0) m_lbc.sellCount--;
         if(pf > 0) { m_lbc.harvestedTotal += pf; m_lbc.harvestCount++; }
      }
      Print("[AQ V7.7.1] CERRADA #", ticket, " $", NormalizeDouble(pf,2),
            (reason != "" ? " [" + reason + "]" : ""));
      ZeroMemory(m_rec[idx]);
   }
   return true;
}

bool CloseRescuePos(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   bool ok = false;
   int retries = 3;
   while(retries-- > 0) {
      ok = m_trade.PositionClose(ticket);
      if(ok) break;
      int ret = (int)m_trade.ResultRetcode();
      if(ret == TRADE_RETCODE_CONNECTION || ret == TRADE_RETCODE_TIMEOUT) { Sleep(200); continue; }
      break;
   }
   if(ok) {
      m_totalPnL += pf; m_tradesClosed++;
      Print("[AQ V7.7.1] RESCATE CERRADA #", ticket, " $", NormalizeDouble(pf,2), " [", reason, "]");
   }
   return ok;
}

bool CloseBlockIfPositive(string reason)
{
   if(m_port.totalProfit < Inp_BlockTPTarget) return false;
   Print("[AQ V7.7.1] CIERRE POSITIVO: PnL=$", NormalizeDouble(m_port.totalProfit,2), " [", reason, "]");
   m_isProcessing = true;

   for(int pass = 0; pass < 2; pass++) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
         double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(pass == 0 && pf <  0) continue;
         if(pass == 1 && pf >= 0) continue;
         ClosePos(t, reason);
      }
   }

   if(Inp_RescueAllTrades) {
      for(int pass = 0; pass < 2; pass++) {
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) == Inp_Magic) continue;
            double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            if(pass == 0 && pf <  0) continue;
            if(pass == 1 && pf >= 0) continue;
            CloseRescuePos(t, "RESCUE_" + reason);
         }
      }
   }

   m_isProcessing          = false;
   m_recoveryActive        = false;
   m_recoveryOrders        = 0;
   m_hedgeLockCount        = 0;
   m_thirdOrderBullTicks   = 0;
   m_thirdOrderBearTicks   = 0;
   m_thirdOrderReady       = false;
   m_cycleResetTime        = TimeCurrent();
   m_cycleInPause          = true;
   m_lastCTBuyPrice        = m_lastCTSellPrice = 0;
   m_postMiniBlockActive   = false;
   m_postMiniBlockCTCount  = 0;
   ZeroMemory(m_lbc);
   for(int i = 0; i < MAX_RECORDS; i++) ZeroMemory(m_hedgeLocks[i]);
   return true;
}

//=================================================================
//  LOTES
//=================================================================
double CalcLot(int level = 0)
{
   m_lotBaseEffective = GetEffectiveLotBase();
   if(!Inp_UseDynamicLot || m_mkt.atr <= 0)
      return NormLot(m_lotBaseEffective * m_lotMultiplier);

   double bal     = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskUSD = bal * Inp_RiskPerTradePct;
   double slDist  = m_mkt.atr * Inp_SL_ATR;
   double tv = GetTickVal(), ts = GetTickSize();
   double lot = m_lotBaseEffective;
   if(tv > 0 && ts > 0 && slDist > 0) {
      double pipV = tv / ts;
      if(pipV > 0) lot = riskUSD / (slDist * pipV);
   }
   return NormLot(MathMax(lot, m_lotBaseEffective) * m_lotMultiplier);
}

// INTOCABLE: CalcRecoveryLot
double CalcRecoveryLot()
{
   double atr = m_mkt.atr;
   if(atr <= 0) return NormLot(m_lotBaseEffective * Inp_RecoveryMinLotMult);

   double blockLoss    = MathAbs(m_port.totalProfit);
   double totalNeeded  = blockLoss + Inp_BlockTPTarget;
   double moveDist     = atr * Inp_RecoveryMoveATR;
   if(moveDist <= 0) moveDist = atr * 0.5;

   double tv = GetTickVal(), ts = GetTickSize();
   double profitPer1LotPerDist = 0;
   if(tv > 0 && ts > 0)
      profitPer1LotPerDist = (moveDist / ts) * tv;

   double calcLot = m_lotBaseEffective;
   if(profitPer1LotPerDist > 0)
      calcLot = totalNeeded / profitPer1LotPerDist;

   double loserLot = m_lotBaseEffective;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(MathAbs(pf - m_port.worstProfit) < 0.001) { loserLot = vol; break; }
   }

   double minRecLot = loserLot * Inp_RecoveryMinLotMult;
   double finalLot  = MathMax(calcLot, minRecLot);

   double freeMarg = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margPer001 = CalcMarginFor001();
   double maxLotAllowed = (freeMarg / margPer001) * 0.01 * 0.40;

   finalLot = MathMin(finalLot, maxLotAllowed);

   return NormLot(finalLot);
}

//=================================================================
//  APERTURA — OpenOrder con retry de red y SL=0, TP=0
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type, double lot, string comment, bool forceOpen = false)
{
   if(m_isPaused && !forceOpen) return 0;

   int posLimit = forceOpen ? (Inp_MaxPositionsTotal + 10) : Inp_MaxPositionsTotal;
   if(PositionsTotal() >= posLimit) return 0;

   lot = NormLot(lot);
   if(lot <= 0) return 0;

   bool margOK = forceOpen ? MarginOK_Hedge(lot, type) : MarginOK(lot, type);
   if(!margOK) return 0;

   MqlTick t; if(!GetTick(t)) return 0;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;

   int retries = 3;
   bool ok = false;
   while(retries-- > 0) {
      ok = (type == ORDER_TYPE_BUY)
         ? m_trade.Buy( lot, _Symbol, price, 0, 0, comment)
         : m_trade.Sell(lot, _Symbol, price, 0, 0, comment);
      if(ok) break;
      int ret = (int)m_trade.ResultRetcode();
      if(ret == TRADE_RETCODE_CONNECTION || ret == TRADE_RETCODE_TIMEOUT ||
         ret == TRADE_RETCODE_REQUOTE) {
         Sleep(250);
         if(!GetTick(t)) continue;
         price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
         continue;
      }
      break;
   }

   if(!ok) {
      Print("[AQ V7.7.1] ERR apertura: ", m_trade.ResultRetcodeDescription(), " [", comment, "]");
      return 0;
   }

   ulong ticket = m_trade.ResultOrder();
   if(ticket > 0) {
      m_tradesOpened++;
      Print("[AQ V7.7.1] ABIERTA #", ticket, " ",
            (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot=", lot, " @ ", NormalizeDouble(price, _Digits),
            " SL=0 TP=0 [", comment, "]",
            (forceOpen ? " [FORCE]" : ""));
   }
   return ticket;
}

//=================================================================
//  V7.7.1-OPT — TRAILING STOP PRIMARIO (NUEVO)
//
//  ACTIVACION:
//    - Exactamente 1 posicion abierta (m_port.totalPos == 1)
//    - Esa posicion tiene isPrimary == true en su PosRecord
//    - El profit de esa posicion alcanzo Inp_PrimaryTrailActivation
//
//  LOGICA:
//    - Usa m_rec[idx].peakProfit (actualizado en UpdateKalmanPositions)
//    - Si pf <= peakProfit - Inp_PrimaryTrailDist → cerrar posicion
//    - No interfiere con CloseBlockIfPositive (que opera en bloque)
//    - No interfiere con ningun motor de recovery/hedge/CT
//
//  INVARIANTES RESPETADOS:
//    - SL = 0 siempre (la posicion nunca tiene SL; es cierre por logica)
//    - Solo llama a ClosePos (mismo mecanismo que todo el EA)
//    - Magic Number via Inp_Magic (verificado dentro de ClosePos)
//=================================================================
void RunPrimaryTrailing()
{
   if(!Inp_PrimaryTrailEnable) return;
   if(m_isProcessing) return;
   // Solo cuando hay exactamente 1 posicion abierta
   if(m_port.totalPos != 1) return;
   if(TimeCurrent() - m_lastTrailTime < Inp_PrimaryTrailIntervalSec) return;
   m_lastTrailTime = TimeCurrent();

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;

      int idx = FindRec(t);
      if(idx < 0) continue;
      // Solo la posicion primaria recibe trailing
      if(!m_rec[idx].isPrimary) continue;

      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      // Actualizar pico de profit
      if(pf > m_rec[idx].peakProfit) m_rec[idx].peakProfit = pf;

      // El trailing no actua hasta que el profit alcance el umbral de activacion
      if(m_rec[idx].peakProfit < Inp_PrimaryTrailActivation) break;

      // Nivel de cierre por trailing = pico - distancia configurada
      double trailLevel = m_rec[idx].peakProfit - Inp_PrimaryTrailDist;

      // Cerrar si el profit actual cayo al nivel de trailing
      if(pf <= trailLevel) {
         Print("[AQ V7.7.1] PRIMARY TRAIL: #", t,
               " | Peak=$", NormalizeDouble(m_rec[idx].peakProfit, 2),
               " | PF actual=$", NormalizeDouble(pf, 2),
               " | Nivel trail=$", NormalizeDouble(trailLevel, 2),
               " | Cerrando posicion primaria.");
         ClosePos(t, "PrimaryTrail");
         // Tras cerrar, resetear ciclo de pausa breve
         m_cycleInPause  = true;
         m_cycleResetTime = TimeCurrent();
      }
      break; // Solo habia 1 posicion; ya procesada
   }
}

//=================================================================
//  V7.7: DRAWDOWN LOCK — HEDGE INMEDIATO
//=================================================================
void RunDrawdownLock()
{
   if(m_isProcessing) return;
   if(m_port.totalPos == 0) return;
   if(TimeCurrent() - m_lastHedgeLockTime < Inp_HedgeLockIntervalSec) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      string comm = PositionGetString(POSITION_COMMENT);
      if(StringFind(comm, "HL_") >= 0) continue;

      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      int    pt  = (int)PositionGetInteger(POSITION_TYPE);

      bool alreadyHedged = false;
      for(int h = 0; h < MAX_RECORDS; h++) {
         if(m_hedgeLocks[h].active && m_hedgeLocks[h].primaryTicket == t) {
            alreadyHedged = true;
            break;
         }
      }
      if(alreadyHedged) continue;

      if(pf <= Inp_HedgeLockTrigger) {
         ENUM_ORDER_TYPE hedgeType = (pt == POSITION_TYPE_BUY)
            ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

         string hlComm = "HL_" + (hedgeType == ORDER_TYPE_BUY ? "B" : "S") +
                         "_" + IntegerToString((int)t);
         m_isProcessing = true;
         ulong hTicket  = OpenOrder(hedgeType, vol, hlComm, true);
         m_isProcessing = false;

         if(hTicket > 0) {
            for(int h = 0; h < MAX_RECORDS; h++) {
               if(!m_hedgeLocks[h].active) {
                  m_hedgeLocks[h].primaryTicket = t;
                  m_hedgeLocks[h].hedgeTicket   = hTicket;
                  m_hedgeLocks[h].lockPnL       = pf;
                  m_hedgeLocks[h].active         = true;
                  m_hedgeLockCount++;
                  break;
               }
            }
            int idx = FreeRec();
            if(idx >= 0) {
               MqlTick tk; GetTick(tk);
               int    hpt = (hedgeType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
               double op  = (hedgeType == ORDER_TYPE_BUY) ? tk.ask : tk.bid;
               InitRec(idx, hTicket, hpt, op, vol, hlComm, false, false, true, false, true, false);
            }
            m_lastHedgeLockTime = TimeCurrent();
            Print("[AQ V7.7.1] HEDGE LOCK: #", hTicket, " contra #", t,
                  " | PnL=$", NormalizeDouble(pf,2), " | Lot=", vol);
         }
      }
   }
}

//=================================================================
//  V7.7: 3ER ORDEN — Ruptura del hedge lock
//=================================================================
void RunThirdOrderBreaker()
{
   if(m_isProcessing) return;
   if(m_port.totalPos == 0) return;
   if(m_hedgeLockCount == 0) return;
   if(!m_thirdOrderReady) return;
   if(IsStormActiveForThirdOrder()) return;

   double baseLot = CalcRecoveryLot();
   double t3Lot   = NormLot(baseLot * Inp_ThirdOrderLotMult);

   ENUM_ORDER_TYPE t3Type = m_thirdOrderDir;

   double netExposure = m_port.buyVolume - m_port.sellVolume;
   if(netExposure > 0.005 && t3Type == ORDER_TYPE_SELL) {
   } else if(netExposure < -0.005 && t3Type == ORDER_TYPE_BUY) {
   } else if(m_port.totalProfit >= 0) {
      return;
   }

   if(!MarginOK(t3Lot, t3Type)) {
      t3Lot = NormLot(t3Lot * 0.5);
      if(!MarginOK(t3Lot, t3Type)) {
         Print("[AQ V7.7.1] T3: Sin margen -> Mini-Block mode");
         m_miniBlock.active = true;
         return;
      }
   }

   string t3Comm = "T3_" + (t3Type == ORDER_TYPE_BUY ? "B" : "S") +
                   "_TEMA" + (m_mkt.temaAlignBull ? "+" : "-") +
                   "_KLM" + (m_mkt.kalmanAlignBull ? "+" : "-");

   m_isProcessing = true;
   ulong ticket   = OpenOrder(t3Type, t3Lot, t3Comm, true);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         MqlTick tk; GetTick(tk);
         int    pt = (t3Type == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (t3Type == ORDER_TYPE_BUY) ? tk.ask : tk.bid;
         InitRec(idx, ticket, pt, op, t3Lot, t3Comm, false, false, true, false, false, true);
      }
      m_thirdOrderBullTicks = 0;
      m_thirdOrderBearTicks = 0;
      m_thirdOrderReady     = false;

      Print("[AQ V7.7.1] 3ER ORDEN #", ticket,
            " [", (t3Type==ORDER_TYPE_BUY?"BUY":"SELL"), "]",
            " Lot=", t3Lot,
            " TEMA=", DoubleToString(m_mkt.temaFast,_Digits),
            " KalmanV=", DoubleToString(m_mkt.kalmanTrend,_Digits));
   }
}

//=================================================================
//  FIX V7.7: POST MINI-BLOCK COUNTER TRADE
//=================================================================
void RunPostMiniBlockCounterTrade()
{
   if(!m_postMiniBlockActive) return;
   if(m_isProcessing) return;

   if(m_port.totalPos == 0) {
      m_postMiniBlockActive  = false;
      m_postMiniBlockCTCount = 0;
      return;
   }

   if(m_port.totalProfit >= Inp_BlockTPTarget) {
      m_postMiniBlockActive  = false;
      m_postMiniBlockCTCount = 0;
      return;
   }

   if(m_port.negativeSum <= 0.001) {
      m_postMiniBlockActive  = false;
      m_postMiniBlockCTCount = 0;
      return;
   }

   if(m_postMiniBlockCTCount >= Inp_PostMBMaxCT) {
      m_postMiniBlockActive  = false;
      m_postMiniBlockCTCount = 0;
      return;
   }

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   ENUM_ORDER_TYPE counterType;
   bool hasBuyLosers  = (m_port.buyProfit  < -0.001 && m_port.buyCount  > 0);
   bool hasSellLosers = (m_port.sellProfit < -0.001 && m_port.sellCount > 0);

   if(!hasBuyLosers && !hasSellLosers) {
      m_postMiniBlockActive  = false;
      m_postMiniBlockCTCount = 0;
      return;
   }

   if(hasBuyLosers && hasSellLosers) {
      counterType = (m_port.buyProfit < m_port.sellProfit)
         ? ORDER_TYPE_SELL
         : ORDER_TYPE_BUY;
   } else if(hasBuyLosers) {
      counterType = ORDER_TYPE_SELL;
   } else {
      counterType = ORDER_TYPE_BUY;
   }

   double ctDist = atr * Inp_CTDistanceATR * Inp_PostMBCTDistMult;
   if(counterType == ORDER_TYPE_BUY && m_lastCTBuyPrice > 0 &&
      MathAbs(tk.ask - m_lastCTBuyPrice) < ctDist) {
      m_postMiniBlockActive  = false;
      m_postMiniBlockCTCount = 0;
      return;
   }
   if(counterType == ORDER_TYPE_SELL && m_lastCTSellPrice > 0 &&
      MathAbs(tk.bid - m_lastCTSellPrice) < ctDist) {
      m_postMiniBlockActive  = false;
      m_postMiniBlockCTCount = 0;
      return;
   }

   double pmLot = CalcRecoveryLot();
   if(!MarginOK(pmLot, counterType)) {
      pmLot = NormLot(pmLot * 0.5);
      if(!MarginOK(pmLot, counterType)) {
         pmLot = NormLot(m_lotBaseEffective);
         if(!MarginOK(pmLot, counterType)) {
            m_miniBlock.active    = true;
            m_postMiniBlockActive = false;
            m_postMiniBlockCTCount= 0;
            Print("[AQ V7.7.1] POST-MB: Sin margen -> re-activando Mini-Block");
            return;
         }
      }
   }

   string pmComm = "REC_" + (counterType == ORDER_TYPE_BUY ? "B" : "S") +
                   "_PMB" + IntegerToString(m_miniBlock.iterationCount) +
                   "_" + IntegerToString(m_postMiniBlockCTCount + 1);

   m_isProcessing = true;
   ulong ticket   = OpenOrder(counterType, pmLot, pmComm, true);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (counterType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (counterType == ORDER_TYPE_BUY) ? tk.ask : tk.bid;
         InitRec(idx, ticket, pt, op, pmLot, pmComm, false, false, true, false, false, false);
      }

      if(counterType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = tk.ask;
      else                               m_lastCTSellPrice = tk.bid;

      m_recoveryOrders++;
      m_recoveryActive    = true;
      m_lastRecoveryTime  = TimeCurrent();
      m_postMiniBlockCTCount++;

      if(m_postMiniBlockCTCount >= Inp_PostMBMaxCT) {
         m_postMiniBlockActive  = false;
         m_postMiniBlockCTCount = 0;
      }

      Print("[AQ V7.7.1] POST-MB CT #", ticket,
            " [", (counterType == ORDER_TYPE_BUY ? "BUY" : "SELL"), "]",
            " Lot=", pmLot,
            " | Iter MB=", m_miniBlock.iterationCount,
            " | CT#=", m_postMiniBlockCTCount,
            " | PerdRestante=$", NormalizeDouble(m_port.negativeSum, 2));
   } else {
      m_postMiniBlockActive  = false;
      m_postMiniBlockCTCount = 0;
   }
}

//=================================================================
//  V7.7: MINI-BLOCK PARTIAL NETTING
//=================================================================
void RunMiniBlockPartialNetting()
{
   if(!m_miniBlock.active && AccountInfoDouble(ACCOUNT_MARGIN_FREE) > Inp_MiniBlockMarginThreshold)
      return;

   if(m_isProcessing) return;
   if(m_port.totalPos < 2) return;
   if(TimeCurrent() - m_lastMiniBlockTime < Inp_MiniBlockIntervalSec) return;
   m_lastMiniBlockTime = TimeCurrent();
   m_miniBlock.active  = true;

   struct PosEntry { ulong ticket; double pf; double vol; };
   PosEntry winners[MAX_RECORDS];
   PosEntry losers[MAX_RECORDS];
   int nWin = 0, nLos = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;

      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);

      if(pf > 0 && nWin < MAX_RECORDS) {
         winners[nWin].ticket = t;
         winners[nWin].pf     = pf;
         winners[nWin].vol    = vol;
         nWin++;
      } else if(pf < 0 && nLos < MAX_RECORDS) {
         losers[nLos].ticket = t;
         losers[nLos].pf     = pf;
         losers[nLos].vol    = vol;
         nLos++;
      }
   }

   if(nWin == 0 || nLos == 0) {
      if(m_port.totalProfit >= 0) m_miniBlock.active = false;
      return;
   }

   double totalWinProfit = 0;
   for(int w = 0; w < nWin; w++) totalWinProfit += winners[w].pf;

   int    bestLosIdx  = -1;
   double bestLosPF   = 0;
   for(int l = 0; l < nLos; l++) {
      double losPF   = losers[l].pf;
      double netPnL  = totalWinProfit + losPF;
      if(netPnL >= Inp_MiniBlockBuffer) {
         if(losPF < bestLosPF) {
            bestLosPF  = losPF;
            bestLosIdx = l;
         }
      }
   }

   if(bestLosIdx < 0) {
      Print("[AQ V7.7.1] Mini-Block: Sin par viable con buffer $", Inp_MiniBlockBuffer,
            " | TotalWin=$", NormalizeDouble(totalWinProfit,2));
      return;
   }

   double netClosed = 0;
   m_isProcessing   = true;

   Print("[AQ V7.7.1] MINI-BLOCK: Cerrando ", nWin, " ganadoras + 1 perdedora | NetEsp=$",
         NormalizeDouble(totalWinProfit + losers[bestLosIdx].pf, 2));

   for(int w = 0; w < nWin; w++) {
      if(ClosePos(winners[w].ticket, "MiniBlock_Win")) {
         netClosed += winners[w].pf;
      }
   }

   bool loserClosed = false;
   if(ClosePos(losers[bestLosIdx].ticket, "MiniBlock_Los")) {
      netClosed += losers[bestLosIdx].pf;
      m_miniBlock.iterationCount++;
      m_miniBlock.totalNetted += netClosed;
      loserClosed = true;

      m_lastRecoveryTime  = 0;
      m_lastHedgeLockTime = 0;
      m_lastCTTime        = 0;

      Print("[AQ V7.7.1] MINI-BLOCK OK: Net=$", NormalizeDouble(netClosed,2),
            " | Iter #", m_miniBlock.iterationCount,
            " | Total cosechado=$", NormalizeDouble(m_miniBlock.totalNetted,2));
   }

   m_isProcessing = false;

   UpdatePortfolio();
   if(m_port.totalPos == 0 ||
      AccountInfoDouble(ACCOUNT_MARGIN_FREE) > Inp_MiniBlockMarginThreshold * 3) {
      m_miniBlock.active = false;
   }

   if(loserClosed && m_port.totalPos > 0 && m_port.negativeSum > 0.001) {
      m_postMiniBlockActive  = true;
      m_postMiniBlockCTCount = 0;
      m_recoveryActive       = true;
      Print("[AQ V7.7.1] POST-MB ACTIVADO: ", m_port.totalPos,
            " pos restantes | Perdida=$", NormalizeDouble(m_port.negativeSum, 2));
   }
}

//=================================================================
//  RECOVERY ENGINE
//=================================================================
void RunRecoveryEngine()
{
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD) {
      if(m_recoveryActive && m_hedgeLockCount == 0) {
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
      Print("[AQ V7.7.1] RECOVERY ACTIVADO | PnL=$", NormalizeDouble(m_port.totalProfit,2));
   }

   if(m_thirdOrderReady && m_hedgeLockCount > 0) return;

   if(TimeCurrent() - m_lastRecoveryTime < Inp_RecoveryIntervalSec) return;
   if(!SpreadOK()) return;

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   if(m_losingPosOpenPrice > 0 && m_losingPosType >= 0) {
      double distFromLoser = 0;
      if(m_losingPosType == POSITION_TYPE_SELL)
         distFromLoser = tk.bid - m_losingPosOpenPrice;
      else
         distFromLoser = m_losingPosOpenPrice - tk.ask;

      if(distFromLoser < atr * Inp_RecoveryMinDistATR) return;
   }

   ENUM_ORDER_TYPE recType;
   bool bearTrend = (!m_mkt.temaAlignBull && m_mkt.adx > Inp_ADXTrendLevel);
   bool bullTrend = (m_mkt.temaAlignBull  && m_mkt.adx > Inp_ADXTrendLevel);

   if(m_port.buyProfit < m_port.sellProfit && bearTrend) {
      recType = ORDER_TYPE_SELL;
   } else if(m_port.sellProfit < m_port.buyProfit && bullTrend) {
      recType = ORDER_TYPE_BUY;
   } else {
      if(m_port.buyProfit < m_port.sellProfit) {
         recType = ORDER_TYPE_BUY;
         if(m_lastCTBuyPrice > 0 && MathAbs(tk.ask - m_lastCTBuyPrice) < atr * 0.3) return;
      } else {
         recType = ORDER_TYPE_SELL;
         if(m_lastCTSellPrice > 0 && MathAbs(tk.bid - m_lastCTSellPrice) < atr * 0.3) return;
      }
   }

   double recLot = CalcRecoveryLot();
   if(!MarginOK(recLot, recType)) {
      recLot = NormLot(recLot * 0.5);
      if(!MarginOK(recLot, recType)) {
         recLot = NormLot(m_lotBaseEffective);
         if(!MarginOK(recLot, recType)) {
            Print("[AQ V7.7.1] RECOVERY: Sin margen -> Mini-Block mode");
            m_miniBlock.active = true;
            return;
         }
      }
   }

   string recComm = "REC_" + (recType==ORDER_TYPE_BUY?"B":"S") + "_" + IntegerToString(m_recoveryOrders+1);
   m_isProcessing = true;
   ulong ticket   = OpenOrder(recType, recLot, recComm, true);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (recType==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (recType==ORDER_TYPE_BUY) ? tk.ask : tk.bid;
         InitRec(idx, ticket, pt, op, recLot, recComm, false, false, true, false, false, false);
      }
      if(recType==ORDER_TYPE_BUY) m_lastCTBuyPrice  = tk.ask;
      else                         m_lastCTSellPrice = tk.bid;
      m_recoveryOrders++;
      m_lastRecoveryTime = TimeCurrent();
   }
}

//=================================================================
//  LBC ENGINE — INTOCABLE de V7.6C
//=================================================================
void ActivateLBC()
{
   if(m_lbc.active) return;
   m_lbc.active        = true;
   m_lbc.activatedTime = TimeCurrent();
   m_lbc.buyCount = m_lbc.sellCount = 0;
   m_lbc.lastBuyPrice = m_lbc.lastSellPrice = 0;
   m_lbc.harvestedTotal = 0; m_lbc.harvestCount = 0;
   double freeMarg   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margPer001 = CalcMarginFor001();
   double usableMarg = freeMarg * Inp_LBCMarginPct;
   m_lbc.maxOrdersCalc = (int)MathFloor(usableMarg / (2.0 * MathMax(margPer001, 0.01)));
   m_lbc.maxOrdersCalc = MathMax(1, MathMin(m_lbc.maxOrdersCalc, Inp_LBCMaxPairs));
   Print("[AQ V7.7.1] LBC ACTIVADO | MaxPares=", m_lbc.maxOrdersCalc);
}

// INTOCABLE: DeactivateLBC
void DeactivateLBC()
{
   if(!m_lbc.active) return;
   Print("[AQ V7.7.1] LBC DESACTIVADO | Cosechado=$", NormalizeDouble(m_lbc.harvestedTotal,2));
   ZeroMemory(m_lbc);
}

void RunLBCEngine()
{
   if(!m_lbc.active) return;
   if(m_port.totalPos == 0) { DeactivateLBC(); return; }
   if(m_isProcessing)        return;
   if(m_port.totalProfit >= Inp_BlockTPTarget) return;
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD * 0.5) { DeactivateLBC(); return; }

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   double harvestMin = DistToUSD(atr * Inp_LBCHarvestATR, 0.01);
   harvestMin = MathMax(harvestMin, 0.02);

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
         double freeMarg = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         double margP001 = CalcMarginFor001();
         m_lbc.maxOrdersCalc = MathMax(1, MathMin(
            (int)MathFloor((freeMarg*Inp_LBCMarginPct)/(2.0*MathMax(margP001,0.01))),
            Inp_LBCMaxPairs));
      }
   }

   if(TimeCurrent() - m_lbc.lastOrderTime < Inp_LBCIntervalSec) return;
   if(!SpreadOK()) return;

   int totalLBCPairs = MathMin(m_lbc.buyCount, m_lbc.sellCount);
   if(totalLBCPairs >= m_lbc.maxOrdersCalc) return;

   double gridSpace = atr * Inp_LBCGridATR;
   double lot001    = NormLot(m_lotBaseEffective);
   bool needBuy = false, needSell = false;

   if(m_lbc.buyCount == 0 && m_lbc.sellCount == 0) {
      needBuy = needSell = true;
   } else {
      if(m_lbc.buyCount <= m_lbc.sellCount) {
         if(m_lbc.lastBuyPrice <= 0 || MathAbs(tk.ask - m_lbc.lastBuyPrice) >= gridSpace)
            needBuy = true;
      }
      if(m_lbc.sellCount <= m_lbc.buyCount) {
         if(m_lbc.lastSellPrice <= 0 || MathAbs(tk.bid - m_lbc.lastSellPrice) >= gridSpace)
            needSell = true;
      }
   }

   if(needBuy && MarginOK_Hedge(lot001, ORDER_TYPE_BUY)) {
      string commB = "LBC_B" + IntegerToString(m_lbc.buyCount+1);
      m_isProcessing = true;
      ulong tB = OpenOrder(ORDER_TYPE_BUY, lot001, commB, true);
      m_isProcessing = false;
      if(tB > 0) {
         int idx = FreeRec();
         if(idx >= 0) InitRec(idx, tB, POSITION_TYPE_BUY, tk.ask, lot001, commB, false, false, false, true);
         m_lbc.buyCount++; m_lbc.lastBuyPrice = tk.ask; m_lbc.lastOrderTime = TimeCurrent();
      }
   }
   if(needSell && MarginOK_Hedge(lot001, ORDER_TYPE_SELL)) {
      string commS = "LBC_S" + IntegerToString(m_lbc.sellCount+1);
      m_isProcessing = true;
      ulong tS = OpenOrder(ORDER_TYPE_SELL, lot001, commS, true);
      m_isProcessing = false;
      if(tS > 0) {
         int idx = FreeRec();
         if(idx >= 0) InitRec(idx, tS, POSITION_TYPE_SELL, tk.bid, lot001, commS, false, false, false, true);
         m_lbc.sellCount++; m_lbc.lastSellPrice = tk.bid; m_lbc.lastOrderTime = TimeCurrent();
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
   double hMin = Inp_HarvestMinUSD;
   if(atr > 0 && tv > 0 && ts > 0) {
      double minL   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double atrUSD = (atr/ts)*tv*minL*Inp_HarvestATRMult;
      hMin = MathMax(hMin, NormalizeDouble(atrUSD, 2));
   }

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      int    idx = FindRec(t);
      double kpf = (idx >= 0 && m_rec[idx].kInit) ? m_rec[idx].kX : pf;
      if(m_port.negativeSum > pf * 1.5 && pf > 0) continue;
      bool doH = (pf >= hMin*3.0) ||
                 (kpf >= hMin && idx >= 0 && m_rec[idx].kInit && m_rec[idx].kK <= 0.30);
      if(doH) ClosePos(t, "Harvest");
   }
}

//=================================================================
//  V7.7: EQUITY GUARD — Solo alarma critica, no pausa
//=================================================================
bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   if(m_port.currentDD >= Inp_MaxDrawdownPct) {
      Print("[AQ V7.7.1] ALERTA CRITICA: DD=", NormalizeDouble(m_port.currentDD*100,1),
            "% | Equity=$", NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY),2));
      return true;
   }
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
   if(m_lbc.active) return false;
   if(m_mkt.atr <= 0) return false;

   bool buyLosing  = (m_port.buyProfit  < -0.05 && m_port.buyCount  > 0);
   bool sellLosing = (m_port.sellProfit < -0.05 && m_port.sellCount > 0);
   bool openBuy = false, openSell = false;

   if(buyLosing && !sellLosing) {
      if(m_port.sellCount >= Inp_CTMaxSameDir) return false;
      openSell = true;
   } else if(sellLosing && !buyLosing) {
      if(m_port.buyCount >= Inp_CTMaxSameDir) return false;
      openBuy = true;
   } else if(buyLosing && sellLosing) {
      if(m_mkt.htfTrend == 1 && m_port.buyCount < Inp_CTMaxSameDir) openBuy = true;
      else if(m_mkt.htfTrend == -1 && m_port.sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(m_port.buyProfit < m_port.sellProfit && m_port.sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(m_port.buyCount < Inp_CTMaxSameDir) openBuy = true;
      else return false;
   } else return false;

   double ctDist = (Inp_CTMode == CT_ATR_DISTANCE)
      ? m_mkt.atr * Inp_CTDistanceATR
      : Inp_CTFixedPoints * _Point;
   MqlTick t; if(!GetTick(t)) return false;
   if(ctDist > 0) {
      if(openBuy  && m_lastCTBuyPrice  > 0 && MathAbs(t.ask - m_lastCTBuyPrice)  < ctDist) return false;
      if(openSell && m_lastCTSellPrice > 0 && MathAbs(t.bid - m_lastCTSellPrice) < ctDist) return false;
   }

   ctLevel = openBuy ? m_port.buyCount : m_port.sellCount;
   ctLot   = CalcLot(ctLevel);
   ctType  = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine()
{
   if(m_isProcessing || m_isPaused) return;
   if(TimeCurrent() - m_lastCTTime < Inp_CTIntervalSec) return;
   m_lastCTTime = TimeCurrent();

   MqlTick ts; if(!GetTick(ts)) return;

   if(m_port.totalPos == 0 && !m_cycleInPause) {
      if(TimeCurrent() - m_lastPrimaryTime < Inp_PrimaryCooldownSec) return;

      ENUM_ORDER_TYPE initType;
      if(m_temaFast.init && m_temaSlow.init) {
         initType = m_mkt.temaAlignBull ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      } else if(m_mkt.isBullish) {
         initType = ORDER_TYPE_BUY;
      } else if(m_mkt.isBearish) {
         initType = ORDER_TYPE_SELL;
      } else {
         initType = (m_mkt.emaFast > m_mkt.emaSlow) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      }

      if(m_lastPrimaryLost && m_lastPrimaryDir != 0) {
         ENUM_ORDER_TYPE alt = (m_lastPrimaryDir == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         if(initType != alt) { initType = alt; m_lastPrimaryLost = false; }
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
         if(initType == ORDER_TYPE_BUY) m_lastCTBuyPrice  = ts.ask;
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

   string ctComm = "CT_" + (ctType==ORDER_TYPE_BUY?"B":"S") + "_L" + IntegerToString(ctLevel+1);
   m_isProcessing = true;
   ulong ticket   = OpenOrder(ctType, ctLot, ctComm);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (ctType==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (ctType==ORDER_TYPE_BUY) ? ts.ask : ts.bid;
         InitRec(idx, ticket, pt, op, ctLot, ctComm, false, true, false, false);
      }
      if(ctType==ORDER_TYPE_BUY) m_lastCTBuyPrice  = ts.ask;
      else                        m_lastCTSellPrice = ts.bid;
   }
}

//=================================================================
//  V7.7: DASHBOARD — Dark Mode Institucional con Z-Order fijo
//=================================================================
void AQLbl(string n, string txt, int x, int y, color c, int fs=9, bool bold=false)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTED,   false);
      ObjectSetInteger(0, n, OBJPROP_ZORDER,     1000);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  fs);
   ObjectSetString(0,  n, OBJPROP_FONT,      bold ? "Consolas Bold" : "Consolas");
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
}

void AQBtn(string n, string txt, int x, int y, int w, int h, color bg, color fg=clrWhite)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE,   8);
      ObjectSetString(0,  n, OBJPROP_FONT,       "Consolas");
      ObjectSetInteger(0, n, OBJPROP_ZORDER,     1001);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,     h);
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     fg);
}

void AQPanel(string n, int x, int y, int w, int h)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_BACK,       false);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,     true);
      ObjectSetInteger(0, n, OBJPROP_ZORDER,     999);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,       h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,     C'8,8,12');
   ObjectSetInteger(0, n, OBJPROP_COLOR,       C'70,70,70');
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_WIDTH,       1);
}

void DeleteDash()
{
   string objs[] = {
      "AQ77_BG","AQ77_HDR","AQ77_SEP1","AQ77_STATE",
      "AQ77_SEP2","AQ77_TEMA","AQ77_KALM","AQ77_T3",
      "AQ77_SEP3","AQ77_HEDGE","AQ77_MINI","AQ77_PMB",
      "AQ77_SEP4","AQ77_ACC",
      "AQ77_SEP5","AQ77_PNL","AQ77_POS","AQ77_VWAP",
      "AQ77_REC","AQ77_SEP6","AQ77_HIST",
      "AQ77_SEP7","AQ77_SCALE","AQ77_STORM",
      "AQ77_TRAIL",
      "AQ77_B1","AQ77_B2",
      "AQ75_BG","AQ75_HDR","AQ75_SEP1","AQ75_STATE","AQ75_REASON",
      "AQ75_SEP2","AQ75_SENS_HDR","AQ75_S1","AQ75_S2","AQ75_S3","AQ75_S4","AQ75_S5",
      "AQ75_SEP3","AQ75_RESCUE","AQ75_SEP4","AQ75_ACC","AQ75_SEP5","AQ75_PNL",
      "AQ75_POS","AQ75_VWAP","AQ75_REC","AQ75_NH","AQ75_SF","AQ75_SEP6","AQ75_HIST",
      "AQ75_SEP7","AQ75_DIAG","AQ75_B1","AQ75_B2"
   };
   for(int i = 0; i < ArraySize(objs); i++) ObjectDelete(0, objs[i]);
}

void UpdateDash()
{
   if(!Inp_ShowDashboard) return;
   if(TimeCurrent() - m_lastDashTime < 1) return;
   m_lastDashTime = TimeCurrent();

   color cBorder= C'70,70,70';
   color cGreen = C'0,220,80';
   color cRed   = C'220,50,50';
   color cOra   = C'220,150,30';
   color cYel   = C'200,200,50';
   color cCyan  = C'50,190,220';
   color cPurple= C'160,80,220';
   color cTema  = C'80,160,255';
   color cGray  = C'120,120,130';
   color cMint  = C'0,200,160';

   int x0=Inp_DashX, y0=Inp_DashY, lh=16, pad=8, w=580;
   int h = 40 * lh + 60;
   AQPanel("AQ77_BG", x0-pad, y0-pad, w, h);

   int x=x0, y=y0;

   AQLbl("AQ77_HDR",
         "[ " + VERSION_STR + " ]  " + _Symbol + "  |  ZERO-SURRENDER ENGINE",
         x, y, cGreen, 10, true);
   y += lh + 2;

   AQLbl("AQ77_SEP1",
         "──────────────────────────────────────────────────────────────────────",
         x, y, cBorder, 8);
   y += lh - 4;

   string stateStr; color stateC;
   if(m_postMiniBlockActive) {
      stateStr = "[ POST MINI-BLOCK: ABRIENDO CONTRA-TRADES (" +
                 IntegerToString(m_postMiniBlockCTCount) + "/" +
                 IntegerToString(Inp_PostMBMaxCT) + ") ]";
      stateC   = cPurple;
   } else if(m_miniBlock.active) {
      stateStr = "[ MINI-BLOCK PARTIAL NETTING ACTIVO ]";
      stateC   = cOra;
   } else if(m_hedgeLockCount > 0 && m_thirdOrderReady) {
      stateStr = "[ 3ER ORDEN LISTO - DOBLE CONFIRMACION ]";
      stateC   = cGreen;
   } else if(m_hedgeLockCount > 0) {
      stateStr = "[ DRAWDOWN LOCKS ACTIVOS - ESPERANDO 3ER ORDEN ]";
      stateC   = cYel;
   } else if(m_recoveryActive) {
      stateStr = "[ RECOVERY ACTIVO ]";
      stateC   = cYel;
   } else if(m_lbc.active) {
      stateStr = "[ MODO LBC ACTIVO ]";
      stateC   = cOra;
   } else if(m_cycleInPause) {
      stateStr = "[ PAUSA ENTRE CICLOS ]";
      stateC   = cGray;
   } else if(m_isPaused) {
      stateStr = "[ PAUSA MANUAL - RECOVERY CONTINUA ]";
      stateC   = cYel;
   } else if(m_port.totalPos == 1) {
      // Mostrar estado especial cuando trailing puede estar activo
      int idxTrail = -1;
      for(int i = PositionsTotal()-1; i >= 0; i--) {
         ulong tt = PositionGetTicket(i);
         if(!PositionSelectByTicket(tt)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
         idxTrail = FindRec(tt);
         break;
      }
      bool trailArmed = (Inp_PrimaryTrailEnable && idxTrail >= 0 &&
                         m_rec[idxTrail].isPrimary &&
                         m_rec[idxTrail].peakProfit >= Inp_PrimaryTrailActivation);
      stateStr = trailArmed
         ? "[ PRIMARIA SOLA - TRAILING ARMADO ]"
         : "[ PRIMARIA SOLA - ESPERANDO ACTIVACION TRAIL ]";
      stateC   = trailArmed ? cMint : cGreen;
   } else {
      stateStr = "[ BUSCANDO ENTRADA - OPERACION CONTINUA ]";
      stateC   = cGreen;
   }
   AQLbl("AQ77_STATE", stateStr, x, y, stateC, 10, true);
   y += lh + 2;

   AQLbl("AQ77_SEP2",
         "── ZERO-LAG INDICATORS (TEMA + KALMAN) ─────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   string temaStr = m_temaFast.init ?
      "TEMA Fast=" + DoubleToString(m_mkt.temaFast,_Digits) +
      "  Slow=" + DoubleToString(m_mkt.temaSlow,_Digits) +
      "  Dir=" + (m_mkt.temaAlignBull ? "BULL" : "BEAR") : "TEMA: cargando...";
   AQLbl("AQ77_TEMA", temaStr, x, y, cTema, 9);
   y += lh - 1;

   string kalmStr = m_kalmanFast.init ?
      "Kalman Price=" + DoubleToString(m_mkt.kalmanPrice,_Digits) +
      "  Vel=" + DoubleToString(m_mkt.kalmanTrend*10000,1) + "e-4" +
      "  Dir=" + (m_mkt.kalmanAlignBull ? "BULL" : "BEAR") : "Kalman: cargando...";
   AQLbl("AQ77_KALM", kalmStr, x, y, cTema, 9);
   y += lh - 1;

   string t3Str; color t3C;
   if(m_thirdOrderReady) {
      t3Str = "3ER ORDEN: READY! Dir=" + (m_thirdOrderDir==ORDER_TYPE_BUY?"BUY":"SELL") +
              " | Bull:" + IntegerToString(m_thirdOrderBullTicks) +
              " Bear:" + IntegerToString(m_thirdOrderBearTicks) +
              " Req=" + IntegerToString(Inp_ThirdOrderConfirmTicks);
      t3C   = cGreen;
   } else {
      t3Str = "3ER ORDEN: esperando | Bull:" + IntegerToString(m_thirdOrderBullTicks) +
              "/" + IntegerToString(Inp_ThirdOrderConfirmTicks) +
              " Bear:" + IntegerToString(m_thirdOrderBearTicks) +
              "/" + IntegerToString(Inp_ThirdOrderConfirmTicks);
      t3C   = cGray;
   }
   AQLbl("AQ77_T3", t3Str, x, y, t3C, 9);
   y += lh;

   AQLbl("AQ77_SEP3",
         "── DRAWDOWN LOCK + MINI-BLOCK + POST-MB CT ──────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   string hlStr = "Hedge Locks: " + IntegerToString(m_hedgeLockCount) +
                  " | Trigger: $" + DoubleToString(Inp_HedgeLockTrigger,2) +
                  " | Cap: $" + DoubleToString(Inp_HedgeCapUSD,2);
   color hlC = (m_hedgeLockCount > 0) ? cRed : cGray;
   AQLbl("AQ77_HEDGE", hlStr, x, y, hlC, 9);
   y += lh - 1;

   string mbStr; color mbC;
   if(m_miniBlock.active) {
      mbStr = "MINI-BLOCK: ACTIVO | Iter=" + IntegerToString(m_miniBlock.iterationCount) +
              " | Cosechado=$" + DoubleToString(m_miniBlock.totalNetted,2) +
              " | LibreMarg=$" + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE),2);
      mbC   = cOra;
   } else {
      mbStr = "Mini-Block: espera | Activa si LibreMarg < $" +
              DoubleToString(Inp_MiniBlockMarginThreshold,2) +
              " | Iters: " + IntegerToString(m_miniBlock.iterationCount);
      mbC   = cGray;
   }
   AQLbl("AQ77_MINI", mbStr, x, y, mbC, 9);
   y += lh - 1;

   string pmbStr; color pmbC;
   if(m_postMiniBlockActive) {
      pmbStr = "POST-MB CT: ACTIVO | " + IntegerToString(m_postMiniBlockCTCount) +
               "/" + IntegerToString(Inp_PostMBMaxCT) +
               " | PerdRest=$" + DoubleToString(m_port.negativeSum,2);
      pmbC   = cPurple;
   } else {
      pmbStr = "Post-MB CT: inactivo | Activado tras mini-block exitoso con perdedoras";
      pmbC   = cGray;
   }
   AQLbl("AQ77_PMB", pmbStr, x, y, pmbC, 9);
   y += lh;

   // V7.7.1: Trailing Stop Primario
   AQLbl("AQ77_SEP7",
         "── TRAILING STOP PRIMARIO ────────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   string trailStr; color trailC;
   if(!Inp_PrimaryTrailEnable) {
      trailStr = "Trailing primario: DESACTIVADO";
      trailC   = cGray;
   } else if(m_port.totalPos == 1) {
      double peakPF = 0;
      for(int i = 0; i < MAX_RECORDS; i++) {
         if(m_rec[i].ticket != 0 && m_rec[i].isPrimary) {
            peakPF = m_rec[i].peakProfit;
            break;
         }
      }
      bool armed = (peakPF >= Inp_PrimaryTrailActivation);
      trailStr = armed
         ? "TRAIL ACTIVO: Peak=$" + DoubleToString(peakPF,2) +
           " | Cierra si PF<=$" + DoubleToString(peakPF - Inp_PrimaryTrailDist,2) +
           " | Dist=$" + DoubleToString(Inp_PrimaryTrailDist,2)
         : "Trail espera activacion: Peak=$" + DoubleToString(peakPF,2) +
           " | Activa a >= $" + DoubleToString(Inp_PrimaryTrailActivation,2);
      trailC = armed ? cMint : cGray;
   } else {
      trailStr = "Trailing: inactivo (solo con 1 posicion primaria sola) | " +
                 IntegerToString(m_port.totalPos) + " pos abiertas";
      trailC   = cGray;
   }
   AQLbl("AQ77_TRAIL", trailStr, x, y, trailC, 9);
   y += lh;

   AQLbl("AQ77_SEP4",
         "── CUENTA ───────────────────────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double ddPct= m_port.currentDD * 100.0;
   color  ddC  = (ddPct > 25.0) ? cRed : (ddPct > 10.0) ? cOra : cGreen;

   AQLbl("AQ77_ACC",
         "Saldo: $" + DoubleToString(bal,2) +
         "   Equity: $" + DoubleToString(eq,2) +
         "   LibreMarg: $" + DoubleToString(free,2) +
         "   DD: " + DoubleToString(ddPct,1) + "%",
         x, y, cCyan, 9);
   y += lh;

   AQLbl("AQ77_SEP5",
         "── BLOQUE ACTIVO ─────────────────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   double pnl    = m_port.totalProfit;
   double falta  = MathMax(0, Inp_BlockTPTarget - pnl);
   color  pnlC   = (pnl >= 0) ? cGreen : cRed;

   AQLbl("AQ77_PNL",
         "PnL BLOQUE: " + (pnl>=0?"+":"") + DoubleToString(pnl,2) +
         "   Target: +$" + DoubleToString(Inp_BlockTPTarget,2) +
         "   Falta: $" + DoubleToString(falta,2),
         x, y, pnlC, 9);
   y += lh - 1;

   AQLbl("AQ77_POS",
         "Pos: " + IntegerToString(m_port.totalPos) +
         "   BUY: " + IntegerToString(m_port.buyCount) + "($" + DoubleToString(m_port.buyProfit,2) + ")" +
         "   SELL: " + IntegerToString(m_port.sellCount) + "($" + DoubleToString(m_port.sellProfit,2) + ")" +
         "   HL:" + IntegerToString(m_port.hedgeLockCount) +
         " REC:" + IntegerToString(m_port.recoveryCount),
         x, y, cCyan, 9);
   y += lh - 1;

   string dirStr = (m_port.blockDir>0) ? "LARGO" : (m_port.blockDir<0) ? "CORTO" : "NEUTRO";
   AQLbl("AQ77_VWAP",
         "VWAP: " + (m_port.blockVWAP > 0 ? DoubleToString(m_port.blockVWAP,_Digits) : "N/A") +
         "   Dir: " + dirStr +
         "   Rescate: " + IntegerToString(m_port.rescueCount) + " pos externas",
         x, y, cGray, 9);
   y += lh - 1;

   string recStr = m_recoveryActive
      ? "RECOVERY: ACTIVO (" + IntegerToString(m_recoveryOrders) + " ord)"
      : "RECOVERY: en espera";
   AQLbl("AQ77_REC", recStr, x, y, m_recoveryActive ? cYel : cGray, 9);
   y += lh;

   AQLbl("AQ77_SEP6",
         "── HISTORIAL ─────────────────────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   int    totalT = m_totalWins + m_totalLosses;
   double wrPct  = (totalT > 0) ? (double)m_totalWins / totalT * 100.0 : 0;
   double expect = 0;
   if(totalT > 0) {
      double avgW = (m_totalWins   > 0) ? m_sumWins   / m_totalWins   : 0;
      double avgL = (m_totalLosses > 0) ? m_sumLosses / m_totalLosses : 0;
      expect = ((double)m_totalWins / totalT * avgW) -
               ((double)m_totalLosses / totalT * avgL);
   }
   AQLbl("AQ77_HIST",
         "Win: " + DoubleToString(wrPct,1) + "% (" + IntegerToString(m_totalWins) +
         "/" + IntegerToString(totalT) + ")" +
         "   Expect: $" + DoubleToString(expect,3) +
         "   PnL cerrado: $" + DoubleToString(m_totalPnL,2) +
         "   Ticks: " + IntegerToString((int)m_tickCount),
         x, y, (expect>=0)?cGreen:cOra, 9);
   y += lh;

   AQLbl("AQ77_SCALE",
         "LoteBase: " + DoubleToString(GetEffectiveLotBase(),2) +
         "  (Auto >$" + DoubleToString(Inp_ScaleBalance1,0) + ")" +
         "   ATR: " + DoubleToString(m_mkt.atr,4) +
         "   Spread: " + DoubleToString(m_mkt.spread,0) + " pts",
         x, y, cCyan, 9);
   y += lh - 1;

   string stormStr = m_stormActive
      ? "STORM FILTER: ACTIVO (bloquea 3er orden) | ATRratio=" + DoubleToString(m_mkt.atrRatio,2)
      : "Storm Filter: OK | ATRratio=" + DoubleToString(m_mkt.atrRatio,2) + "x";
   AQLbl("AQ77_STORM", stormStr, x, y, m_stormActive ? cOra : cGray, 9);
   y += lh + 4;

   AQBtn("AQ77_B1", m_isPaused ? ">> REANUDAR <<" : "|| PAUSA PRIMARIAS",
         x, y, 180, 22, m_isPaused ? C'180,130,0' : C'0,90,40');
   AQBtn("AQ77_B2", "CERRAR TODAS (MANUAL)", x+190, y, 180, 22, C'150,20,20');

   ChartRedraw(0);
}

//=================================================================
//  FILLING MODE — Auto-deteccion
//=================================================================
ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   if((bool)MQLInfoInteger(MQL_TESTER)) return ORDER_FILLING_RETURN;
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//=================================================================
//  OnInit
//=================================================================
int OnInit()
{
   Print("=============================================================");
   Print("  " + VERSION_STR + " - ZERO-SURRENDER ENGINE (140 USD OPT)");
   Print("  SL=0 | TP=0 | CalcRecoveryLot=INTOCABLE | DeactivateLBC=INTOCABLE");
   Print("  HedgeLock: $", Inp_HedgeLockTrigger, " | RecoveryTrigger: $", Inp_RecoveryTriggerUSD);
   Print("  TEMA(", Inp_TEMAFastPeriod, "/", Inp_TEMASlowPeriod,
         ") | Kalman(Q=", Inp_KalmanQ, " R=", Inp_KalmanR, ")");
   Print("  3er Orden: ", Inp_ThirdOrderConfirmTicks, " ticks doble confirmacion");
   Print("  RecoveryMinDistATR=", Inp_RecoveryMinDistATR,
         " | RecoveryMoveATR=", Inp_RecoveryMoveATR,
         " | RecoveryMinLotMult=", Inp_RecoveryMinLotMult);
   Print("  CTDistanceATR=", Inp_CTDistanceATR, " | PrimaryCooldown=", Inp_PrimaryCooldownSec, "s");
   Print("  Primary Trail: ", Inp_PrimaryTrailEnable ? "ON" : "OFF",
         " | Activation=$", Inp_PrimaryTrailActivation,
         " | Dist=$", Inp_PrimaryTrailDist);
   Print("  Mini-Block buffer=$", Inp_MiniBlockBuffer,
         " | PostMBMaxCT=", Inp_PostMBMaxCT);
   Print("  LotMaximum=", Inp_LotMaximum,
         " | AutoScale: $", Inp_ScaleBalance1, "->0.02 | $",
         Inp_ScaleBalance2, "->0.03 | $", Inp_ScaleBalance3, "->0.05");
   Print("=============================================================");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(30);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(DetectFillingMode());

   ChartSetInteger(0, CHART_SHOW_TRADE_HISTORY, false);
   ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS,  false);

   h_ATR     = iATR(_Symbol,  PERIOD_M1, Inp_ATRPeriod);
   h_EMAFast = iMA(_Symbol,   PERIOD_M1, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMASlow = iMA(_Symbol,   PERIOD_M1, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol,  PERIOD_M1, Inp_RSIPeriod, PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol, PERIOD_M1, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);

   if(h_ATR==INVALID_HANDLE || h_EMAFast==INVALID_HANDLE ||
      h_EMASlow==INVALID_HANDLE || h_RSI==INVALID_HANDLE || h_MACD==INVALID_HANDLE) {
      Print("[AQ V7.7.1] ERROR: Indicadores base no iniciados");
      return INIT_FAILED;
   }

   h_ADX        = iADX(_Symbol, PERIOD_M1, Inp_ADXPeriod);
   h_HTFEMAFast = iMA(_Symbol, Inp_HTFTF, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_HTFEMASlow = iMA(_Symbol, Inp_HTFTF, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA200     = iMA(_Symbol, PERIOD_M1, 200, 0, MODE_EMA, PRICE_CLOSE);
   h_ATRSlow    = iATR(_Symbol, PERIOD_M1, 100);

   for(int i = 0; i < MAX_RECORDS; i++) {
      ZeroMemory(m_rec[i]);
      ZeroMemory(m_hedgeLocks[i]);
   }
   ZeroMemory(m_lbc);
   ZeroMemory(m_mkt);
   ZeroMemory(m_kalmanFast);
   ZeroMemory(m_temaFast);
   ZeroMemory(m_temaSlow);
   ZeroMemory(m_miniBlock);

   m_initialBalance       = AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity           = AccountInfoDouble(ACCOUNT_EQUITY);
   m_lotBaseEffective     = GetEffectiveLotBase();
   m_inSession            = true;
   m_postMiniBlockActive  = false;
   m_postMiniBlockCTCount = 0;
   m_lastTrailTime        = 0;

   SyncPositions();
   UpdatePortfolio();

   if(m_port.recoveryCount > 0) {
      m_recoveryActive = true;
      m_recoveryOrders = m_port.recoveryCount;
      Print("[AQ V7.7.1] HERENCIA: ", m_port.recoveryCount, " ordenes recovery");
   }
   if(m_port.hedgeLockCount > 0) {
      m_hedgeLockCount = m_port.hedgeLockCount;
      Print("[AQ V7.7.1] HERENCIA: ", m_hedgeLockCount, " hedge locks");
   }
   if(m_port.lbcCount > 0) {
      m_lbc.active = true;
      m_lbc.maxOrdersCalc = Inp_LBCMaxPairs;
      Print("[AQ V7.7.1] HERENCIA: ", m_port.lbcCount, " posiciones LBC");
   }
   if(m_port.rescueCount > 0)
      Print("[AQ V7.7.1] RESCATE: ", m_port.rescueCount, " posiciones externas");

   if(Inp_ShowDashboard) { DeleteDash(); UpdateDash(); }

   Print("[AQ V7.7.1] LISTO | Saldo=$", m_initialBalance,
         " | LoteBase=", m_lotBaseEffective,
         " | MargPor0.01=$", NormalizeDouble(CalcMarginFor001(),2));
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[AQ V7.7.1] DETENIDO | PnL=$", NormalizeDouble(m_totalPnL,2),
         " | Abiertas:", m_tradesOpened,
         " | Cerradas:", m_tradesClosed);
   ChartSetInteger(0, CHART_SHOW_TRADE_HISTORY, true);
   ChartSetInteger(0, CHART_SHOW_TRADE_LEVELS,  true);

   if(h_ATR        != INVALID_HANDLE) IndicatorRelease(h_ATR);
   if(h_EMAFast    != INVALID_HANDLE) IndicatorRelease(h_EMAFast);
   if(h_EMASlow    != INVALID_HANDLE) IndicatorRelease(h_EMASlow);
   if(h_RSI        != INVALID_HANDLE) IndicatorRelease(h_RSI);
   if(h_MACD       != INVALID_HANDLE) IndicatorRelease(h_MACD);
   if(h_ADX        != INVALID_HANDLE) IndicatorRelease(h_ADX);
   if(h_HTFEMAFast != INVALID_HANDLE) IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow != INVALID_HANDLE) IndicatorRelease(h_HTFEMASlow);
   if(h_EMA200     != INVALID_HANDLE) IndicatorRelease(h_EMA200);
   if(h_ATRSlow    != INVALID_HANDLE) IndicatorRelease(h_ATRSlow);

   if(Inp_ShowDashboard) DeleteDash();
}

//=================================================================
//  OnTick — Flujo principal V7.7.1-OPT
//=================================================================
void OnTick()
{
   m_tickCount++;

   UpdateMarket();
   UpdateKalmanPositions();
   UpdatePortfolio();

   // --- Pausa de ciclo ---
   if(m_cycleInPause) {
      if(TimeCurrent() - m_cycleResetTime >= 15) {
         m_cycleInPause         = false;
         m_recoveryActive       = false;
         m_recoveryOrders       = 0;
         m_hedgeLockCount       = 0;
         m_thirdOrderBullTicks  = 0;
         m_thirdOrderBearTicks  = 0;
         m_thirdOrderReady      = false;
         m_miniBlock.active     = false;
         m_postMiniBlockActive  = false;
         m_postMiniBlockCTCount = 0;
         DeactivateLBC();
      } else {
         UpdatePortfolio();
         if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget)
            CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard) UpdateDash();
         return;
      }
   }

   // --- Mantenimiento de registros ---
   if(TimeCurrent() - m_lastCleanupTime > 5) {
      CleanupRecs();
      SyncPositions();
      m_lastCleanupTime = TimeCurrent();
   }

   // PRIORIDAD 0: Cierre del bloque si es positivo
   if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget) {
      CloseBlockIfPositive("BlockTP");
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // PRIORIDAD 0.5: TRAILING STOP PRIMARIO (solo posicion primaria sola)
   // Condicion: exactamente 1 posicion abierta y es Primary
   // No interfiere con el cierre en bloque (ya verificado en PRIORIDAD 0)
   if(Inp_PrimaryTrailEnable && m_port.totalPos == 1)
      RunPrimaryTrailing();

   // PRIORIDAD 1: DRAWDOWN LOCK — Hedge inmediato en -$2.00
   RunDrawdownLock();

   // PRIORIDAD 2: 3ER ORDEN — Ruptura del hedge lock (TEMA+Kalman)
   if(m_hedgeLockCount > 0 && m_thirdOrderReady)
      RunThirdOrderBreaker();

   // PRIORIDAD 2.5: POST MINI-BLOCK COUNTER TRADE
   if(m_postMiniBlockActive)
      RunPostMiniBlockCounterTrade();

   // PRIORIDAD 3: MINI-BLOCK PARTIAL NETTING
   RunMiniBlockPartialNetting();

   // PRIORIDAD 4: RECOVERY matematico clasico
   RunRecoveryEngine();

   // PRIORIDAD 5: LBC micro-grid
   RunLBCEngine();

   // PRIORIDAD 6: Basket TP
   RunBasketTP();

   // PRIORIDAD 7: Harvest
   RunHarvest();

   // PRIORIDAD 8: Equity Guard (solo alarma)
   CheckEquityGuard();

   // PRIORIDAD 9: CT Engine (nuevas entradas)
   if(!m_isPaused && !m_recoveryActive && !m_lbc.active)
      RunCTEngine();

   if(Inp_ShowDashboard) UpdateDash();
}

//=================================================================
//  OnChartEvent — Botones del dashboard V7.7.1
//=================================================================
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp)
{
   if(id == CHARTEVENT_OBJECT_CLICK) {

      if(sp == "AQ77_B1") {
         m_isPaused = !m_isPaused;
         if(!m_isPaused) {
            m_emergencyMode        = false;
            m_recoveryActive       = false;
            m_recoveryOrders       = 0;
            m_thirdOrderBullTicks  = 0;
            m_thirdOrderBearTicks  = 0;
            m_thirdOrderReady      = false;
            m_miniBlock.active     = false;
            m_postMiniBlockActive  = false;
            m_postMiniBlockCTCount = 0;
            DeactivateLBC();
            Print("[AQ V7.7.1] SISTEMA REANUDADO");
         } else {
            Print("[AQ V7.7.1] PRIMARIAS PAUSADAS (recovery/hedge/mini-block/trail continuan)");
         }
      }

      if(sp == "AQ77_B2") {
         Print("[AQ V7.7.1] CIERRE MANUAL solicitado...");
         int closed = 0;

         for(int i = PositionsTotal()-1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
            if(ClosePos(t, "Manual")) closed++;
         }
         if(Inp_RescueAllTrades) {
            for(int i = PositionsTotal()-1; i >= 0; i--) {
               ulong t = PositionGetTicket(i);
               if(!PositionSelectByTicket(t)) continue;
               if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
               if(PositionGetInteger(POSITION_MAGIC) == Inp_Magic) continue;
               if(CloseRescuePos(t, "Manual_Rescue")) closed++;
            }
         }

         m_lastCTBuyPrice       = m_lastCTSellPrice = 0;
         m_consecutiveLosses    = 0;
         m_lotMultiplier        = 1.0;
         m_cycleInPause         = false;
         m_recoveryActive       = false;
         m_recoveryOrders       = 0;
         m_lastPrimaryDir       = 0;
         m_lastPrimaryLost      = false;
         m_hedgeLockCount       = 0;
         m_thirdOrderBullTicks  = 0;
         m_thirdOrderBearTicks  = 0;
         m_thirdOrderReady      = false;
         m_miniBlock.active     = false;
         m_postMiniBlockActive  = false;
         m_postMiniBlockCTCount = 0;
         m_lastTrailTime        = 0;
         for(int i=0; i<MAX_RECORDS; i++) ZeroMemory(m_hedgeLocks[i]);
         DeactivateLBC();
         Print("[AQ V7.7.1] CIERRE MANUAL: ", closed, " posiciones cerradas");
      }

      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+