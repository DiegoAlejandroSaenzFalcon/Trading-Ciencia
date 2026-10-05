//+------------------------------------------------------------------+
//|   APEXQUANT - V7.8-DYNAMIC                                       |
//|   "TEMA+KALMAN + ADAPTIVE STAGE ENGINE"                          |
//|                                                                  |
//| BASE: V7.7-PRO (TEMA+Kalman + Block Stage + Commission Fix)      |
//|                                                                  |
//| OPTIMIZACIONES V7.8-DYNAMIC:                                     |
//|                                                                  |
//| [1] DYNAMIC THRESHOLD ENGINE — Todos los umbrales USD fijos      |
//|     reemplazados por calculos adaptativos ATR+sesion+volatilidad:|
//|     - Stage1Trigger: -Inp_DynStage1Mult × ATR2USD (floor param) |
//|     - Stage3Trigger: -Inp_DynStage3Mult × ATR2USD (floor param) |
//|     - BlockTP:       +Inp_DynTPMult     × ATR2USD (floor param) |
//|     - RecovTrigger:  -Inp_DynRecovMult  × ATR2USD (floor param) |
//|     - Stage2Delay:   adaptativo por sesion (Asian>London>NY)    |
//|     - RecovDistance: adaptativo segun regimen de volatilidad     |
//|     - NetHedge L1/L2: proporcional al ATR actual del bloque     |
//|                                                                  |
//| [2] SESSION CLASSIFIER — 5 estados XAUUSD:                       |
//|     ASIAN(0-7GMT) / LONDON(7-12) / OVERLAP(12-17) / NY(17-22)  |
//|     / OFF(22-0). Factor de escala independiente por sesion.      |
//|                                                                  |
//| [3] VOLATILITY REGIME — 3 estados: LOW / NORMAL / HIGH          |
//|     ATR_fast/ATR_slow ratio. Ajusta multiplicadores en tiempo   |
//|     real. VOL_HIGH bloquea apertura de nuevas primarias.         |
//|                                                                  |
//| [4] RECOVERY CONSOLIDADO — Jerarquia sin solapamiento:           |
//|     BSE Stage Engine → Recovery Fallback → LBC Emergencia       |
//|     Net Hedge: seguro de exposicion pura (NO recovery engine)   |
//|     Cada sistema tiene condicion de activacion exclusiva.        |
//|                                                                  |
//| [5] BSE MEJORADO — Lot 3ra/4ta orden calculado dinamicamente     |
//|     segun desequilibrio actual vs distancia ATR esperada.        |
//|     Analisis Stage2 enriquecido: TEMA+Kalman + momentum ATR.    |
//|                                                                  |
//| INVARIANTES PRESERVADOS (identicos a V7.7-PRO):                 |
//|   - SL=0 en TODAS las ordenes, TP individual=0                  |
//|   - UNICO cierre: bloque neto >= m_dyn.blockTP                   |
//|   - CloseBlockIfPositive: logica intacta (umbral dinamico)      |
//|   - CalcRecoveryLot: logica de calculo preservada               |
//|   - DeactivateLBC: comportamiento identico                       |
//|   - EquityGuard NO bloquea Recovery/LBC/Stage (fix V7.3F)       |
//|   - ClosePos guard: bloquea individual con totalPos>1            |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V7.8-DYNAMIC | XAUUSD Adaptive Engine"
#property version   "7.80"
#property strict
#property description "XAUUSD | V7.8-DYNAMIC | ATR-Adaptive Thresholds | Session+Volatility Classifier"

#define VERSION_STR   "APEXQUANT_V7.8-DYNAMIC"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   80

enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

// ================================================================
//  NUEVOS ENUMS V7.8
// ================================================================
enum ENUM_SESSION_STATE {
   SESSION_ASIAN   = 0,   //  0-7 GMT: baja volatilidad
   SESSION_LONDON  = 1,   //  7-12 GMT: apertura europea
   SESSION_OVERLAP = 2,   // 12-17 GMT: solapamiento LDN+NY (mayor volatilidad)
   SESSION_NY      = 3,   // 17-22 GMT: tarde americana
   SESSION_OFF     = 4    // 22-0  GMT: fuera de horario
};

enum ENUM_VOL_REGIME {
   VOL_LOW    = 0,    // ATR < 0.65 × ATR_Slow: mercado lento
   VOL_NORMAL = 1,    // 0.65 <= ratio <= 1.5: condiciones normales
   VOL_HIGH   = 2     // ratio > 1.5: tormenta / news event
};

//=================================================================
//  PARAMETROS
//=================================================================

// ================================================================
//  [V7.8] DYNAMIC THRESHOLD ENGINE
//  Todos los umbrales en USD pasan a ser ATR × multiplicador
//  Los parametros originales actuan como FLOOR minimo de seguridad
// ================================================================
input group "=== [V7.8] DYNAMIC THRESHOLD ENGINE ==="
// Multiplicador ATR para trigger Stage1 (apertura hedge)
// -Mult × ATR2USD; nunca menor que Inp_Stage1Trigger
input double Inp_DynStage1Mult       = 1.20;
// Multiplicador ATR para trigger Stage3 (4ta orden)
// -Mult × ATR2USD; nunca menor que Inp_Stage3Trigger
input double Inp_DynStage3Mult       = 2.50;
// Multiplicador ATR para Block TP
// +Mult × ATR2USD; nunca menor que Inp_BlockTPTarget
input double Inp_DynTPMult           = 0.80;
// Multiplicador ATR para inicio de Recovery Engine fallback
// -Mult × ATR2USD; nunca menor que Inp_RecoveryTriggerUSD
input double Inp_DynRecovMult        = 0.60;
// Techo maximo Stage1 trigger (USD) — evita hedges demasiado tardios
input double Inp_DynMaxStage1USD     = 3.00;
// Techo maximo Stage3 trigger (USD)
input double Inp_DynMaxStage3USD     = 6.00;
// Techo maximo Block TP (USD) — evita targets irreales
input double Inp_DynMaxTPUSD         = 2.00;

// ================================================================
//  [V7.8] SESSION ADAPTIVE FACTORS (XAUUSD calibrado)
// ================================================================
input group "=== [V7.8] SESSION FACTORS (XAUUSD) ==="
// Factor escala Asian: mercado lento, umbrales mas ajustados
input double Inp_SessFactorAsian     = 0.65;
// Factor escala apertura Londres: referencia 1.0
input double Inp_SessFactorLondon    = 1.00;
// Factor escala solapamiento LDN+NY: maxima volatilidad
input double Inp_SessFactorOverlap   = 1.25;
// Factor escala tarde NY: algo menor que overlap
input double Inp_SessFactorNY        = 1.10;
// Factor escala fuera de sesion
input double Inp_SessFactorOff       = 0.55;

// ================================================================
//  [V7.8] STAGE2 ADAPTIVE DELAY (por sesion)
// ================================================================
input group "=== [V7.8] STAGE2 DELAY POR SESION ==="
// Delay Asian: mercados lentos necesitan mas tiempo de analisis
input int    Inp_Stage2DelayAsian    = 20;
// Delay apertura Londres
input int    Inp_Stage2DelayLondon   = 6;
// Delay overlap: mercados rapidos, decidir antes
input int    Inp_Stage2DelayOverlap  = 3;
// Delay tarde NY
input int    Inp_Stage2DelayNY       = 5;

// ================================================================
//  [V7.8] ADAPTIVE RECOVERY DISTANCE (por regimen de volatilidad)
// ================================================================
input group "=== [V7.8] RECOVERY DISTANCE ADAPTATIVO ==="
// Distancia minima entre ordenes recovery en vol. baja (ATR multiplier)
input double Inp_RecovDistLow        = 0.30;
// Distancia en volatilidad normal
input double Inp_RecovDistNormal     = 0.50;
// Distancia en volatilidad alta (mas separacion para no acumular)
input double Inp_RecovDistHigh       = 0.85;

// ================================================================
//  [V7.7] TEMA + KALMAN TREND ENGINE
// ================================================================
input group "=== [V7.7] TEMA + KALMAN TREND ENGINE ==="
input bool   Inp_UseTEMAKalman       = true;
input int    Inp_TEMAFastPeriod      = 21;
input int    Inp_TEMASlowPeriod      = 55;
input double Inp_KalmanQ             = 0.0001;
input double Inp_KalmanR             = 0.005;

// ================================================================
//  [V7.7] BLOCK STAGE ENGINE — floors de seguridad
//  NOTA V7.8: estos valores actuan como MINIMO. El sistema
//  dinamico siempre calculara valores >= a estos floors.
// ================================================================
input group "=== [V7.7] BLOCK STAGE ENGINE (FLOORS de seguridad) ==="
// Floor minimo Stage1 trigger (USD negativo)
input double Inp_Stage1Trigger       = -0.40;
// Floor minimo Stage3 trigger (USD negativo)
input double Inp_Stage3Trigger       = -0.80;
// [Obsoleto como delay directo — V7.8 usa delay por sesion]
input int    Inp_Stage2DelaySec      = 5;

// ================================================================
//  [V7.6C] VOLATILITY STORM FILTER
// ================================================================
input group "=== [V7.6C] VOLATILITY STORM FILTER ==="
input bool   Inp_UseStormFilter       = true;
input int    Inp_StormATRWindow       = 20;
input double Inp_StormATRMult         = 2.0;
input double Inp_StormSpreadMult      = 2.5;
input int    Inp_StormSpreadWindow    = 20;
input int    Inp_StormCooldownSec     = 30;

// ================================================================
//  [V7.6B] NET EXPOSURE HEDGE ENGINE
// ================================================================
input group "=== [V7.6B] NET EXPOSURE HEDGE ==="
input bool   Inp_UseNetHedge          = true;
// [V7.8] Estos son multipliers ATR ahora (en modo dinamico)
// Se usan como floors USD si ATR no disponible
input double Inp_NetHedgeTrigger1USD  = -2.0;
input double Inp_NetHedgeTrigger2USD  = -3.0;
// Multiplicadores ATR para net hedge dinamico
input double Inp_NetHedgeMult1        = 2.0;    // L1 = -2 ATRs del bloque
input double Inp_NetHedgeMult2        = 3.5;    // L2 = -3.5 ATRs del bloque
input int    Inp_NetHedgeIntervalSec  = 5;

input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic               = 1111;
input int    Inp_MaxPositionsTotal   = 8;
input double Inp_LotBase             = 0.01;
input double Inp_LotMaximum          = 0.05;
input double Inp_RiskPerTradePct     = 0.01;
input bool   Inp_UseDynamicLot       = true;
input double Inp_CTMinBalanceUSD     = 5.0;
input double Inp_MinFreeMarginPct    = 0.02;

input group "=== CIERRE DEL BLOQUE — FLOOR MINIMO ==="
// V7.8: Inp_BlockTPTarget es el FLOOR. El target real sera
// max(Inp_BlockTPTarget, ATR2USD * Inp_DynTPMult * sessionFactor)
input double Inp_BlockTPTarget       = 0.25;
input double Inp_TP_ATR              = 2.5;
input double Inp_SL_ATR              = 1.2;
input double Inp_OffSessionTP_ATR    = 2.2;
input double Inp_OffSessionSL_ATR    = 1.0;

input group "=== RECOVERY ENGINE (fallback) ==="
// V7.8: Inp_RecoveryTriggerUSD es el FLOOR del trigger dinamico
input double Inp_RecoveryTriggerUSD  = -0.20;
input double Inp_RecoveryMinDistATR  = 0.5;
input double Inp_RecoveryMoveATR     = 0.5;
input double Inp_RecoveryMinLotMult  = 2.0;
input int    Inp_RecoveryMaxOrders   = 3;
input int    Inp_RecoveryMaxOrdersTrend = 9;
input int    Inp_RecoveryIntervalSec = 3;

input group "=== LBC: CONTINGENCIA BALANCE BAJO ==="
input int    Inp_LBCMaxPairs         = 4;
input double Inp_LBCGridATR          = 0.30;
input double Inp_LBCHarvestATR       = 0.15;
input int    Inp_LBCIntervalSec      = 8;
input double Inp_LBCMarginPct        = 0.55;

input group "=== COUNTER-TRADE ENGINE ==="
input ENUM_CT_MODE Inp_CTMode        = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR       = 1.2;
input int    Inp_CTFixedPoints       = 100;
input int    Inp_CTIntervalSec       = 10;
input int    Inp_CTMaxSameDir        = 3;
input int    Inp_PrimaryCooldownSec  = 10;
input int    Inp_PrimaryCooldownOff  = 20;
input double Inp_CTMaxSpreadPoints   = 20;
input double Inp_CTMaxSpreadOff      = 10;

input group "=== SESIONES ==="
input int    Inp_GMTOffset           = 0;
input int    Inp_LondonOpen          = 7;
input int    Inp_LondonClose         = 17;
input int    Inp_NYOpen              = 13;
input int    Inp_NYClose             = 22;
input double Inp_OffSessionLotFactor = 1.0;

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
input double Inp_CycleMaxLossUSD     = -100.00;
input int    Inp_CyclePauseSec       = 30;

input group "=== ADX + HTF ==="
input bool   Inp_UseADX              = true;
input int    Inp_ADXPeriod           = 14;
input double Inp_ADXTrendLevel       = 30.0;
input double Inp_ADXTrendLevelOff    = 22.0;
input bool   Inp_UseHTF              = true;
input ENUM_TIMEFRAMES Inp_HTFTF      = PERIOD_M5;

input group "=== PROTECCION DIARIA ==="
input bool   Inp_UseDailyLimit       = true;
input double Inp_DailyLossUSD        = -140.0;
input double Inp_DailyLossPct        = 100.0;
input int    Inp_LossStreakMax        = 4;
input double Inp_LossStreakReduce     = 0.70;

input group "=== EQUITY GUARD ==="
input bool   Inp_UseEquityGuard      = true;
input double Inp_EmergencyLossUSD    = -3.0;
input double Inp_MaxDrawdownPct      = 100;
input int    Inp_EmergencyCooldown   = 10;

input group "=== INDICADORES BASE ==="
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

input group "=== [V7.5] RESCATE UNIVERSAL ==="
input bool   Inp_RescueAllTrades     = true;

input group "=== [V7.5] SENSOR HORARIO GMT ==="
input bool   Inp_UseTimeFilter       = true;
input int    Inp_UserGMT             = -5;
input int    Inp_BrokerGMT           = 2;
input string Inp_StartTime           = "07:30";
input string Inp_EndTime             = "15:00";

input group "=== [V7.5] SENSOR TENDENCIA INSTITUCIONAL ==="
input bool   Inp_UseTrendFilter200   = true;
input int    Inp_EMA200Period        = 200;

input group "=== [V7.5] SENSOR VOLATILIDAD ==="
input bool   Inp_UseVolatFilter      = true;
input int    Inp_ATRSlowPeriod       = 100;
input double Inp_ATRRatioMax         = 2.5;

input group "=== [V7.5] SENSOR MARGIN GUARD ==="
input bool   Inp_UseMarginGuard      = true;
input int    Inp_MarginGuardLevels   = 3;

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
   double atrSlow;
   double ema200;
   double temaFast;
   double temaSlow;
   double kalmanFast;
   double kalmanSlow;
   int    trendConfirmed;
};

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

struct SensorState {
   bool   timeOK;
   bool   spreadOK;
   bool   trendBull;
   bool   volatOK;
   bool   marginOK;
   bool   allOK;
   string blockReason;
   double atrRatio;
   int    brokerStartMin;
   int    brokerEndMin;
};

// ================================================================
//  [V7.8] NUEVO: DYNAMIC THRESHOLDS — calculados por tick
// ================================================================
struct DynThresholds {
   double stage1Trigger;   // Negativo USD — dispara hedge (Stage1→2)
   double stage3Trigger;   // Negativo USD — dispara 4ta orden (Stage3→4)
   double blockTP;         // Positivo USD — cierre del bloque completo
   double recovTrigger;    // Negativo USD — activa Recovery Engine fallback
   double recovDistATR;    // Multiplicador ATR minimo entre ordenes recovery
   int    stage2Delay;     // Segundos analisis Stage2 (adaptativo por sesion)
   double netHedgeTrig1;   // Trigger net hedge L1 (USD negativo)
   double netHedgeTrig2;   // Trigger net hedge L2 (USD negativo)
   double sessionFactor;   // Factor escala de sesion actual
   ENUM_SESSION_STATE session;
   ENUM_VOL_REGIME    volRegime;
   double atr2usd;         // 1 ATR en USD para 0.01 lot (cache)
};

//=================================================================
//  HANDLES
//=================================================================
int h_ATR, h_EMAFast, h_EMASlow, h_RSI, h_MACD;
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
SensorState m_sensors;
DynThresholds m_dyn;          // V7.8: umbrales dinamicos

double   m_initialBalance    = 0;
double   m_bestEquity        = 0;
bool     m_isPaused          = false;
bool     m_emergencyMode     = false;
bool     m_dailyLimitHit     = false;
bool     m_inSession         = false;
bool     m_recoveryActive    = false;
int      m_recoveryOrders    = 0;
bool     m_recoveryTrendHedge = false;

bool     m_netHedge1Applied   = false;
bool     m_netHedge2Applied   = false;
datetime m_lastNetHedgeTime   = 0;

bool     m_stormActive        = false;
datetime m_stormDetectedTime  = 0;
double   m_stormLastATRRatio  = 0.0;
double   m_stormLastSprRatio  = 0.0;

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

double   m_losingPosOpenPrice = 0;
int      m_losingPosType      = -1;

// TEMA state (fast)
double   m_temaF_e1 = 0.0, m_temaF_e2 = 0.0, m_temaF_e3 = 0.0;
bool     m_temaF_init = false;
// TEMA state (slow)
double   m_temaS_e1 = 0.0, m_temaS_e2 = 0.0, m_temaS_e3 = 0.0;
bool     m_temaS_init = false;
// Kalman state (fast TEMA)
double   m_kalF_x = 0.0, m_kalF_p = 1.0;
bool     m_kalF_init = false;
// Kalman state (slow TEMA)
double   m_kalS_x = 0.0, m_kalS_p = 1.0;
bool     m_kalS_init = false;

// Block Stage Engine state
int              m_blockStage      = 0;
ENUM_ORDER_TYPE  m_primaryType     = ORDER_TYPE_BUY;
datetime         m_stage2Time      = 0;
bool             m_stageFollowHedge = false;

// V7.8: Tracking de umbral al momento de apertura de cada stage
double   m_stage1TriggerAtOpen    = 0.0;  // Valor dinamico usado al abrir Stage1
double   m_stage3TriggerAtOpen    = 0.0;  // Valor dinamico usado al abrir Stage3

//=================================================================
//  V7.8: DYNAMIC THRESHOLD ENGINE — FUNCIONES CORE
//=================================================================

// Convierte distancia ATR en USD para un lote dado
// Para XAUUSD: DistToUSD(ATR, 0.01) ≈ ATR (precio en USD)
double ATR2USD_Lot(double atrMult, double lot)
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0 || m_mkt.atr <= 0 || lot <= 0) return 0;
   return NormalizeDouble((m_mkt.atr * atrMult / ts) * tv * lot, 4);
}

// Convierte 1 ATR en USD para el lot base (cached en m_dyn.atr2usd)
double ATR2USD(double atrMult = 1.0)
{
   return ATR2USD_Lot(atrMult, Inp_LotBase);
}

// Detecta la sesion actual del mercado basandose en GMT
ENUM_SESSION_STATE GetCurrentSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   // Convertir hora broker a GMT usando Inp_GMTOffset (offset broker vs GMT)
   int gmtH = (dt.hour - Inp_GMTOffset + 24) % 24;

   if(dt.day_of_week == 0 || dt.day_of_week == 6) return SESSION_OFF;

   if(gmtH >= 12 && gmtH < 17) return SESSION_OVERLAP;   // LDN+NY: maxima vol
   if(gmtH >= 7  && gmtH < 12) return SESSION_LONDON;
   if(gmtH >= 17 && gmtH < 22) return SESSION_NY;
   if(gmtH >= 2  && gmtH <  7) return SESSION_ASIAN;
   return SESSION_OFF;                                      // 22-2 GMT
}

// Retorna factor de escala segun sesion
double GetSessionFactor(ENUM_SESSION_STATE sess)
{
   switch(sess) {
      case SESSION_ASIAN:   return Inp_SessFactorAsian;
      case SESSION_LONDON:  return Inp_SessFactorLondon;
      case SESSION_OVERLAP: return Inp_SessFactorOverlap;
      case SESSION_NY:      return Inp_SessFactorNY;
      default:              return Inp_SessFactorOff;
   }
}

// Detecta regimen de volatilidad via ratio ATR_fast / ATR_slow
ENUM_VOL_REGIME GetVolatilityRegime()
{
   if(m_mkt.atrSlow <= 0 || m_mkt.atr <= 0) return VOL_NORMAL;
   double ratio = m_mkt.atr / m_mkt.atrSlow;
   if(ratio > 1.50) return VOL_HIGH;
   if(ratio < 0.65) return VOL_LOW;
   return VOL_NORMAL;
}

// Nombre legible del regimen de volatilidad
string VolRegimeName(ENUM_VOL_REGIME r)
{
   switch(r) {
      case VOL_LOW:    return "LOW";
      case VOL_HIGH:   return "HIGH";
      default:         return "NORMAL";
   }
}

// Nombre legible de la sesion
string SessionName(ENUM_SESSION_STATE s)
{
   switch(s) {
      case SESSION_ASIAN:   return "ASIAN";
      case SESSION_LONDON:  return "LONDON";
      case SESSION_OVERLAP: return "OVERLAP(LDN+NY)";
      case SESSION_NY:      return "NY";
      default:              return "OFF";
   }
}

// Delay adaptativo Stage2 segun sesion
int GetStage2Delay(ENUM_SESSION_STATE sess)
{
   switch(sess) {
      case SESSION_ASIAN:   return Inp_Stage2DelayAsian;
      case SESSION_LONDON:  return Inp_Stage2DelayLondon;
      case SESSION_OVERLAP: return Inp_Stage2DelayOverlap;
      case SESSION_NY:      return Inp_Stage2DelayNY;
      default:              return Inp_Stage2DelayAsian;
   }
}

// Distancia ATR para recovery segun regimen
double GetRecovDistATR(ENUM_VOL_REGIME regime)
{
   switch(regime) {
      case VOL_LOW:    return Inp_RecovDistLow;
      case VOL_HIGH:   return Inp_RecovDistHigh;
      default:         return Inp_RecovDistNormal;
   }
}

// ================================================================
//  CALCULO PRINCIPAL DE UMBRALES DINAMICOS — llamado cada tick
//  Aplica: ATR × sesion × volatilidad, con floor y techo de seguridad
// ================================================================
void UpdateDynamicThresholds()
{
   m_dyn.session    = GetCurrentSession();
   m_dyn.volRegime  = GetVolatilityRegime();
   m_dyn.sessionFactor = GetSessionFactor(m_dyn.session);

   // 1 ATR en USD para 0.01 lot (base de calculo)
   m_dyn.atr2usd = ATR2USD(1.0);
   double atr = m_dyn.atr2usd;

   // Si ATR no disponible, usar floors minimos
   if(atr <= 0.01) {
      m_dyn.stage1Trigger = Inp_Stage1Trigger;
      m_dyn.stage3Trigger = Inp_Stage3Trigger;
      m_dyn.blockTP       = Inp_BlockTPTarget;
      m_dyn.recovTrigger  = Inp_RecoveryTriggerUSD;
      m_dyn.netHedgeTrig1 = Inp_NetHedgeTrigger1USD;
      m_dyn.netHedgeTrig2 = Inp_NetHedgeTrigger2USD;
   } else {
      double sf = m_dyn.sessionFactor;

      // Stage1 trigger: negativo
      // Calculo: -1.20 × ATR × sessionFactor; floor: Inp_Stage1Trigger; techo: -DynMax
      double s1Raw = -(atr * Inp_DynStage1Mult * sf);
      s1Raw = MathMax(s1Raw, -Inp_DynMaxStage1USD);  // aplicar techo
      m_dyn.stage1Trigger = MathMin(s1Raw, Inp_Stage1Trigger);  // floor (el mas negativo)

      // Stage3 trigger: negativo
      double s3Raw = -(atr * Inp_DynStage3Mult * sf);
      s3Raw = MathMax(s3Raw, -Inp_DynMaxStage3USD);
      m_dyn.stage3Trigger = MathMin(s3Raw, Inp_Stage3Trigger);

      // Block TP: positivo
      double tpRaw = atr * Inp_DynTPMult * sf;
      tpRaw = MathMin(tpRaw, Inp_DynMaxTPUSD);
      m_dyn.blockTP = MathMax(tpRaw, Inp_BlockTPTarget);

      // Recovery trigger: negativo
      double rRaw = -(atr * Inp_DynRecovMult * sf);
      m_dyn.recovTrigger = MathMin(rRaw, Inp_RecoveryTriggerUSD);

      // Net Hedge triggers: basados en ATR actual (bloque de posiciones)
      // L1 = -2.0 ATRs, L2 = -3.5 ATRs (relativos al ATR actual)
      m_dyn.netHedgeTrig1 = MathMin(-(atr * Inp_NetHedgeMult1), Inp_NetHedgeTrigger1USD);
      m_dyn.netHedgeTrig2 = MathMin(-(atr * Inp_NetHedgeMult2), Inp_NetHedgeTrigger2USD);
   }

   // Delay Stage2 adaptativo por sesion
   m_dyn.stage2Delay = GetStage2Delay(m_dyn.session);

   // Distancia recovery adaptativa por regimen de volatilidad
   m_dyn.recovDistATR = GetRecovDistATR(m_dyn.volRegime);
}

// ================================================================
//  Calcula el lot optimo para ordenes de cobertura/recuperacion
//  del Block Stage Engine (3ra y 4ta orden).
//  Proporcional al desequilibrio actual vs distancia ATR esperada.
//  Siempre retorna al menos Inp_LotBase * 2.
// ================================================================
double CalcBSECoverLot()
{
   double atr = m_mkt.atr;
   if(atr <= 0) return NormLot(Inp_LotBase * 2.0);

   double blockLoss   = MathAbs(m_port.totalProfit);
   double totalNeeded = blockLoss + m_dyn.blockTP;
   double moveDist    = atr * Inp_RecoveryMoveATR;
   if(moveDist <= 0) moveDist = atr * 0.5;

   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double calcLot = Inp_LotBase * 2.0;
   if(tv > 0 && ts > 0 && moveDist > 0) {
      double profitPer = (moveDist / ts) * tv;
      if(profitPer > 0) calcLot = totalNeeded / profitPer;
   }

   double minLot = NormLot(Inp_LotBase * 2.0);
   return NormLot(MathMax(calcLot, minLot));
}

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

double NormPrice(double p)  { return NormalizeDouble(p, _Digits); }
bool   GetTick(MqlTick &t) { return SymbolInfoTick(_Symbol, t); }

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

bool MarginOK_Hedge(double lot, ENUM_ORDER_TYPE type)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free <= 0) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg)) {
      if(marg <= 0) return false;
      return (marg <= free * 0.90);
   }
   return false;
}

double CalcMarginFor001()
{
   double marg = 0;
   MqlTick t; GetTick(t);
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 0.01, t.ask, marg)) return 2.0;
   return (marg > 0) ? marg : 2.0;
}

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
      bool isRec  = (StringFind(comm, "REC_")    >= 0 || StringFind(comm, "BSE_") >= 0);
      bool isLBC  = (StringFind(comm, "LBC_")    >= 0);
      InitRec(idx, t, pt, op, vol, comm, isPri, isCT, isRec, isLBC);
   }
}

//=================================================================
//  KALMAN (suavizador de PnL por posicion)
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

//=================================================================
//  V7.7: TEMA + KALMAN INLINE TREND ENGINE
//=================================================================
void UpdateTEMAKalman()
{
   if(!Inp_UseTEMAKalman) {
      m_mkt.trendConfirmed = m_mkt.isBullish ? 1 : (m_mkt.isBearish ? -1 : 0);
      return;
   }

   MqlTick tk; if(!GetTick(tk)) return;
   double price = (tk.bid + tk.ask) / 2.0;
   if(price <= 0) return;

   double alphaF = 2.0 / (double)(Inp_TEMAFastPeriod + 1);
   if(!m_temaF_init) {
      m_temaF_e1 = price; m_temaF_e2 = price; m_temaF_e3 = price;
      m_temaF_init = true;
   }
   m_temaF_e1 += alphaF * (price      - m_temaF_e1);
   m_temaF_e2 += alphaF * (m_temaF_e1 - m_temaF_e2);
   m_temaF_e3 += alphaF * (m_temaF_e2 - m_temaF_e3);
   m_mkt.temaFast = 3.0 * m_temaF_e1 - 3.0 * m_temaF_e2 + m_temaF_e3;

   double alphaS = 2.0 / (double)(Inp_TEMASlowPeriod + 1);
   if(!m_temaS_init) {
      m_temaS_e1 = price; m_temaS_e2 = price; m_temaS_e3 = price;
      m_temaS_init = true;
   }
   m_temaS_e1 += alphaS * (price      - m_temaS_e1);
   m_temaS_e2 += alphaS * (m_temaS_e1 - m_temaS_e2);
   m_temaS_e3 += alphaS * (m_temaS_e2 - m_temaS_e3);
   m_mkt.temaSlow = 3.0 * m_temaS_e1 - 3.0 * m_temaS_e2 + m_temaS_e3;

   if(!m_kalF_init) { m_kalF_x = m_mkt.temaFast; m_kalF_p = 1.0; m_kalF_init = true; }
   m_kalF_p += Inp_KalmanQ;
   double kgF = m_kalF_p / (m_kalF_p + Inp_KalmanR);
   m_kalF_x  += kgF * (m_mkt.temaFast - m_kalF_x);
   m_kalF_p  *= (1.0 - kgF);
   m_mkt.kalmanFast = m_kalF_x;

   if(!m_kalS_init) { m_kalS_x = m_mkt.temaSlow; m_kalS_p = 1.0; m_kalS_init = true; }
   m_kalS_p += Inp_KalmanQ;
   double kgS = m_kalS_p / (m_kalS_p + Inp_KalmanR);
   m_kalS_x  += kgS * (m_mkt.temaSlow - m_kalS_x);
   m_kalS_p  *= (1.0 - kgS);
   m_mkt.kalmanSlow = m_kalS_x;

   bool temaBull = (m_mkt.temaFast  > m_mkt.temaSlow);
   bool temaBear = (m_mkt.temaFast  < m_mkt.temaSlow);
   bool kalBull  = (m_mkt.kalmanFast > m_mkt.kalmanSlow);
   bool kalBear  = (m_mkt.kalmanFast < m_mkt.kalmanSlow);

   if     (temaBull && kalBull) m_mkt.trendConfirmed = 1;
   else if(temaBear && kalBear) m_mkt.trendConfirmed = -1;
   else                         m_mkt.trendConfirmed = 0;

   m_mkt.isBullish = (m_mkt.trendConfirmed == 1);
   m_mkt.isBearish = (m_mkt.trendConfirmed == -1);
}

//=================================================================
//  ACTUALIZACION DE MERCADO
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
         CopyBuffer(h_HTFEMASlow, 0, 0, 1, hs) == 1)
         m_mkt.htfTrend = (hf[0] > hs[0]*1.0001) ? 1 : (hf[0] < hs[0]*0.9999) ? -1 : 0;
   }
   if(h_EMA200 != INVALID_HANDLE) {
      double e200[1];
      if(CopyBuffer(h_EMA200, 0, 1, 1, e200) == 1) m_mkt.ema200 = e200[0];
   }
   if(h_ATRSlow != INVALID_HANDLE) {
      double atrS[1];
      if(CopyBuffer(h_ATRSlow, 0, 1, 1, atrS) == 1) m_mkt.atrSlow = atrS[0];
   }

   m_mkt.isBullish = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.rsi > 52 && m_mkt.macdMain > m_mkt.macdSig);
   m_mkt.isBearish = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.rsi < 48 && m_mkt.macdMain < m_mkt.macdSig);

   UpdateTEMAKalman();

   // V7.8: Recalcular umbrales dinamicos tras actualizar ATR y sesion
   UpdateDynamicThresholds();
}

//=================================================================
//  ACTUALIZACION DE PORTFOLIO
//=================================================================
void UpdatePortfolio()
{
   ZeroMemory(m_port);
   m_port.worstProfit   = 0;
   m_losingPosOpenPrice = 0;
   m_losingPosType      = -1;

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
      else        m_port.negativeSum += MathAbs(pf);

      if(pt == POSITION_TYPE_BUY) { m_port.buyCount++;  m_port.buyProfit  += pf; m_port.buyVolume  += vol; }
      else                        { m_port.sellCount++; m_port.sellProfit += pf; m_port.sellVolume += vol; }

      vwapNumer += op * vol; vwapDenom += vol;
      m_port.blockDir += (pt == POSITION_TYPE_BUY) ? 1 : -1;

      if(pf < m_port.worstProfit) {
         m_port.worstProfit   = pf;
         m_port.worstTicket   = t;
         m_losingPosOpenPrice = op;
         m_losingPosType      = pt;
      }

      if(isOwn) {
         if(StringFind(comm, "CT_")  >= 0) m_port.ctCount++;
         if(StringFind(comm, "REC_") >= 0 || StringFind(comm, "BSE_") >= 0) m_port.recoveryCount++;
         if(StringFind(comm, "LBC_") >= 0) m_port.lbcCount++;
      }
      if(isExt) { m_port.rescueCount++; m_port.rescueProfit += pf; }
   }

   if(vwapDenom > 0) m_port.blockVWAP = vwapNumer / vwapDenom;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > m_bestEquity) m_bestEquity = eq;
   m_port.currentDD = (m_bestEquity > 0) ? (m_bestEquity - eq) / m_bestEquity : 0;
}

//=================================================================
//  V7.5: SENSORES
//=================================================================
int ParseHH(string t) { return (int)StringToInteger(StringSubstr(t, 0, 2)); }
int ParseMM(string t) { return (int)StringToInteger(StringSubstr(t, 3, 2)); }

void CalcBrokerTimeWindow()
{
   int startUserMin = ParseHH(Inp_StartTime) * 60 + ParseMM(Inp_StartTime);
   int endUserMin   = ParseHH(Inp_EndTime)   * 60 + ParseMM(Inp_EndTime);
   int offsetMin    = (Inp_BrokerGMT - Inp_UserGMT) * 60;
   m_sensors.brokerStartMin = ((startUserMin + offsetMin) % 1440 + 1440) % 1440;
   m_sensors.brokerEndMin   = ((endUserMin   + offsetMin) % 1440 + 1440) % 1440;
}

bool IsInTradingWindow()
{
   if(!Inp_UseTimeFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour * 60 + dt.min;
   int s = m_sensors.brokerStartMin, e = m_sensors.brokerEndMin;
   if(s <= e) return (nowMin >= s && nowMin < e);
   else        return (nowMin >= s || nowMin < e);
}

bool TrendFilter200OK(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseTrendFilter200) return true;
   if(m_mkt.ema200 <= 0) return true;
   MqlTick tk; if(!GetTick(tk)) return true;
   double mid = (tk.bid + tk.ask) / 2.0;
   if(type == ORDER_TYPE_BUY)  return (mid > m_mkt.ema200);
   if(type == ORDER_TYPE_SELL) return (mid < m_mkt.ema200);
   return true;
}

bool VolatilityOK()
{
   if(!Inp_UseVolatFilter) return true;
   if(m_mkt.atrSlow <= 0) return true;
   m_sensors.atrRatio = m_mkt.atr / m_mkt.atrSlow;
   return (m_sensors.atrRatio <= Inp_ATRRatioMax);
}

bool MarginGuardOK()
{
   if(!Inp_UseMarginGuard) return true;
   double lot = CalcLot(0);
   double marg1 = 0;
   MqlTick tk; if(!GetTick(tk)) return true;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, tk.ask, marg1)) return true;
   if(marg1 <= 0) return true;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return (free >= marg1 * (1.0 + Inp_MarginGuardLevels));
}

void UpdateSensors()
{
   m_sensors.blockReason = "";
   m_sensors.timeOK      = IsInTradingWindow();
   if(!m_sensors.timeOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Fuera de ventana horaria";

   m_sensors.spreadOK = SpreadOK();
   if(!m_sensors.spreadOK && m_sensors.blockReason == "") {
      int curSpr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      m_sensors.blockReason = "Spread: " + IntegerToString(curSpr) + " pts";
   }

   if(m_mkt.ema200 > 0) {
      MqlTick tk; GetTick(tk);
      m_sensors.trendBull = ((tk.bid+tk.ask)/2.0 > m_mkt.ema200);
   } else m_sensors.trendBull = true;

   m_sensors.volatOK = VolatilityOK();
   if(!m_sensors.volatOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Tormenta ATR: ratio=" + DoubleToString(m_sensors.atrRatio,1);

   // V7.8: VOL_HIGH bloquea tambien nuevas primarias como capa adicional
   if(m_dyn.volRegime == VOL_HIGH && m_sensors.volatOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Vol.Regime HIGH: pausando primarias";

   m_sensors.marginOK = MarginGuardOK();
   if(!m_sensors.marginOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Margen insuf. para " + IntegerToString(Inp_MarginGuardLevels) + " niveles";

   m_sensors.allOK = (m_sensors.timeOK   && m_sensors.spreadOK &&
                      m_sensors.volatOK  && m_sensors.marginOK &&
                      m_dyn.volRegime    != VOL_HIGH);
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
//  CONTROL DIARIO
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

bool DailyLimitReached()
{
   if(!Inp_UseDailyLimit) return false;
   if(m_dailyLimitHit) return true;
   double eff = (AccountInfoDouble(ACCOUNT_BALANCE) - m_dailyBalance) + m_port.totalProfit;
   double lim = MathMin(MathAbs(Inp_DailyLossUSD), m_dailyBalance * MathAbs(Inp_DailyLossPct));
   if(eff <= -lim) {
      Print("[AQ V7.8] LIMITE DIARIO: pausa nuevas primarias");
      m_dailyLimitHit = true; m_isPaused = true;
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
      m_lotMultiplier = 1.0; m_consecutiveLosses = 0;
   }
}

double CalcExpectancy()
{
   int total = m_totalWins + m_totalLosses;
   if(total == 0) return 0;
   double wr   = (double)m_totalWins / total;
   double avgW = (m_totalWins   > 0) ? m_sumWins   / m_totalWins   : 0;
   double avgL = (m_totalLosses > 0) ? m_sumLosses / m_totalLosses : 0;
   return (wr * avgW) - ((1.0-wr) * avgL);
}

//=================================================================
//  CIERRE
//=================================================================
bool ClosePos(ulong ticket, string reason = "")
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) return false;

   if(!m_isProcessing && m_port.totalPos > 1) {
      Print("[AQ V7.8] !! CIERRE INDIVIDUAL BLOQUEADO #", ticket,
            " [", reason, "] totalPos=", m_port.totalPos);
      return false;
   }

   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   if(m_trade.PositionClose(ticket)) {
      UpdateStreak(pf);
      if(pf > 0) { m_cycleWinsSum += pf; m_cycleWinsCount++; m_totalWins++; m_sumWins += pf; }
      else        { m_cycleLossSum += pf; m_totalLosses++; m_sumLosses += MathAbs(pf); }
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
         Print("[AQ V7.8] CERRADA #", ticket, " $", NormalizeDouble(pf,2),
               (reason!=""?" ["+reason+"]":""));
         ZeroMemory(m_rec[idx]);
      }
      return true;
   }
   return false;
}

bool CloseRescuePos(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)) {
      m_totalPnL += pf; m_tradesClosed++;
      Print("[AQ V7.8] RESCATE #", ticket, " $", NormalizeDouble(pf,2), " [", reason, "]");
      return true;
   }
   return false;
}

// INTOCABLE en logica — ahora usa m_dyn.blockTP (dinamico) en lugar de parametro fijo
bool CloseBlockIfPositive(string reason)
{
   // V7.8: umbral dinamico calculado en UpdateDynamicThresholds()
   if(m_port.totalProfit < m_dyn.blockTP) return false;

   Print("[AQ V7.8] CIERRE POSITIVO: PnL=$", NormalizeDouble(m_port.totalProfit,2),
         " >= $", NormalizeDouble(m_dyn.blockTP,2),
         " (ATR2USD=", NormalizeDouble(m_dyn.atr2usd,3), ")",
         " [", reason, "] Stage=", m_blockStage,
         " Sesion=", SessionName(m_dyn.session),
         " Rescatadas:", m_port.rescueCount);
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
            CloseRescuePos(t, "RESCUE_"+reason);
         }
      }
   }

   m_isProcessing        = false;
   m_recoveryActive      = false;
   m_recoveryOrders      = 0;
   m_recoveryTrendHedge  = false;
   m_netHedge1Applied    = false;
   m_netHedge2Applied    = false;
   m_blockStage          = 0;
   m_stageFollowHedge    = false;
   m_stage1TriggerAtOpen = 0;
   m_stage3TriggerAtOpen = 0;
   m_cycleResetTime      = TimeCurrent();
   m_cycleInPause        = true;
   m_lastCTBuyPrice      = m_lastCTSellPrice = 0;
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
   double tv = GetTickVal(), ts = GetTickSize(), lot = Inp_LotBase;
   if(tv > 0 && ts > 0 && slDist > 0) {
      double pipV = tv / ts;
      if(pipV > 0) lot = riskUSD / (slDist * pipV);
   }
   return NormLot(MathMax(lot, Inp_LotBase) * m_lotMultiplier * sessionFactor);
}

// INTOCABLE — preservado exactamente de V7.7
double CalcRecoveryLot()
{
   double atr = m_mkt.atr;
   if(atr <= 0) return NormLot(Inp_LotBase * Inp_RecoveryMinLotMult);

   // V7.8: usa blockTP dinamico para calculo
   double blockLoss   = MathAbs(m_port.totalProfit);
   double totalNeeded = blockLoss + m_dyn.blockTP;
   double moveDist    = atr * Inp_RecoveryMoveATR;
   if(moveDist <= 0) moveDist = atr * 0.5;

   double tv = GetTickVal(), ts = GetTickSize(), profitPer1LotPerDist = 0;
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

   Print("[AQ V7.8] REC LOT (LBC fallback): necesito=$", NormalizeDouble(totalNeeded,2),
         " calc=", NormalizeDouble(calcLot,2),
         " final=", NormalizeDouble(NormLot(finalLot),2),
         " [DynTP=", NormalizeDouble(m_dyn.blockTP,3), "]");
   return NormLot(finalLot);
}

//=================================================================
//  APERTURA — SL=0, TP=0 siempre
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

   bool ok = (type == ORDER_TYPE_BUY)
      ? m_trade.Buy( lot, _Symbol, price, 0, 0, comment)
      : m_trade.Sell(lot, _Symbol, price, 0, 0, comment);

   if(!ok) { Print("[AQ V7.8] ERR apertura: ", m_trade.ResultRetcodeDescription()); return 0; }

   ulong ticket = m_trade.ResultOrder();
   if(ticket > 0) {
      m_tradesOpened++;
      Print("[AQ V7.8] ABIERTA #", ticket, " ",
            (type==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=", lot, " @ ", NormalizeDouble(price,_Digits),
            " SL=0 TP=0 [", comment, "]",
            " Stage=", m_blockStage,
            " Sesion=", SessionName(m_dyn.session));
   }
   return ticket;
}

void ManagePositions() {}

//=================================================================
//  V7.8: BLOCK STAGE ENGINE — DINAMICO
//
//  Identico a V7.7 en logica, pero todos los umbrales USD
//  provienen de m_dyn (calculados adaptativamente).
//  La decision de 3ra orden en Stage2 usa ademas momentum ATR.
//=================================================================
void RunBlockStageEngine()
{
   if(m_isProcessing)       return;
   if(m_blockStage == 0)    return;
   if(m_port.totalPos == 0) { m_blockStage = 0; m_stageFollowHedge = false; return; }

   if(CloseBlockIfPositive("BSE_TP")) return;

   MqlTick tk; if(!GetTick(tk)) return;
   double totalPnL = m_port.totalProfit;

   // ── STAGE 1: Monitorea hasta Dyn Stage1 trigger ────────────
   if(m_blockStage == 1 && m_port.totalPos == 1) {
      // Usar el trigger que habia al abrir Stage1 (no cambiar en vuelo)
      double trigger1 = (m_stage1TriggerAtOpen != 0)
         ? m_stage1TriggerAtOpen : m_dyn.stage1Trigger;

      if(totalPnL <= trigger1) {
         ENUM_ORDER_TYPE hedgeType = (m_primaryType==ORDER_TYPE_BUY)
            ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         double hedgeLot = NormLot(Inp_LotBase);
         if(MarginOK(hedgeLot, hedgeType)) {
            m_isProcessing = true;
            ulong t1 = OpenOrder(hedgeType, hedgeLot, "BSE_H1", true);
            m_isProcessing = false;
            if(t1 > 0) {
               int idx = FreeRec();
               if(idx >= 0) {
                  int    pt1 = (hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
                  double op1 = (hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
                  InitRec(idx, t1, pt1, op1, hedgeLot, "BSE_H1", false, false, true, false);
               }
               m_blockStage          = 2;
               m_stage2Time          = TimeCurrent();
               m_recoveryActive      = true;
               // Registrar trigger Stage3 al entrar en Stage2
               m_stage3TriggerAtOpen = m_dyn.stage3Trigger;
               Print("[AQ V7.8] >>> STAGE 2: Hedge H1 #", t1,
                     " | PnL=$", NormalizeDouble(totalPnL,2),
                     " | Trigger1=", NormalizeDouble(trigger1,2),
                     " | Delay=", m_dyn.stage2Delay, "s",
                     " [", SessionName(m_dyn.session), "/", VolRegimeName(m_dyn.volRegime), "]");
            }
         }
      }
      return;
   }

   // ── STAGE 2: Primaria + Hedge. Analisis enriquecido V7.8 ───
   if(m_blockStage == 2 && m_port.totalPos == 2) {
      // Delay adaptativo por sesion
      if((int)(TimeCurrent() - m_stage2Time) < m_dyn.stage2Delay) return;
      if(!SpreadOK()) return;

      int trendDir   = m_mkt.trendConfirmed;   // +1=BULL, -1=BEAR, 0=NEUTRAL
      int primaryDir = (m_primaryType==ORDER_TYPE_BUY) ? 1 : -1;

      // V7.8: Analisis enriquecido Stage2 — considera momentum ATR
      // Si el ratio ATR es alto (mercado acelerado), dar mas peso a TEMA+Kalman
      bool strongTrend = (trendDir != 0 && trendDir != primaryDir);

      // En VOL_HIGH, reforzar primaria es mas arriesgado: preferir seguir tendencia
      if(m_dyn.volRegime == VOL_HIGH && trendDir != 0)
         strongTrend = (trendDir != primaryDir); // Siempre seguir tendencia si hay vol alta

      ENUM_ORDER_TYPE thirdType;
      string stage3Label;
      if(strongTrend) {
         thirdType          = (m_primaryType==ORDER_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         m_stageFollowHedge = true;
         stage3Label        = "BSE_TREND";
      } else {
         thirdType          = m_primaryType;
         m_stageFollowHedge = false;
         stage3Label        = "BSE_REINF";
      }

      // V7.8: Lot 3ra orden calculado dinamicamente segun desequilibrio
      double thirdLot = CalcBSECoverLot();
      if(MarginOK(thirdLot, thirdType)) {
         m_isProcessing = true;
         ulong t2 = OpenOrder(thirdType, thirdLot, stage3Label, true);
         m_isProcessing = false;
         if(t2 > 0) {
            int idx = FreeRec();
            if(idx >= 0) {
               int    pt2 = (thirdType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
               double op2 = (thirdType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
               InitRec(idx, t2, pt2, op2, thirdLot, stage3Label, false, false, true, false);
            }
            m_blockStage = 3;
            Print("[AQ V7.8] >>> STAGE 3", m_stageFollowHedge?"A":"B",
                  ": #", t2,
                  " ", (thirdType==ORDER_TYPE_BUY?"BUY":"SELL"),
                  " Lot=", NormalizeDouble(thirdLot,2),
                  " | TrendConf=", m_mkt.trendConfirmed,
                  " | VolReg=", VolRegimeName(m_dyn.volRegime),
                  " | PnL=$", NormalizeDouble(totalPnL,2));
         }
      } else {
         Print("[AQ V7.8] STAGE 2->3: Sin margen para 3ra -> LBC");
         ActivateLBC();
      }
      return;
   }

   // ── STAGE 3: Monitorea hasta Stage3 trigger (dinamico) ─────
   if(m_blockStage == 3) {
      double trigger3 = (m_stage3TriggerAtOpen != 0)
         ? m_stage3TriggerAtOpen : m_dyn.stage3Trigger;

      if(totalPnL <= trigger3) {
         if(!SpreadOK()) return;
         ENUM_ORDER_TYPE fourthType = m_stageFollowHedge
            ? m_primaryType
            : ((m_primaryType==ORDER_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);

         // V7.8: Lot 4ta orden tambien dinamico
         double fourthLot = CalcBSECoverLot();
         if(MarginOK(fourthLot, fourthType)) {
            m_isProcessing = true;
            ulong t3 = OpenOrder(fourthType, fourthLot, "BSE_COV4", true);
            m_isProcessing = false;
            if(t3 > 0) {
               int idx = FreeRec();
               if(idx >= 0) {
                  int    pt3 = (fourthType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
                  double op3 = (fourthType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
                  InitRec(idx, t3, pt3, op3, fourthLot, "BSE_COV4", false, false, true, false);
               }
               m_blockStage = 4;
               Print("[AQ V7.8] >>> STAGE 4: Cob4 #", t3,
                     " ", (fourthType==ORDER_TYPE_BUY?"BUY":"SELL"),
                     " Lot=", NormalizeDouble(fourthLot,2),
                     " | Trigger3=", NormalizeDouble(trigger3,2),
                     " | PnL=$", NormalizeDouble(totalPnL,2));
            }
         } else {
            Print("[AQ V7.8] STAGE 3->4: Sin margen -> LBC");
            ActivateLBC();
         }
      }
      return;
   }

   // ── STAGE 4: Exposicion maxima. Solo cierre en positivo ────
   if(m_blockStage == 4) {
      // Activar LBC si la perdida crece mas alla de 1.5x Stage3 trigger
      double lbcTrigger = m_dyn.stage3Trigger * 1.5;
      if(!m_lbc.active && totalPnL < lbcTrigger) {
         ActivateLBC();
      }
   }
}

//=================================================================
//  RECOVERY ENGINE FALLBACK — Solo para posiciones huerfanas
//  (blockStage==0 con posiciones abiertas = restart con pos activas)
//  V7.8: usa m_dyn.recovTrigger y m_dyn.recovDistATR dinamicos
//=================================================================
void RunRecoveryEngine()
{
   // V7.8: trigger dinamico
   if(m_port.totalProfit >= m_dyn.recovTrigger) {
      if(m_recoveryActive && m_blockStage == 0) {
         m_recoveryActive = false; m_recoveryOrders = 0; m_recoveryTrendHedge = false;
      }
      return;
   }
   if(m_port.totalPos == 0) return;
   if(m_isProcessing)        return;

   if(CloseBlockIfPositive("Recovery_TP")) return;

   if(!m_recoveryActive) {
      m_recoveryActive     = true;
      m_recoveryOrders     = m_port.recoveryCount;
      m_recoveryTrendHedge = false;
      Print("[AQ V7.8] RECOVERY FALLBACK | PnL=$", NormalizeDouble(m_port.totalProfit,2),
            " trigger=", NormalizeDouble(m_dyn.recovTrigger,2));
   }

   int maxRec = m_recoveryTrendHedge ? Inp_RecoveryMaxOrdersTrend : Inp_RecoveryMaxOrders;
   if(m_recoveryOrders >= maxRec) return;
   if(TimeCurrent() - m_lastRecoveryTime < Inp_RecoveryIntervalSec) return;
   if(!SpreadOK()) return;

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   // V7.8: distancia minima adaptativa segun regimen de volatilidad
   double minDist = atr * m_dyn.recovDistATR;

   if(m_losingPosOpenPrice > 0 && m_losingPosType >= 0) {
      double distFromLoser = 0;
      if(m_losingPosType == POSITION_TYPE_SELL)
         distFromLoser = tk.bid - m_losingPosOpenPrice;
      else
         distFromLoser = m_losingPosOpenPrice - tk.ask;
      if(distFromLoser < minDist) return;
   }

   ENUM_ORDER_TYPE recType;
   double adxLevel  = m_inSession ? Inp_ADXTrendLevel : Inp_ADXTrendLevelOff;
   bool   bearTrend = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.adx > adxLevel);
   bool   bullTrend = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.adx > adxLevel);

   if(m_port.buyProfit < m_port.sellProfit && bearTrend) {
      recType = ORDER_TYPE_SELL; m_recoveryTrendHedge = true;
   } else if(m_port.sellProfit < m_port.buyProfit && bullTrend) {
      recType = ORDER_TYPE_BUY;  m_recoveryTrendHedge = true;
   } else {
      m_recoveryTrendHedge = false;
      // V7.8: distancia anti-cluster dinamica
      double clusterDist = atr * 0.3;
      if(m_port.buyProfit < m_port.sellProfit) {
         recType = ORDER_TYPE_BUY;
         if(m_lastCTBuyPrice > 0 && MathAbs(tk.ask - m_lastCTBuyPrice) < clusterDist) return;
      } else {
         recType = ORDER_TYPE_SELL;
         if(m_lastCTSellPrice > 0 && MathAbs(tk.bid - m_lastCTSellPrice) < clusterDist) return;
      }
   }

   double recLot = CalcRecoveryLot();
   if(!MarginOK(recLot, recType)) {
      recLot = NormLot(recLot * 0.5);
      if(!MarginOK(recLot, recType)) {
         recLot = NormLot(Inp_LotBase);
         if(!MarginOK(recLot, recType)) { ActivateLBC(); return; }
      }
   }

   string recComm = "REC_" + (recType==ORDER_TYPE_BUY?"B":"S") +
                    "_" + IntegerToString(m_recoveryOrders+1);
   m_isProcessing = true;
   ulong ticket = OpenOrder(recType, recLot, recComm, true);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (recType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
         double op = (recType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
         InitRec(idx, ticket, pt, op, recLot, recComm, false, false, true, false);
      }
      if(recType == ORDER_TYPE_BUY) m_lastCTBuyPrice  = tk.ask;
      else                           m_lastCTSellPrice = tk.bid;
      m_recoveryOrders++;
      m_lastRecoveryTime = TimeCurrent();
   }
}

//=================================================================
//  LBC ENGINE — INTOCABLE en logica
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
   Print("[AQ V7.8] LBC ACTIVADO | LibreMarg=$", NormalizeDouble(freeMarg,2),
         " | MaxPares=", m_lbc.maxOrdersCalc);
}

// INTOCABLE
void DeactivateLBC()
{
   if(!m_lbc.active) return;
   Print("[AQ V7.8] LBC DESACTIVADO | Cosechado:$", NormalizeDouble(m_lbc.harvestedTotal,2),
         " en ", m_lbc.harvestCount, " cosechas");
   ZeroMemory(m_lbc);
}

void RunLBCEngine()
{
   if(!m_lbc.active) return;
   if(m_port.totalPos == 0) { DeactivateLBC(); return; }
   if(m_isProcessing) return;
   if(m_port.totalProfit >= m_dyn.blockTP) return;
   if(m_port.totalProfit >= m_dyn.recovTrigger * 0.5) { DeactivateLBC(); return; }

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   int nonLBCCount = m_port.totalPos - m_port.lbcCount;
   bool blockHasMainPositions = (nonLBCCount > 0);

   if(!blockHasMainPositions) {
      double harvestMin = DistToUSD(atr * Inp_LBCHarvestATR, 0.01);
      harvestMin = MathMax(harvestMin, 0.02);
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         string comm = PositionGetString(POSITION_COMMENT);
         if(StringFind(comm, "LBC_") < 0) continue;
         double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(pf >= harvestMin) {
            ClosePos(t, "LBC_Harvest");
            double freeMarg = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
            double margPer001 = CalcMarginFor001();
            m_lbc.maxOrdersCalc = (int)MathFloor(
               (freeMarg*Inp_LBCMarginPct) / (2.0*MathMax(margPer001,0.01)));
            m_lbc.maxOrdersCalc = MathMax(1, MathMin(m_lbc.maxOrdersCalc, Inp_LBCMaxPairs));
         }
      }
   }

   if(TimeCurrent() - m_lbc.lastOrderTime < Inp_LBCIntervalSec) return;
   if(!SpreadOK()) return;

   int totalLBCPairs = MathMin(m_lbc.buyCount, m_lbc.sellCount);
   if(totalLBCPairs >= m_lbc.maxOrdersCalc) return;

   double sessionMult = m_inSession ? 1.2 : 1.0;
   double gridSpace   = atr * Inp_LBCGridATR * sessionMult;
   double lot001      = NormLot(Inp_LotBase);

   bool needBuy = false, needSell = false;
   if(m_lbc.buyCount == 0 && m_lbc.sellCount == 0) {
      needBuy = true; needSell = true;
   } else {
      if(m_lbc.buyCount <= m_lbc.sellCount &&
         (m_lbc.lastBuyPrice <= 0 || MathAbs(tk.ask-m_lbc.lastBuyPrice) >= gridSpace))
         needBuy = true;
      if(m_lbc.sellCount <= m_lbc.buyCount &&
         (m_lbc.lastSellPrice <= 0 || MathAbs(tk.bid-m_lbc.lastSellPrice) >= gridSpace))
         needSell = true;
   }

   if(needBuy && MarginOK(lot001, ORDER_TYPE_BUY)) {
      string commB = "LBC_B" + IntegerToString(m_lbc.buyCount+1);
      m_isProcessing = true;
      ulong ticketB = OpenOrder(ORDER_TYPE_BUY, lot001, commB, true);
      m_isProcessing = false;
      if(ticketB > 0) {
         int idx = FreeRec();
         if(idx >= 0) InitRec(idx, ticketB, POSITION_TYPE_BUY, tk.ask, lot001, commB,
                              false, false, false, true);
         m_lbc.buyCount++; m_lbc.lastBuyPrice = tk.ask; m_lbc.lastOrderTime = TimeCurrent();
      }
   }
   if(needSell && MarginOK(lot001, ORDER_TYPE_SELL)) {
      string commS = "LBC_S" + IntegerToString(m_lbc.sellCount+1);
      m_isProcessing = true;
      ulong ticketS = OpenOrder(ORDER_TYPE_SELL, lot001, commS, true);
      m_isProcessing = false;
      if(ticketS > 0) {
         int idx = FreeRec();
         if(idx >= 0) InitRec(idx, ticketS, POSITION_TYPE_SELL, tk.bid, lot001, commS,
                              false, false, false, true);
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
   if(m_port.totalProfit < m_dyn.blockTP) return;
   double avgWin = (m_cycleWinsCount > 0) ? m_cycleWinsSum / m_cycleWinsCount : Inp_BasketTPFactor;
   double target = MathMax(m_dyn.blockTP, avgWin * Inp_BasketTPRatio);
   if(m_port.totalProfit >= target) CloseBlockIfPositive("BasketTP");
}

void CheckCycleMaxLoss()
{
   if(!Inp_UseCycleMaxLoss || m_port.totalPos == 0) return;
   if(m_port.totalProfit <= Inp_CycleMaxLossUSD) {
      Print("[AQ V7.8] CYCLE MAX LOSS: $", NormalizeDouble(m_port.totalProfit,2));
      if(!m_recoveryActive && m_blockStage == 0) {
         m_recoveryActive = true; m_recoveryOrders = 0;
      }
   }
}

//=================================================================
//  HARVEST
//=================================================================
void RunHarvest()
{
   if(m_port.totalPos > 1) return;
   if(!Inp_HarvestContinuous || m_isProcessing) return;
   if(TimeCurrent() - m_lastHarvestTime < Inp_HarvestIntervalSec) return;
   m_lastHarvestTime = TimeCurrent();
   // V7.8: usar umbral dinamico
   if(m_port.totalProfit >= m_dyn.blockTP) {
      CloseBlockIfPositive("Harvest_Single");
      return;
   }
}

//=================================================================
//  EQUITY GUARD (fix V7.3F preservado)
//=================================================================
bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   if(m_port.totalProfit <= Inp_EmergencyLossUSD && !m_emergencyMode) {
      Print("[AQ V7.8] ALERTA EQUITY: $", NormalizeDouble(m_port.totalProfit,2),
            " -> Pausa primarias. Recovery/LBC/Stage siguen.");
      m_emergencyMode = true; m_isPaused = true;
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
//  CT ENGINE — Primary entry con TEMA+Kalman V7.7
//  V7.8: m_stage1TriggerAtOpen se registra al abrir Primary
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType, double &ctLot, int &ctLevel)
{
   if(m_port.totalPos == 0) return false;
   if(m_port.totalPos >= Inp_MaxPositionsTotal) return false;
   if(m_port.totalProfit >= 0 && m_port.negativeSum == 0) return false;
   if(m_recoveryActive || m_lbc.active || m_mkt.atr <= 0) return false;

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
      if(openBuy  && m_lastCTBuyPrice  > 0 && MathAbs(t.ask-m_lastCTBuyPrice)  < ctDist) return false;
      if(openSell && m_lastCTSellPrice > 0 && MathAbs(t.bid-m_lastCTSellPrice) < ctDist) return false;
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
      // ── ENTRADA PRIMARIA ──────────────────────────────────────
      if(!m_sensors.allOK) {
         static datetime lastSensorLog = 0;
         if(TimeCurrent() - lastSensorLog >= 60) {
            Print("[AQ V7.8] ENTRADA BLOQUEADA: ", m_sensors.blockReason);
            lastSensorLog = TimeCurrent();
         }
         return;
      }
      if(m_stormActive) return;

      int cooldown = m_inSession ? Inp_PrimaryCooldownSec : Inp_PrimaryCooldownOff;
      if(TimeCurrent() - m_lastPrimaryTime < cooldown) return;

      ENUM_ORDER_TYPE initType;
      if(m_mkt.trendConfirmed == 1)         initType = ORDER_TYPE_BUY;
      else if(m_mkt.trendConfirmed == -1)   initType = ORDER_TYPE_SELL;
      else if(m_mkt.isBullish)              initType = ORDER_TYPE_BUY;
      else if(m_mkt.isBearish)             initType = ORDER_TYPE_SELL;
      else if(m_mkt.emaFast > m_mkt.emaSlow) initType = ORDER_TYPE_BUY;
      else                                  initType = ORDER_TYPE_SELL;

      if(m_lastPrimaryLost && m_lastPrimaryDir != 0) {
         ENUM_ORDER_TYPE alt = (m_lastPrimaryDir == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         if(initType != alt) { initType = alt; m_lastPrimaryLost = false; }
      }
      if(!ADXAllowsEntry(initType)) return;
      if(!TrendFilter200OK(initType)) return;
      if(!m_inSession) {
         bool clearSignal = (m_mkt.isBullish && initType==ORDER_TYPE_BUY) ||
                            (m_mkt.isBearish && initType==ORDER_TYPE_SELL);
         if(!clearSignal) return;
      }

      double lot = NormLot(Inp_LotBase);
      m_isProcessing = true;
      ulong ticket = OpenOrder(initType, lot, "Primary_Entry");
      if(ticket > 0) {
         int idx = FreeRec();
         if(idx >= 0) {
            int    pt = (initType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
            double op = (initType==ORDER_TYPE_BUY)?ts.ask:ts.bid;
            InitRec(idx, ticket, pt, op, lot, "Primary_Entry", true, false, false, false);
         }
         m_lastPrimaryDir      = (initType==ORDER_TYPE_BUY) ? 1 : -1;
         m_lastPrimaryTime     = TimeCurrent();
         if(initType==ORDER_TYPE_BUY) m_lastCTBuyPrice  = ts.ask;
         else                          m_lastCTSellPrice = ts.bid;
         m_recoveryActive      = false;
         m_recoveryOrders      = 0;
         m_recoveryTrendHedge  = false;
         m_blockStage          = 1;
         m_primaryType         = initType;
         m_stageFollowHedge    = false;
         // V7.8: Registrar triggers dinamicos al momento de la entrada
         m_stage1TriggerAtOpen = m_dyn.stage1Trigger;
         m_stage3TriggerAtOpen = m_dyn.stage3Trigger;
         DeactivateLBC();
         Print("[AQ V7.8] PRIMARY #", ticket,
               " ", (initType==ORDER_TYPE_BUY?"BUY":"SELL"),
               " | TrendConf=", m_mkt.trendConfirmed,
               " | Sesion=", SessionName(m_dyn.session),
               " | VolReg=", VolRegimeName(m_dyn.volRegime),
               " | DynStage1=", NormalizeDouble(m_stage1TriggerAtOpen,2),
               " | DynTP=", NormalizeDouble(m_dyn.blockTP,2),
               " | ATR2USD=", NormalizeDouble(m_dyn.atr2usd,3));
      }
      m_isProcessing = false;
      return;
   }

   // V7.8: CT clasico solo cuando blockStage==0 (sin bloque activo)
   if(m_blockStage > 0) return;

   ENUM_ORDER_TYPE ctType; double ctLot; int ctLevel;
   if(!ShouldOpenCT(ctType, ctLot, ctLevel)) return;
   if(!MarginOK(ctLot, ctType)) return;

   string ctComm = "CT_" + (ctType==ORDER_TYPE_BUY?"B":"S") +
                   "_L" + IntegerToString(ctLevel+1);
   m_isProcessing = true;
   ulong ticket = OpenOrder(ctType, ctLot, ctComm);
   m_isProcessing = false;
   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (ctType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
         double op = (ctType==ORDER_TYPE_BUY)?ts.ask:ts.bid;
         InitRec(idx, ticket, pt, op, ctLot, ctComm, false, true, false, false);
      }
      if(ctType==ORDER_TYPE_BUY) m_lastCTBuyPrice  = ts.ask;
      else                        m_lastCTSellPrice = ts.bid;
   }
}

//=================================================================
//  V7.6B: NET EXPOSURE HEDGE — V7.8: triggers dinamicos
//=================================================================
void RunNetExposureHedge()
{
   if(!Inp_UseNetHedge || m_port.totalPos == 0 || m_isProcessing) return;

   double netVol = NormalizeDouble(m_port.buyVolume - m_port.sellVolume, 2);
   if(MathAbs(netVol) < 0.005) return;

   double loss = m_port.totalProfit;
   // V7.8: usar triggers dinamicos
   if(loss > m_dyn.netHedgeTrig1) return;
   if(TimeCurrent() - m_lastNetHedgeTime < Inp_NetHedgeIntervalSec) return;
   if(!SpreadOK()) return;

   ENUM_ORDER_TYPE hedgeType = (netVol > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   if(loss <= m_dyn.netHedgeTrig2 && !m_netHedge2Applied) {
      double pctAlreadyCovered = m_netHedge1Applied ? 0.50 : 0.0;
      double hedgeLot = NormLot(MathAbs(netVol) * (1.0 - pctAlreadyCovered));
      if(hedgeLot > 0 && MarginOK_Hedge(hedgeLot, hedgeType)) {
         m_isProcessing = true;
         ulong ticket = OpenOrder(hedgeType, hedgeLot, "NET_HEDGE_L2", true);
         m_isProcessing = false;
         if(ticket > 0) {
            m_netHedge2Applied = m_netHedge1Applied = true;
            m_lastNetHedgeTime = TimeCurrent();
            MqlTick tk; GetTick(tk);
            int idx = FreeRec();
            if(idx >= 0) {
               int    pt = (hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
               double op = (hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
               InitRec(idx, ticket, pt, op, hedgeLot, "NET_HEDGE_L2", false, false, true, false);
            }
            Print("[AQ V7.8] NET HEDGE L2 | PnL=$", NormalizeDouble(loss,2),
                  " trigger=", NormalizeDouble(m_dyn.netHedgeTrig2,2));
         }
      }
      return;
   }

   if(loss <= m_dyn.netHedgeTrig1 && !m_netHedge1Applied) {
      double hedgeLot = NormLot(MathAbs(netVol) * 0.50);
      if(hedgeLot > 0 && MarginOK_Hedge(hedgeLot, hedgeType)) {
         m_isProcessing = true;
         ulong ticket = OpenOrder(hedgeType, hedgeLot, "NET_HEDGE_L1", true);
         m_isProcessing = false;
         if(ticket > 0) {
            m_netHedge1Applied = true;
            m_lastNetHedgeTime = TimeCurrent();
            MqlTick tk; GetTick(tk);
            int idx = FreeRec();
            if(idx >= 0) {
               int    pt = (hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
               double op = (hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
               InitRec(idx, ticket, pt, op, hedgeLot, "NET_HEDGE_L1", false, false, true, false);
            }
            Print("[AQ V7.8] NET HEDGE L1 | PnL=$", NormalizeDouble(loss,2),
                  " trigger=", NormalizeDouble(m_dyn.netHedgeTrig1,2));
         }
      }
   }
}

//=================================================================
//  V7.6C: VOLATILITY STORM FILTER
//=================================================================
double CalcAvgATR(int windowBars)
{
   if(windowBars <= 0 || h_ATR == INVALID_HANDLE) return 0;
   double buf[]; ArraySetAsSeries(buf, true);
   if(CopyBuffer(h_ATR, 0, 1, windowBars, buf) < windowBars) return 0;
   double sum = 0;
   for(int i = 0; i < windowBars; i++) sum += buf[i];
   return sum / windowBars;
}

double CalcAvgSpread(int windowBars)
{
   if(windowBars <= 0) return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   MqlRates rates[]; ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, windowBars, rates) < windowBars)
      return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double sumSpread = 0;
   for(int i = 0; i < windowBars; i++)
      sumSpread += (rates[i].high - rates[i].low) / _Point;
   return sumSpread / windowBars;
}

void RunVolatilityStormFilter()
{
   if(!Inp_UseStormFilter) { m_stormActive = false; return; }
   double atrNow = m_mkt.atr; if(atrNow <= 0) return;
   double atrAvg = CalcAvgATR(Inp_StormATRWindow);
   bool atrStorm = false;
   if(atrAvg > 0) { m_stormLastATRRatio = atrNow/atrAvg; atrStorm = (m_stormLastATRRatio >= Inp_StormATRMult); }
   double sprNow = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double sprAvg = CalcAvgSpread(Inp_StormSpreadWindow);
   bool sprStorm = false;
   if(sprAvg > 0) {
      m_stormLastSprRatio = sprNow/sprAvg;
      sprStorm = (sprNow/(double)MathMax(Inp_MaxSpread,1) > Inp_StormSpreadMult*0.5);
   }
   bool stormNow = (atrStorm || sprStorm);
   if(stormNow && !m_stormActive) {
      m_stormActive = true; m_stormDetectedTime = TimeCurrent();
      Print("[AQ V7.8] TORMENTA | ATRx=", NormalizeDouble(m_stormLastATRRatio,2));
   }
   if(m_stormActive) {
      if(TimeCurrent() - m_stormDetectedTime >= Inp_StormCooldownSec) {
         if(!stormNow) { m_stormActive = false; Print("[AQ V7.8] TORMENTA DESPEJADA"); }
         else m_stormDetectedTime = TimeCurrent();
      }
   }
}

//=================================================================
//  FILLING MODE
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
//  DASHBOARD V7.8 — agrega fila Dynamic Thresholds y Session/Vol
//=================================================================
void AQLbl(string n, string txt, int x, int y, color c, int fs=9, bool bold=false)
{
   if(ObjectFind(0,n)<0){
      ObjectCreate(0,n,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,bold?"Consolas Bold":"Consolas");
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
}

void AQBtn(string n, string txt, int x, int y, int w, int h, color bg, color fg=clrWhite)
{
   if(ObjectFind(0,n)<0){
      ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);
      ObjectSetString(0,n,OBJPROP_FONT,"Consolas");
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,fg);
}

void AQPanel(string n, int x, int y, int w, int h)
{
   if(ObjectFind(0,n)<0){
      ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_BACK,false);
      ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
   }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'8,8,12');
   ObjectSetInteger(0,n,OBJPROP_COLOR,C'70,70,70');
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
}

void DeleteDash()
{
   string names[] = {
      "AQ78_BG","AQ78_HDR","AQ78_SEP1","AQ78_STATE","AQ78_REASON",
      "AQ78_SEP2","AQ78_SENS_HDR","AQ78_S1","AQ78_S2","AQ78_S3","AQ78_S4","AQ78_S5",
      "AQ78_SEP_DYN","AQ78_SESS","AQ78_DYN1","AQ78_DYN2",
      "AQ78_SEP_TK","AQ78_TEMA","AQ78_STAGE",
      "AQ78_SEP3","AQ78_RESCUE","AQ78_SEP4","AQ78_ACC",
      "AQ78_SEP5","AQ78_PNL","AQ78_POS","AQ78_VWAP","AQ78_REC","AQ78_NH","AQ78_SF",
      "AQ78_SEP6","AQ78_HIST","AQ78_SEP7","AQ78_DIAG",
      "AQ78_B1","AQ78_B2",
      // Legacy names from V7.7 dashboard
      "AQ75_BG","AQ75_HDR","AQ75_SEP1","AQ75_STATE","AQ75_REASON",
      "AQ75_SEP2","AQ75_SENS_HDR","AQ75_S1","AQ75_S2","AQ75_S3","AQ75_S4","AQ75_S5",
      "AQ75_SEP6A","AQ75_TEMA","AQ75_STAGE","AQ75_SEP3","AQ75_RESCUE",
      "AQ75_SEP4","AQ75_ACC","AQ75_SEP5","AQ75_PNL","AQ75_POS","AQ75_VWAP",
      "AQ75_REC","AQ75_NH","AQ75_SF","AQ75_SEP6","AQ75_HIST","AQ75_SEP7","AQ75_DIAG",
      "AQ75_B1","AQ75_B2"
   };
   for(int i = 0; i < ArraySize(names); i++) ObjectDelete(0, names[i]);
}

void UpdateDash()
{
   if(!Inp_ShowDashboard) return;
   if(TimeCurrent() - m_lastDashTime < 1) return;
   m_lastDashTime = TimeCurrent();

   color cBG    = C'8,8,12';
   color cBord  = C'70,70,70';
   color cGray  = C'120,120,130';
   color cGreen = C'0,220,80';
   color cRed   = C'220,50,50';
   color cOra   = C'220,150,30';
   color cYel   = C'200,200,50';
   color cCyan  = C'50,190,220';
   color cPurp  = C'160,80,220';
   color cTeal  = C'0,190,170';
   color cMint  = C'0,200,150';

   int x0 = Inp_DashX, y0 = Inp_DashY;
   int lh = 16, pad = 8, w = 580;
   int h  = 42 * lh + 60;

   AQPanel("AQ78_BG", x0-pad, y0-pad, w, h);
   int x = x0, y = y0;

   AQLbl("AQ78_HDR", "[ " + VERSION_STR + " ]  " + _Symbol +
         "  |  ATR-ADAPTIVE + TEMA+KALMAN + SESSION ENGINE",
         x, y, cGreen, 10, true);
   y += lh + 2;

   AQLbl("AQ78_SEP1",
         "──────────────────────────────────────────────────────────────────────",
         x, y, cBord, 8);
   y += lh - 4;

   // Estado
   string stateStr; color stateC;
   if(m_emergencyMode)    { stateStr = "[ ALERTA EQUITY — RECOVERY ACTIVO ]";           stateC = cRed;  }
   else if(m_dailyLimitHit){ stateStr = "[ LIMITE DIARIO — GESTION CONTINUA ]";         stateC = cOra;  }
   else if(m_lbc.active)  { stateStr = "[ MODO LBC ACTIVO — MICRO-GRID ]";              stateC = cOra;  }
   else if(m_blockStage >= 2) {
      string snames[] = {"","PRIMARY","HEDGE","3RA_ORD","COB_MAX"};
      stateStr = "[ BSE STAGE " + IntegerToString(MathMin(m_blockStage,4)) +
                 ": " + snames[MathMin(m_blockStage,4)] +
                 (m_stageFollowHedge?" (3A-TREND)":"") + " ]";
      stateC = cYel;
   }
   else if(m_blockStage==1){ stateStr = "[ BSE STAGE 1: PRIMARIA — esp. DynTrig ]";    stateC = cCyan; }
   else if(m_recoveryActive){ stateStr = "[ RECOVERY FALLBACK ]";                       stateC = cYel;  }
   else if(m_cycleInPause)  { stateStr = "[ PAUSA ENTRE CICLOS ]";                      stateC = cGray; }
   else if(m_isPaused)      { stateStr = "[ PAUSADO — RECOVERY OPERA ]";                stateC = cYel;  }
   else if(!m_sensors.allOK){ stateStr = "[ BUSCANDO CONDICIONES ]";                    stateC = cGray; }
   else                     { stateStr = "[ BUSCANDO ENTRADA PRIMARIA ]";               stateC = cGreen;}
   AQLbl("AQ78_STATE", stateStr, x, y, stateC, 10, true);
   y += lh + 2;

   string diagStr = "";
   if(!m_sensors.allOK && m_port.totalPos == 0)
      diagStr = "  Bloqueo: " + m_sensors.blockReason;
   else if(m_port.totalPos > 0 && m_port.totalProfit < 0)
      diagStr = "  Bloque en perdida | BSE activo | Umbrales dinamicos activos";
   AQLbl("AQ78_REASON", diagStr, x, y, cGray, 8);
   y += lh - 2;

   // Sensores
   AQLbl("AQ78_SEP2","── SENSORES ──────────────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y += lh - 3;
   int curSpr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   string ratioStr = (m_mkt.atrSlow > 0) ? DoubleToString(m_sensors.atrRatio,2) : "N/A";
   AQLbl("AQ78_S1", "TIME:" + (m_sensors.timeOK?"PASS ":"WAIT "),  x,     y, m_sensors.timeOK?cGreen:cRed,   9);
   AQLbl("AQ78_S2", "SPR:" + (m_sensors.spreadOK?"PASS("+IntegerToString(curSpr)+")":"ALTO("+IntegerToString(curSpr)+")"),
         x+110, y, m_sensors.spreadOK?cGreen:cRed, 9);
   AQLbl("AQ78_S3", "TEND:" + (m_sensors.trendBull?"BULL":"BEAR"), x+240, y, m_sensors.trendBull?cGreen:cOra,9);
   AQLbl("AQ78_S4", "VOLAT:" + (m_sensors.volatOK?"OK("+ratioStr+")":"STORM("+ratioStr+")"),
         x+350, y, m_sensors.volatOK?cGreen:cRed, 9);
   y += lh - 1;
   AQLbl("AQ78_S5", "MARG:" + (m_sensors.marginOK?"PASS (>"+IntegerToString(Inp_MarginGuardLevels)+" niv)":"WAIT"),
         x, y, m_sensors.marginOK?cGreen:cOra, 9);
   y += lh;

   // V7.8: Dynamic Thresholds + Session + Volatility
   AQLbl("AQ78_SEP_DYN","── V7.8 DYNAMIC ENGINE — UMBRALES ADAPTATIVOS ─────────────────────────",x,y,C'30,60,50',8);
   y += lh - 3;

   string sessColor2str = SessionName(m_dyn.session);
   color  sessC = (m_dyn.session==SESSION_OVERLAP) ? cRed  :
                  (m_dyn.session==SESSION_NY)       ? cOra  :
                  (m_dyn.session==SESSION_LONDON)   ? cGreen:
                  (m_dyn.session==SESSION_ASIAN)    ? cCyan : cGray;
   string volStr  = VolRegimeName(m_dyn.volRegime);
   color  volC    = (m_dyn.volRegime==VOL_HIGH) ? cRed :
                    (m_dyn.volRegime==VOL_LOW)  ? cCyan: cGreen;
   AQLbl("AQ78_SESS",
         "SESION: " + sessColor2str + "  Factor=" + DoubleToString(m_dyn.sessionFactor,2) +
         "  |  VOL_REGIME: " + volStr + "  ATR2USD=" + DoubleToString(m_dyn.atr2usd,3) +
         "  |  RecovDist=" + DoubleToString(m_dyn.recovDistATR,2) + "xATR" +
         "  Delay=" + IntegerToString(m_dyn.stage2Delay) + "s",
         x, y, sessC, 9);
   y += lh - 1;
   AQLbl("AQ78_DYN1",
         "DYN TRIGGERS   Stage1=" + DoubleToString(m_dyn.stage1Trigger,2) +
         "  Stage3=" + DoubleToString(m_dyn.stage3Trigger,2) +
         "  BlockTP=+" + DoubleToString(m_dyn.blockTP,2) +
         "  RecovTrig=" + DoubleToString(m_dyn.recovTrigger,2),
         x, y, cMint, 9);
   y += lh - 1;
   AQLbl("AQ78_DYN2",
         "NET HEDGE      L1=" + DoubleToString(m_dyn.netHedgeTrig1,2) +
         "  L2=" + DoubleToString(m_dyn.netHedgeTrig2,2) +
         "  |  Floors: S1=" + DoubleToString(Inp_Stage1Trigger,2) +
         " S3=" + DoubleToString(Inp_Stage3Trigger,2) +
         " TP=" + DoubleToString(Inp_BlockTPTarget,2),
         x, y, cGray, 8);
   y += lh;

   // TEMA+Kalman + Stage
   AQLbl("AQ78_SEP_TK","── V7.7 TEMA+KALMAN + BLOCK STAGE ENGINE ────────────────────────────────",x,y,C'30,60,60',8);
   y += lh - 3;
   string trendLabel = (m_mkt.trendConfirmed==1)?"BULL CONFIRMADO":(m_mkt.trendConfirmed==-1)?"BEAR CONFIRMADO":"NEUTRAL";
   color  trendLbC   = (m_mkt.trendConfirmed==1)?cGreen:(m_mkt.trendConfirmed==-1)?cRed:cGray;
   AQLbl("AQ78_TEMA",
         "TEMA+KAL:" + (Inp_UseTEMAKalman?"ON":"OFF") +
         "  Trend=" + trendLabel +
         "  TEMAf=" + DoubleToString(m_mkt.temaFast,_Digits) +
         " TEMAs=" + DoubleToString(m_mkt.temaSlow,_Digits) +
         "  Kalf=" + DoubleToString(m_mkt.kalmanFast,_Digits) +
         " Kals=" + DoubleToString(m_mkt.kalmanSlow,_Digits),
         x, y, trendLbC, 9);
   y += lh - 1;
   string stgNames[] = {"INACTIVO","PRIMARIA 0.01","HEDGE 0.01","3RA ORD DYN","COB MAX DYN"};
   int    si2 = MathMax(0,MathMin(m_blockStage,4));
   color  stgC = (m_blockStage==0)?cGray:(m_blockStage==1)?cCyan:(m_blockStage==2)?cOra:(m_blockStage==3)?cYel:cRed;
   string trigInfo = "";
   if(m_blockStage==1) trigInfo = "  DynTrig1=" + DoubleToString(m_stage1TriggerAtOpen,2) +
                                   "  PnL=" + DoubleToString(m_port.totalProfit,2);
   else if(m_blockStage==2) trigInfo = "  Delay=" + IntegerToString((int)(TimeCurrent()-m_stage2Time)) +
                                        "s/" + IntegerToString(m_dyn.stage2Delay)+"s";
   else if(m_blockStage==3) trigInfo = "  " + (m_stageFollowHedge?"3A":"3B") +
                                        "  DynTrig3=" + DoubleToString(m_stage3TriggerAtOpen,2);
   else if(m_blockStage==4) trigInfo = "  MAX — esperando DynTP=" + DoubleToString(m_dyn.blockTP,2);
   AQLbl("AQ78_STAGE", "STAGE " + IntegerToString(si2) + ": " + stgNames[si2] + trigInfo,
         x, y, stgC, 9);
   y += lh;

   // Cuenta
   AQLbl("AQ78_SEP4","── CUENTA ───────────────────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y += lh - 3;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE), eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE), ddPct=m_port.currentDD*100.0;
   color  ddC = (ddPct>10.0)?cRed:(ddPct>5.0)?cOra:cGreen;
   AQLbl("AQ78_ACC",
         "Saldo:$"+DoubleToString(bal,2)+"  Equity:$"+DoubleToString(eq,2)+
         "  LibreMarg:$"+DoubleToString(free,2)+"  DD:"+DoubleToString(ddPct,1)+"%",
         x, y, cCyan, 9);
   y += lh;

   // Bloque activo
   AQLbl("AQ78_SEP5","── BLOQUE ACTIVO ────────────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y += lh - 3;
   double pnl = m_port.totalProfit;
   double falta = MathMax(0, m_dyn.blockTP - pnl);
   color  pnlC  = (pnl>=0)?cGreen:cRed;
   AQLbl("AQ78_PNL",
         "PnL BLOQUE:" + (pnl>=0?"+":"") + DoubleToString(pnl,2) +
         "  DynTarget:+" + DoubleToString(m_dyn.blockTP,2) +
         "  Falta:$" + DoubleToString(falta,2),
         x, y, pnlC, 9);
   y += lh - 1;
   AQLbl("AQ78_POS",
         "Pos:" + IntegerToString(m_port.totalPos) +
         "  BUY:" + IntegerToString(m_port.buyCount) + "($"+DoubleToString(m_port.buyProfit,2)+")" +
         "  SELL:" + IntegerToString(m_port.sellCount) + "($"+DoubleToString(m_port.sellProfit,2)+")" +
         "  REC:" + IntegerToString(m_port.recoveryCount) +
         " LBC:" + IntegerToString(m_port.lbcCount),
         x, y, cCyan, 9);
   y += lh - 1;
   string vwapStr = (m_port.blockVWAP>0)
      ? "VWAP:" + DoubleToString(m_port.blockVWAP,_Digits) +
        "  Dir:" + ((m_port.blockDir>0)?"LARGO":(m_port.blockDir<0)?"CORTO":"NEUTRO")
      : "Sin posiciones abiertas";
   AQLbl("AQ78_VWAP", vwapStr, x, y, cGray, 9);
   y += lh - 1;
   string recStr = m_recoveryActive
      ? "RECOVERY FB:ACTIVO ("+IntegerToString(m_recoveryOrders)+"/"+IntegerToString(Inp_RecoveryMaxOrders)+")"
        + "  RecDist=" + DoubleToString(m_dyn.recovDistATR,2)+"xATR"
      : "RECOVERY FB:standby";
   string lbcStr = m_lbc.active
      ? "  LBC:B="+IntegerToString(m_lbc.buyCount)+" S="+IntegerToString(m_lbc.sellCount)+
        " Cos=$"+DoubleToString(m_lbc.harvestedTotal,2)
      : "  LBC:standby";
   AQLbl("AQ78_REC", recStr+lbcStr, x, y, m_recoveryActive?cYel:cGray, 9);
   y += lh - 1;
   double netV = m_port.buyVolume - m_port.sellVolume;
   string nhStr; color nhC;
   if(m_netHedge2Applied) { nhStr="NET HEDGE L2(100%) ACTIVO | NetVol:"+DoubleToString(netV,2); nhC=cRed; }
   else if(m_netHedge1Applied) { nhStr="NET HEDGE L1(50%) ACTIVO | L2@$"+DoubleToString(m_dyn.netHedgeTrig2,2); nhC=cOra; }
   else { nhStr="NET HEDGE:esp L1@$"+DoubleToString(m_dyn.netHedgeTrig1,2)+" L2@$"+DoubleToString(m_dyn.netHedgeTrig2,2); nhC=cGray; }
   AQLbl("AQ78_NH", nhStr, x, y, nhC, 9);
   y += lh - 1;
   string sfStr; color sfC;
   if(m_stormActive) {
      sfStr="STORM:ACTIVO ATR="+DoubleToString(m_stormLastATRRatio,2)+"x  "+
            IntegerToString(MathMax(0,Inp_StormCooldownSec-(int)(TimeCurrent()-m_stormDetectedTime)))+"s";
      sfC=cRed;
   } else { sfStr="STORM:OK ATR="+DoubleToString(m_stormLastATRRatio,2)+"x"; sfC=cGray; }
   AQLbl("AQ78_SF", sfStr, x, y, sfC, 9);
   y += lh;

   // Historial
   AQLbl("AQ78_SEP6","── HISTORIAL ────────────────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y += lh - 3;
   int totalT=m_totalWins+m_totalLosses;
   double wrPct=(totalT>0)?(double)m_totalWins/totalT*100.0:0;
   double expect=CalcExpectancy();
   AQLbl("AQ78_HIST",
         "Win:"+DoubleToString(wrPct,1)+"% ("+IntegerToString(m_totalWins)+"/"+IntegerToString(totalT)+")" +
         "  Expect:$"+DoubleToString(expect,3)+
         "  PnL cerrado:$"+DoubleToString(m_totalPnL,2)+
         "  Ticks:"+IntegerToString((int)m_tickCount),
         x, y, (expect>=0)?cGreen:cOra, 9);
   y += lh;

   // GMT/Indicadores
   AQLbl("AQ78_SEP7","── GMT / INDICADORES ────────────────────────────────────────────────────",x,y,C'50,50,80',8);
   y += lh - 3;
   MqlDateTime dtNow; TimeToStruct(TimeCurrent(), dtNow);
   int sm=m_sensors.brokerStartMin, em=m_sensors.brokerEndMin;
   AQLbl("AQ78_DIAG",
         StringFormat("Hora:%02d:%02d  Vent:%02d:%02d-%02d:%02d",dtNow.hour,dtNow.min,sm/60,sm%60,em/60,em%60)+
         "  U:"+IntegerToString(Inp_UserGMT)+" B:"+IntegerToString(Inp_BrokerGMT)+
         "  ATR:"+DoubleToString(m_mkt.atr,2)+
         "  EMA200:"+(m_mkt.ema200>0?DoubleToString(m_mkt.ema200,1):"..."),
         x, y, cGray, 8);
   y += lh + 4;

   AQBtn("AQ78_B1", m_isPaused?">> REANUDAR <<":"|| PAUSAR PRIMARIAS", x, y, 180, 22,
         m_isPaused?C'180,130,0':C'0,90,40');
   AQBtn("AQ78_B2", "CERRAR TODAS (MANUAL)", x+190, y, 180, 22, C'150,20,20');

   ChartRedraw(0);
}

//=================================================================
//  OnInit
//=================================================================
int OnInit()
{
   Print("=============================================================");
   Print("  " + VERSION_STR + " — ATR-ADAPTIVE DYNAMIC ENGINE");
   Print("  SL=0 en TODAS las ordenes | TP individual=0");
   Print("  [V7.8] Umbrales DINAMICOS: ATR × sesion × volatilidad");
   Print("  [V7.8] Session Classifier: ASIAN/LONDON/OVERLAP/NY/OFF");
   Print("  [V7.8] Volatility Regime: LOW/NORMAL/HIGH");
   Print("  [V7.8] Recovery consolidado: jerarquia clara sin solapamiento");
   Print("  [V7.8] Stage2 delay adaptativo por sesion");
   Print("  [V7.7] TEMA+Kalman dual-confirmacion | Block Stage Engine");
   Print("  DynMults: S1=", Inp_DynStage1Mult, "x  S3=", Inp_DynStage3Mult, "x",
         "  TP=", Inp_DynTPMult, "x  Rec=", Inp_DynRecovMult, "x");
   Print("  Sess factors: Asian=", Inp_SessFactorAsian,
         " Lon=", Inp_SessFactorLondon,
         " Ovlp=", Inp_SessFactorOverlap,
         " NY=", Inp_SessFactorNY);
   Print("  Floors: Stage1=$", Inp_Stage1Trigger,
         " Stage3=$", Inp_Stage3Trigger,
         " BlockTP=$", Inp_BlockTPTarget);
   Print("=============================================================");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(DetectFillingMode());

   h_ATR     = iATR(_Symbol,  PERIOD_M1, Inp_ATRPeriod);
   h_EMAFast = iMA(_Symbol,   PERIOD_M1, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMASlow = iMA(_Symbol,   PERIOD_M1, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol,  PERIOD_M1, Inp_RSIPeriod, PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol, PERIOD_M1, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);

   if(h_ATR==INVALID_HANDLE || h_EMAFast==INVALID_HANDLE ||
      h_EMASlow==INVALID_HANDLE || h_RSI==INVALID_HANDLE || h_MACD==INVALID_HANDLE) {
      Print("[AQ V7.8] ERROR: Indicadores base no iniciados");
      return INIT_FAILED;
   }

   h_ADX        = iADX(_Symbol, PERIOD_M1, Inp_ADXPeriod);
   h_HTFEMAFast = iMA(_Symbol, Inp_HTFTF, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_HTFEMASlow = iMA(_Symbol, Inp_HTFTF, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA200     = iMA(_Symbol, PERIOD_M1, Inp_EMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ATRSlow    = iATR(_Symbol, PERIOD_M1, Inp_ATRSlowPeriod);

   if(h_EMA200  == INVALID_HANDLE) Print("[AQ V7.8] AVISO: EMA200 no creada");
   if(h_ATRSlow == INVALID_HANDLE) Print("[AQ V7.8] AVISO: ATR lento no creado");

   for(int i = 0; i < MAX_RECORDS; i++) ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc); ZeroMemory(m_sensors); ZeroMemory(m_mkt); ZeroMemory(m_dyn);

   m_temaF_init = m_temaS_init = m_kalF_init = m_kalS_init = false;
   m_blockStage = 0; m_stageFollowHedge = false;
   m_stage1TriggerAtOpen = m_stage3TriggerAtOpen = 0;

   // Inicializar thresholds con floors hasta que ATR este disponible
   m_dyn.stage1Trigger = Inp_Stage1Trigger;
   m_dyn.stage3Trigger = Inp_Stage3Trigger;
   m_dyn.blockTP       = Inp_BlockTPTarget;
   m_dyn.recovTrigger  = Inp_RecoveryTriggerUSD;
   m_dyn.stage2Delay   = Inp_Stage2DelayLondon;
   m_dyn.recovDistATR  = Inp_RecovDistNormal;
   m_dyn.netHedgeTrig1 = Inp_NetHedgeTrigger1USD;
   m_dyn.netHedgeTrig2 = Inp_NetHedgeTrigger2USD;
   m_dyn.sessionFactor = 1.0;
   m_dyn.session       = SESSION_OFF;
   m_dyn.volRegime     = VOL_NORMAL;
   m_dyn.atr2usd       = 0;

   m_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance   = m_initialBalance;
   m_lastDailyReset = TimeCurrent();

   CalcBrokerTimeWindow();
   SyncPositions();
   UpdatePortfolio();

   if(m_port.totalPos > 0) {
      Print("[AQ V7.8] Posiciones existentes (", m_port.totalPos, "): ",
            "Stage Engine en fallback hasta nueva primaria.");
   }
   if(m_port.lbcCount > 0) {
      m_lbc.active = true; m_lbc.activatedTime = TimeCurrent();
      m_lbc.maxOrdersCalc = Inp_LBCMaxPairs;
      Print("[AQ V7.8] LBC: ", m_port.lbcCount, " posiciones detectadas");
   }

   if(Inp_ShowDashboard) { DeleteDash(); UpdateDash(); }
   Print("[AQ V7.8] LISTO | Saldo=$", m_initialBalance,
         " | Marg0.01=$", NormalizeDouble(CalcMarginFor001(),2));
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[AQ V7.8] DETENIDO | PnL=$", NormalizeDouble(m_totalPnL,2),
         " | Abiertas:", m_tradesOpened, " | Cerradas:", m_tradesClosed,
         " | Win%:", NormalizeDouble((m_totalWins+m_totalLosses>0)?
            (double)m_totalWins/(m_totalWins+m_totalLosses)*100:0, 1));

   IndicatorRelease(h_ATR); IndicatorRelease(h_EMAFast);
   IndicatorRelease(h_EMASlow); IndicatorRelease(h_RSI); IndicatorRelease(h_MACD);
   if(h_ADX        != INVALID_HANDLE) IndicatorRelease(h_ADX);
   if(h_HTFEMAFast != INVALID_HANDLE) IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow != INVALID_HANDLE) IndicatorRelease(h_HTFEMASlow);
   if(h_EMA200     != INVALID_HANDLE) IndicatorRelease(h_EMA200);
   if(h_ATRSlow    != INVALID_HANDLE) IndicatorRelease(h_ATRSlow);
   if(Inp_ShowDashboard) DeleteDash();
}

//=================================================================
//  OnTick — Flujo principal V7.8
//  ORDEN DE PRIORIDAD (identica a V7.7, umbrales son dinamicos):
//  P0: Net Exposure Hedge (seguro de exposicion)
//  P1: Cierre positivo del bloque (CloseBlockIfPositive)
//  P2: Block Stage Engine (bloque activo BSE)
//     | Recovery fallback (posiciones huerfanas sin stage)
//  P3: LBC Engine (emergencia de margen)
//  P4: Basket TP
//  P5: Cycle max loss check
//  P6: Harvest (posicion sola)
//  P7: CT Engine / Primary Entry
//=================================================================
void OnTick()
{
   m_tickCount++;

   // UpdateMarket() ya llama UpdateTEMAKalman() y UpdateDynamicThresholds()
   UpdateMarket();
   UpdateKalman();
   UpdatePortfolio();

   // P0: Net Exposure Hedge (cobertura proporcional de exposicion)
   RunNetExposureHedge();

   CheckEquityGuard();
   m_inSession = IsInMainSession();
   ResetDailyIfNeeded();
   bool dailyPaused = DailyLimitReached();

   UpdateSensors();
   RunVolatilityStormFilter();

   // Pausa de ciclo
   if(m_cycleInPause) {
      if(TimeCurrent() - m_cycleResetTime >= Inp_CyclePauseSec) {
         m_cycleInPause = false; m_recoveryActive = false;
         m_recoveryOrders = 0; m_recoveryTrendHedge = false;
         m_blockStage = 0; m_stageFollowHedge = false;
         m_stage1TriggerAtOpen = m_stage3TriggerAtOpen = 0;
         DeactivateLBC();
      } else {
         UpdatePortfolio();
         if(m_port.totalPos > 0 && m_port.totalProfit >= m_dyn.blockTP)
            CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard) UpdateDash();
         return;
      }
   }

   // Modo emergencia (fix V7.3F: stage y recovery siguen)
   if(m_emergencyMode) {
      static datetime emgTime = 0;
      UpdatePortfolio();
      if(m_port.totalPos > 0 && m_port.totalProfit >= m_dyn.blockTP) {
         CloseBlockIfPositive("Emergency_TP");
         m_emergencyMode = false; emgTime = 0;
      }
      if(m_port.totalPos == 0 && emgTime == 0) emgTime = TimeCurrent();
      if(emgTime > 0 && TimeCurrent() - emgTime >= Inp_EmergencyCooldown) {
         m_emergencyMode = false; emgTime = 0;
      }
      if(m_blockStage > 0) RunBlockStageEngine();
      else                  RunRecoveryEngine();
      RunLBCEngine();
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // Mantenimiento
   if(TimeCurrent() - m_lastCleanupTime > 5) {
      CleanupRecs(); SyncPositions();
      m_lastCleanupTime = TimeCurrent();
   }

   ManagePositions();

   // P1: Cierre positivo del bloque (umbral dinamico)
   if(m_port.totalPos > 0 && m_port.totalProfit >= m_dyn.blockTP) {
      CloseBlockIfPositive("BlockTP");
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // P2: BSE o Recovery fallback (mutuamente exclusivos por blockStage)
   if(m_blockStage > 0) {
      RunBlockStageEngine();
   } else {
      RunRecoveryEngine();
   }

   // P3: LBC (solo emergencia de margen — activado por BSE/Recovery)
   RunLBCEngine();

   // P4: Basket TP
   RunBasketTP();

   // P5: Cycle max loss
   CheckCycleMaxLoss();

   // P6: Harvest (una posicion sola)
   RunHarvest();

   // P7: CT Engine / Primary Entry
   if(!m_isPaused && !m_recoveryActive && !m_lbc.active && !dailyPaused)
      RunCTEngine();

   if(Inp_ShowDashboard) UpdateDash();
}

//=================================================================
//  OnChartEvent — Botones dashboard
//=================================================================
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp)
{
   if(id == CHARTEVENT_OBJECT_CLICK) {
      if(sp == "AQ78_B1") {
         m_isPaused = !m_isPaused;
         if(!m_isPaused) {
            m_emergencyMode = false; m_dailyLimitHit = false;
            m_recoveryActive = false; m_recoveryOrders = 0; m_recoveryTrendHedge = false;
            m_netHedge1Applied = m_netHedge2Applied = false;
            m_blockStage = 0; m_stageFollowHedge = false;
            m_stage1TriggerAtOpen = m_stage3TriggerAtOpen = 0;
            DeactivateLBC();
            Print("[AQ V7.8] SISTEMA REANUDADO");
         } else {
            Print("[AQ V7.8] SISTEMA PAUSADO (Stage Engine sigue si hay posiciones)");
         }
      }
      if(sp == "AQ78_B2") {
         Print("[AQ V7.8] CIERRE MANUAL...");
         int closed = 0;
         m_isProcessing = true;
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
         m_isProcessing = false;
         m_lastCTBuyPrice = m_lastCTSellPrice = 0;
         m_consecutiveLosses = 0; m_lotMultiplier = 1.0;
         m_cycleInPause = false; m_recoveryActive = false; m_recoveryOrders = 0;
         m_lastPrimaryDir = 0; m_lastPrimaryLost = false;
         m_netHedge1Applied = m_netHedge2Applied = false;
         m_blockStage = 0; m_stageFollowHedge = false;
         m_stage1TriggerAtOpen = m_stage3TriggerAtOpen = 0;
         DeactivateLBC();
         Print("[AQ V7.8] CIERRE MANUAL: ", closed, " posiciones cerradas");
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+
