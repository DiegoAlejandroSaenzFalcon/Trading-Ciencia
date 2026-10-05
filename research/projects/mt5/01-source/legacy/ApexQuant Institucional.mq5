//+------------------------------------------------------------------+
//|   APEXQUANT - V7.6  "TREND-AWARE RECOVERY ENGINE"               |
//|                                                                  |
//| BASE: V7.6B (Net Exposure Hedge Engine)                         |
//|                                                                  |
//| NUEVO EN V7.6:                                                   |
//| [FIX CRITICO] RunRecoveryEngine - Logica de direccion corregida:|
//|   Antes (BUG): Si BUYs pierden -> abrir MAS BUYs (martingala   |
//|                ciega sin importar la tendencia del mercado).     |
//|   Ahora (FIX): Si BUYs pierden + tendencia BEAR confirmada     |
//|                -> abrir SELL (hedge con el mercado). El SELL    |
//|                gana exactamente lo mismo que pierde el BUY por  |
//|                el mismo movimiento. CalcRecoveryLot sin cambios. |
//|                Si no hay tendencia clara -> promediado clasico   |
//|                (comportamiento identico al V7.5 original).      |
//|   Parametro nuevo: Inp_RecoveryMaxOrdersTrend = max ordenes     |
//|   en modo hedge (puede ser mayor porque el mercado las ayuda).  |
//|                                                                  |
//| BASE: Diego Saenz 24H V7.3 (con fix V7.3F del EquityGuard)     |
//|                                                                  |
//| NUEVAS CARACTERISTICAS V7.5:                                    |
//|                                                                  |
//| [1] RESCATE UNIVERSAL (OMNI-RECOVERY)                           |
//|     Inp_RescueAllTrades = true/false                            |
//|     Si true: escanea TODAS las posiciones del simbolo actual,   |
//|     sin importar el Magic Number. Las operaciones manuales y de  |
//|     otros EAs se integran al bloque de recuperacion del EA.     |
//|     La logica de cierre (CloseBlockIfPositive) las cierra junto  |
//|     con las propias cuando el PnL neto total supera BlockTPTarget.|
//|     Las posiciones externas NO se registran en m_rec[] pero si  |
//|     se incluyen en m_port.totalProfit y conteos de bloque.      |
//|                                                                  |
//| [2] CAPA DE SENSORES INSTITUCIONALES (5 filtros)                |
//|     Solo bloquean nuevas entradas primarias. Si hay un ciclo    |
//|     activo (propio o rescatado), los sensores se IGNORAN para   |
//|     permitir la gestion de salida y recovery sin restricciones.  |
//|                                                                  |
//|     SENSOR 1 - HORARIO GMT DINAMICO:                           |
//|     Inputs: Inp_UserGMT, Inp_BrokerGMT, Inp_StartTime, Inp_EndTime|
//|     Conversion: La hora del usuario se convierte a hora del     |
//|     servidor del broker asi:                                     |
//|       offset = Inp_BrokerGMT - Inp_UserGMT                     |
//|       startBroker = startUser + offset                          |
//|       endBroker   = endUser   + offset                          |
//|     TimeCurrent() devuelve hora del servidor. Se compara con   |
//|     startBroker/endBroker normalizados a [0,1440] minutos.     |
//|     Ejemplo: usuario en GMT-5, broker en GMT+2, usuario quiere  |
//|     operar 07:30-15:00 local -> el broker lo recibe en 14:30-22:00|
//|                                                                  |
//|     SENSOR 2 - SPREAD PROFESIONAL:                             |
//|     Usa Inp_MaxSpread. Bloquea entrada durante rollover nocturno.|
//|                                                                  |
//|     SENSOR 3 - TENDENCIA INSTITUCIONAL (EMA 200):              |
//|     Solo BUY si precio > EMA200. Solo SELL si precio < EMA200.  |
//|     Evita ir contra la tendencia dominante de largo plazo.      |
//|                                                                  |
//|     SENSOR 4 - VOLATILIDAD ATR RATIO:                          |
//|     Si ATR(14) / ATR(Inp_ATRSlowPeriod) > Inp_ATRRatioMax(2.5)|
//|     se identifica como "Tormenta de Volatilidad" (noticias) y  |
//|     se bloquea la entrada primaria.                             |
//|                                                                  |
//|     SENSOR 5 - MARGIN GUARD:                                   |
//|     Verifica que el margen libre soporte al menos 3 niveles de  |
//|     la progresion de recovery antes de abrir una nueva primaria. |
//|                                                                  |
//| [3] DASHBOARD DARK MODE INSTITUCIONAL                           |
//|     Fondo negro solido. Bordes gris acero C'70,70,70'.          |
//|     Matriz de sensores visuales en tiempo real.                  |
//|     Estado del bloque, rescue, cuenta y sensores en un panel.   |
//|     Boton PAUSA afecta tanto operativa propia como rescate.     |
//|                                                                  |
//| INVARIANTES INAMOVIBLES (heredados de V7.3F):                  |
//|   - SL = 0 en TODAS las ordenes (broker nunca cierra auto)     |
//|   - TP individual = 0                                           |
//|   - UNICO cierre: bloque neto > BlockTPTarget                  |
//|   - EquityGuard NO bloquea Recovery/LBC (fix V7.3F preservado) |
//|   - CalcRecoveryLot: INTOCABLE                                  |
//|   - DeactivateLBC:   INTOCABLE                                  |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V7.6C - Volatility Storm Filter Engine"
#property version   "7.62"
#property strict
#property description "XAUUSD 24/7 | ApexQuant V7.6 | Trend-Aware Recovery + Rescue Universal + 5 Sensores"

#define VERSION_STR   "APEXQUANT_V7.6C"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   80

enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

//=================================================================
//  PARAMETROS - TODOS LOS DE V7.3 PRESERVADOS
//=================================================================

// ================================================================
//  [V7.6C] VOLATILITY STORM FILTER — SOLO BLOQUEA PRIMARY_ENTRY
//
//  Detecta tormentas institucionales (flash crash, noticias NFP, FOMC)
//  midiendo la ACELERACION del ATR y del spread en ventanas recientes.
//
//  PRINCIPIO: Si el ATR actual supera N veces el ATR promedio de las
//  ultimas M barras, el mercado esta en tormenta — no es momento de
//  abrir una nueva posicion primaria. Una vez abierta, el EA resuelve
//  el bloque completo sin que este filtro intervenga.
//
//  NUNCA afecta: Recovery, CT, LBC, Net Hedge, gestion de bloque abierto.
//  SOLO afecta: La apertura de la proxima Primary_Entry.
// ================================================================
input group "=== [V7.6C] VOLATILITY STORM FILTER (Solo Primary_Entry) ==="
// Activa el filtro de tormenta de volatilidad para nuevas primarias
input bool   Inp_UseStormFilter       = true;
// Numero de barras M1 hacia atras para calcular el ATR promedio de referencia
input int    Inp_StormATRWindow       = 14;
// Si ATR_actual > Inp_StormATRMult * ATR_promedio -> tormenta (NO abrir primaria)
// Valor recomendado: 2.0 (el ATR actual es el doble del promedio reciente)
input double Inp_StormATRMult         = 1.0;
// Si spread_actual > Inp_StormSpreadMult * spread_promedio -> tormenta
// Spread alto indica rollover nocturno o flash-crash
input double Inp_StormSpreadMult      = 1.0;
// Ventana de barras para calcular el spread promedio de referencia
input int    Inp_StormSpreadWindow    = 20;
// Segundos que el filtro mantiene bloqueada la primaria tras detectar tormenta
// (evita entrar inmediatamente cuando el ATR baja un tick momentaneamente)
input int    Inp_StormCooldownSec     = 180;

// ================================================================
//  [V7.6B] NET EXPOSURE HEDGE ENGINE — NUEVO (SOLO ADICIONES)
//  Abre ordenes opuestas proporcionales a la exposicion neta cuando
//  la perdida del bloque supera los umbrales configurados.
//  NUNCA cierra posiciones existentes. Solo abre nuevas coberturas.
// ================================================================
input group "=== [V7.6B] NET EXPOSURE HEDGE ==="
// Activa el hedge de exposicion neta graduado
input bool   Inp_UseNetHedge          = true;
// Nivel 1: cubre el 50% de la exposicion neta (vol neto descubierto)
// Ej: si tienes LONG neto 0.02, abre SELL 0.01
input double Inp_NetHedgeTrigger1USD  = -0.50;
// Nivel 2: cubre el 100% de la exposicion neta
// Ej: abre SELL adicional 0.02 -> total cubierto = 0.04
input double Inp_NetHedgeTrigger2USD  = -1.0;
// Segundos minimos entre operaciones de hedge (evita rafagas)
input int    Inp_NetHedgeIntervalSec  = 1;

input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic               = 1111;
input int    Inp_MaxPositionsTotal   = 10;
input double Inp_LotBase             = 0.01;
input double Inp_LotMaximum          = 0.03;
input double Inp_RiskPerTradePct     = 0.01;
input bool   Inp_UseDynamicLot       = true;
input double Inp_CTMinBalanceUSD     = 20.0;
input double Inp_MinFreeMarginPct    = 0.10;

input group "=== CIERRE DEL BLOQUE - UNICO MODO DE CIERRE ==="
input double Inp_BlockTPTarget       = 0.50;
input double Inp_TP_ATR              = 1.0;
input double Inp_SL_ATR              = 0.5;
input double Inp_OffSessionTP_ATR    = 1.0;
input double Inp_OffSessionSL_ATR    = 0.5;

input group "=== RECOVERY ENGINE ==="
input double Inp_RecoveryTriggerUSD  = -0.50;
input double Inp_RecoveryMinDistATR  = 0.5;
input double Inp_RecoveryMoveATR     = 0.5;
input double Inp_RecoveryMinLotMult  = 2.0;
input int    Inp_RecoveryMaxOrders   = 6;
// V7.6: Max ordenes en modo hedge (tendencia confirmada). Puede ser mayor
// porque cada orden gana con el mercado en lugar de acumular en su contra.
input int    Inp_RecoveryMaxOrdersTrend = 6;
input int    Inp_RecoveryIntervalSec = 1;

input group "=== LBC: CONTINGENCIA BALANCE BAJO ==="
input int    Inp_LBCMaxPairs         = 4;
input double Inp_LBCGridATR          = 0.30;
input double Inp_LBCHarvestATR       = 0.15;
input int    Inp_LBCIntervalSec      = 3;
input double Inp_LBCMarginPct        = 0.55;

input group "=== COUNTER-TRADE ENGINE ==="
input ENUM_CT_MODE Inp_CTMode        = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR       = 0.5;
input int    Inp_CTFixedPoints       = 100;
input int    Inp_CTIntervalSec       = 10;
input int    Inp_CTMaxSameDir        = 10;
input int    Inp_PrimaryCooldownSec  = 1;
input int    Inp_PrimaryCooldownOff  = 1;
input double Inp_CTMaxSpreadPoints   = 25;
input double Inp_CTMaxSpreadOff      = 20;

input group "=== SESIONES ==="
input int    Inp_GMTOffset           = 0;
input int    Inp_LondonOpen          = 7;
input int    Inp_LondonClose         = 17;
input int    Inp_NYOpen              = 13;
input int    Inp_NYClose             = 22;
input double Inp_OffSessionLotFactor = 1.0;

input group "=== BASKET TP ==="
input bool   Inp_UseBasketTP         = true;
input double Inp_BasketTPFactor      = 0.50;
input double Inp_BasketTPRatio       = 0.50;
input int    Inp_BasketCheckSec      = 1;

input group "=== HARVEST ==="
input double Inp_HarvestMinUSD       = 0.80;
input double Inp_HarvestATRMult      = 0.20;
input bool   Inp_HarvestContinuous   = true;
input int    Inp_HarvestIntervalSec  = 3;

input group "=== CYCLE CONTROL ==="
input bool   Inp_UseCycleMaxLoss     = true;
input double Inp_CycleMaxLossUSD     = -1.00;
input int    Inp_CyclePauseSec       = 3;

input group "=== ADX + HTF ==="
input bool   Inp_UseADX              = true;
input int    Inp_ADXPeriod           = 14;
input double Inp_ADXTrendLevel       = 25.0;
input double Inp_ADXTrendLevelOff    = 20.0;
input bool   Inp_UseHTF              = true;
input ENUM_TIMEFRAMES Inp_HTFTF      = PERIOD_M5;

input group "=== PROTECCION DIARIA (solo pausa) ==="
input bool   Inp_UseDailyLimit       = false;
input double Inp_DailyLossUSD        = -90.0;
input double Inp_DailyLossPct        = 70;
input int    Inp_LossStreakMax        = 2;
input double Inp_LossStreakReduce     = 0.50;

input group "=== EQUITY GUARD (solo pausa, recovery sigue) ==="
input bool   Inp_UseEquityGuard      = true;
input double Inp_EmergencyLossUSD    = -3.0;
input double Inp_MaxDrawdownPct      = 0.10;
input int    Inp_EmergencyCooldown   = 5;

input group "=== INDICADORES BASE ==="
input int    Inp_ATRPeriod           = 14;
input int    Inp_EMAFast             = 21;
input int    Inp_EMASlow             = 55;
input int    Inp_RSIPeriod           = 2;
input int    Inp_MACDFast            = 12;
input int    Inp_MACDSlow            = 26;
input int    Inp_MACDSig             = 9;

input group "=== CONTROL VISUAL ==="
input int    Inp_MaxSpread           = 20;
input bool   Inp_ShowDashboard       = true;
input int    Inp_DashX               = 10;
input int    Inp_DashY               = 30;

// ================================================================
//  NUEVOS PARAMETROS V7.5
// ================================================================
input group "=== [V7.5] RESCATE UNIVERSAL ==="
// Si true: incluye TODAS las posiciones del simbolo (sin filtro de magic)
// en el calculo de PnL total y en el cierre del bloque.
// Las posiciones rescatadas se cierran junto con las propias al alcanzar el TP.
input bool   Inp_RescueAllTrades     = true;

input group "=== [V7.5] SENSOR 1: HORARIO GMT DINAMICO ==="
input bool   Inp_UseTimeFilter       = false;
// GMT del usuario (su zona horaria local). Ej: -5 para EST, -3 para BRT, +1 para CET
input int    Inp_UserGMT             = -5;
// GMT del servidor del broker (verificar en la esquina inferior derecha de MT5)
input int    Inp_BrokerGMT           = 2;
// Hora de inicio en horario LOCAL del usuario (formato HH:MM)
input string Inp_StartTime           = "07:30";
// Hora de fin en horario LOCAL del usuario (formato HH:MM)
input string Inp_EndTime             = "15:00";

input group "=== [V7.5] SENSOR 3: TENDENCIA INSTITUCIONAL ==="
input bool   Inp_UseTrendFilter200   = true;
// Periodo de la EMA institucional. EMA200 = tendencia de largo plazo.
input int    Inp_EMA200Period        = 200;

input group "=== [V7.5] SENSOR 4: VOLATILIDAD (TORMENTA ATR) ==="
input bool   Inp_UseVolatFilter      = true;
// Periodo del ATR lento para el ratio. ATR14/ATR_slow > ATRRatioMax = tormenta.
input int    Inp_ATRSlowPeriod       = 100;
// Ratio maximo ATR rapido/lento. Por encima de este valor = noticias/tormenta.
input double Inp_ATRRatioMax         = 2.5;

input group "=== [V7.5] SENSOR 5: MARGIN GUARD ==="
input bool   Inp_UseMarginGuard      = true;
// Minimo de niveles de recovery que el margen libre debe poder soportar
// antes de abrir una nueva entrada primaria.
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
   // --- V7.5: Campos de Rescate Universal ---
   int    rescueCount;     // Posiciones externas detectadas
   double rescueProfit;    // PnL de posiciones externas
   // --- V7.6B: Volumen por direccion para calculo de exposicion neta ---
   double buyVolume;       // Volumen total comprado (lotes)
   double sellVolume;      // Volumen total vendido (lotes)
};

struct MarketSnap {
   double bid, ask, atr, emaFast, emaSlow, rsi, macdMain, macdSig, adx, spread;
   int    htfTrend;
   bool   isBullish, isBearish;
   // --- V7.5: Nuevos campos de mercado ---
   double atrSlow;  // ATR(Inp_ATRSlowPeriod) para ratio de volatilidad
   double ema200;   // EMA(200) para tendencia institucional
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

// --- V7.5: Estado de los 5 sensores institucionales ---
struct SensorState {
   bool   timeOK;       // Sensor 1: Dentro de ventana horaria
   bool   spreadOK;     // Sensor 2: Spread aceptable
   bool   trendBull;    // Sensor 3: Precio > EMA200 (sesgo alcista)
   bool   volatOK;      // Sensor 4: ATR ratio < limite
   bool   marginOK;     // Sensor 5: Margen para 3+ niveles de recovery
   bool   allOK;        // Todos los sensores OK para nueva entrada primaria
   string blockReason;  // Razon de bloqueo (para dashboard)
   double atrRatio;     // ATR rapido / ATR lento (informativo)
   int    brokerStartMin; // Inicio de ventana en hora del broker (minutos)
   int    brokerEndMin;   // Fin de ventana en hora del broker (minutos)
};

//=================================================================
//  HANDLES
//=================================================================
int h_ATR, h_EMAFast, h_EMASlow, h_RSI, h_MACD;
int h_ADX        = INVALID_HANDLE;
int h_HTFEMAFast = INVALID_HANDLE;
int h_HTFEMASlow = INVALID_HANDLE;
// V7.5 nuevos handles
int h_ATRSlow    = INVALID_HANDLE; // ATR lento para ratio de volatilidad
int h_EMA200     = INVALID_HANDLE; // EMA 200 institucional

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade     m_trade;
PosRecord  m_rec[MAX_RECORDS];
Portfolio  m_port;
MarketSnap m_mkt;
LBCState   m_lbc;
SensorState m_sensors; // V7.5

double   m_initialBalance    = 0;
double   m_bestEquity        = 0;
bool     m_isPaused          = false;
bool     m_emergencyMode     = false;
bool     m_dailyLimitHit     = false;
bool     m_inSession         = false;
bool     m_recoveryActive    = false;
int      m_recoveryOrders    = 0;
bool     m_recoveryTrendHedge = false; // V7.6: true = modo hedge (sigue tendencia)

// --- V7.6B: Estado del Net Exposure Hedge ---
bool     m_netHedge1Applied   = false; // L1 (50%) ya aplicado en este ciclo
bool     m_netHedge2Applied   = false; // L2 (100%) ya aplicado en este ciclo
datetime m_lastNetHedgeTime   = 0;     // Timestamp del ultimo hedge abierto

// --- V7.6C: Estado del Volatility Storm Filter ---
bool     m_stormActive        = false; // true = tormenta detectada, bloquear primaria
datetime m_stormDetectedTime  = 0;     // Cuando se detecto la ultima tormenta
double   m_stormLastATRRatio  = 0.0;   // Ratio ATR actual/promedio informativo
double   m_stormLastSprRatio  = 0.0;   // Ratio spread actual/promedio informativo

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

//=================================================================
//  HELPERS (PRESERVADOS DE V7.3)
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

// V7.6B: MarginOK_Hedge — verificacion permisiva para ordenes de cobertura.
// En cuentas hedge (Pepperstone), abrir SELL contra un BUY existente reduce la
// exposicion neta aunque el broker exija margen por ambos lados.
// Permite abrir si hay margen suficiente para cubrir la orden al 90% del libre.
bool MarginOK_Hedge(double lot, ENUM_ORDER_TYPE type)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free <= 0) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg)) {
      if(marg <= 0) return false;
      return (marg <= free * 0.90); // Usa hasta el 90% del margen libre disponible
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
//  RECORDS (PRESERVADOS DE V7.3)
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
//  KALMAN (PRESERVADO DE V7.3)
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
//  SESION (PRESERVADA DE V7.3)
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
//  ACTUALIZACION DE MERCADO - V7.5: agrega EMA200 y ATR lento
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
   // V7.5: EMA 200 institucional
   if(h_EMA200 != INVALID_HANDLE) {
      double e200[1];
      if(CopyBuffer(h_EMA200, 0, 1, 1, e200) == 1) m_mkt.ema200 = e200[0];
   }
   // V7.5: ATR lento para ratio de volatilidad
   if(h_ATRSlow != INVALID_HANDLE) {
      double atrS[1];
      if(CopyBuffer(h_ATRSlow, 0, 1, 1, atrS) == 1) m_mkt.atrSlow = atrS[0];
   }

   m_mkt.isBullish = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.rsi > 52 && m_mkt.macdMain > m_mkt.macdSig);
   m_mkt.isBearish = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.rsi < 48 && m_mkt.macdMain < m_mkt.macdSig);
}

//=================================================================
//  ACTUALIZACION DE PORTFOLIO - V7.5: extiende con Rescate Universal
//
//  Cuando Inp_RescueAllTrades=true, el EA escanea TODAS las posiciones
//  del _Symbol sin filtro de magic. Las posiciones externas se suman
//  a totalProfit, totalPos, buyCount/sellCount y VWAP del bloque.
//  Esto hace que la logica de recovery y cierre las trate como propias.
//=================================================================
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
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   magic = PositionGetInteger(POSITION_MAGIC);
      bool   isOwn = (magic == Inp_Magic);
      bool   isExt = (!isOwn && Inp_RescueAllTrades);

      // Solo procesar posiciones propias O externas en modo rescate
      if(!isOwn && !isExt) continue;

      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double pf   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      string comm = PositionGetString(POSITION_COMMENT);

      m_port.totalPos++;
      m_port.totalProfit += pf;
      if(pf >= 0) m_port.positiveSum += pf;
      else        m_port.negativeSum += MathAbs(pf);

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

      // Contadores por tipo (solo posiciones propias)
      if(isOwn) {
         if(StringFind(comm, "CT_")  >= 0) m_port.ctCount++;
         if(StringFind(comm, "REC_") >= 0) m_port.recoveryCount++;
         if(StringFind(comm, "LBC_") >= 0) m_port.lbcCount++;
      }

      // Contadores de rescate (posiciones externas)
      if(isExt) {
         m_port.rescueCount++;
         m_port.rescueProfit += pf;
      }
   }

   if(vwapDenom > 0) m_port.blockVWAP = vwapNumer / vwapDenom;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > m_bestEquity) m_bestEquity = eq;
   m_port.currentDD = (m_bestEquity > 0) ? (m_bestEquity - eq) / m_bestEquity : 0;
}

//=================================================================
//  V7.5: FUNCIONES DE SOPORTE PARA SENSORES
//=================================================================

// Parsea la hora de un string "HH:MM" -> hora entera
int ParseHH(string t) { return (int)StringToInteger(StringSubstr(t, 0, 2)); }
// Parsea los minutos de un string "HH:MM" -> minutos enteros
int ParseMM(string t) { return (int)StringToInteger(StringSubstr(t, 3, 2)); }

// Convierte la ventana horaria del usuario a minutos del servidor del broker.
// Logica GMT:
//   El servidor del broker usa Inp_BrokerGMT como su UTC offset.
//   El usuario especifica su hora local segun Inp_UserGMT.
//   Para convertir hora local del usuario a hora del servidor:
//     horaBroker = horaUsuario + (Inp_BrokerGMT - Inp_UserGMT)
//   Normalizamos a [0,1440) para manejar cruces de medianoche.
void CalcBrokerTimeWindow()
{
   int startUserMin = ParseHH(Inp_StartTime) * 60 + ParseMM(Inp_StartTime);
   int endUserMin   = ParseHH(Inp_EndTime)   * 60 + ParseMM(Inp_EndTime);
   int offsetMin    = (Inp_BrokerGMT - Inp_UserGMT) * 60;

   m_sensors.brokerStartMin = ((startUserMin + offsetMin) % 1440 + 1440) % 1440;
   m_sensors.brokerEndMin   = ((endUserMin   + offsetMin) % 1440 + 1440) % 1440;
}

// SENSOR 1: Verifica si estamos dentro de la ventana horaria del usuario
bool IsInTradingWindow()
{
   if(!Inp_UseTimeFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour * 60 + dt.min;
   int s = m_sensors.brokerStartMin;
   int e = m_sensors.brokerEndMin;
   if(s <= e)
      return (nowMin >= s && nowMin < e);
   else // Cruce de medianoche (ej: 22:00 a 06:00 del dia siguiente)
      return (nowMin >= s || nowMin < e);
}

// SENSOR 3: Tendencia institucional EMA200 segun la direccion de la orden
bool TrendFilter200OK(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseTrendFilter200) return true;
   if(m_mkt.ema200 <= 0) return true; // EMA no inicializada aun, permitir
   MqlTick tk; if(!GetTick(tk)) return true;
   double mid = (tk.bid + tk.ask) / 2.0;
   if(type == ORDER_TYPE_BUY)  return (mid > m_mkt.ema200);
   if(type == ORDER_TYPE_SELL) return (mid < m_mkt.ema200);
   return true;
}

// SENSOR 4: Ratio de volatilidad ATR(rapido)/ATR(lento)
bool VolatilityOK()
{
   if(!Inp_UseVolatFilter) return true;
   if(m_mkt.atrSlow <= 0) return true; // ATR lento no inicializado, permitir
   m_sensors.atrRatio = m_mkt.atr / m_mkt.atrSlow;
   return (m_sensors.atrRatio <= Inp_ATRRatioMax);
}

// SENSOR 5: Margen suficiente para N niveles de recovery antes de entrar
bool MarginGuardOK()
{
   if(!Inp_UseMarginGuard) return true;
   double lot    = CalcLot(0); // Lote de la primaria que se va a abrir
   double marg1  = 0;
   MqlTick tk; if(!GetTick(tk)) return true;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, tk.ask, marg1)) return true;
   if(marg1 <= 0) return true;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   // El margen libre debe poder soportar: la nueva posicion + N niveles de recovery
   return (free >= marg1 * (1.0 + Inp_MarginGuardLevels));
}

//=================================================================
//  V7.5: ACTUALIZACION DE SENSORES INSTITUCIONALES
//  Se llama una vez por tick antes de RunCTEngine.
//  Los sensores solo afectan Primary_Entry. Si hay un ciclo activo,
//  la gestion de ese ciclo (CT, Recovery, LBC) no se ve afectada.
//=================================================================
void UpdateSensors()
{
   m_sensors.blockReason = "";

   // Sensor 1: Horario
   m_sensors.timeOK = IsInTradingWindow();
   if(!m_sensors.timeOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Fuera de ventana horaria";

   // Sensor 2: Spread (reutiliza SpreadOK del sistema base)
   m_sensors.spreadOK = SpreadOK();
   if(!m_sensors.spreadOK && m_sensors.blockReason == "") {
      int curSpr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      m_sensors.blockReason = "Spread: " + IntegerToString(curSpr) + " pts (max " + IntegerToString(Inp_MaxSpread) + ")";
   }

   // Sensor 3: Tendencia institucional (se evalua por direccion en RunCTEngine)
   // Aqui solo calculamos el sesgo de mercado para el dashboard
   if(m_mkt.ema200 > 0) {
      MqlTick tk; GetTick(tk);
      double mid = (tk.bid + tk.ask) / 2.0;
      m_sensors.trendBull = (mid > m_mkt.ema200);
   } else {
      m_sensors.trendBull = true; // Default si EMA no lista
   }

   // Sensor 4: Volatilidad
   m_sensors.volatOK = VolatilityOK();
   if(!m_sensors.volatOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Tormenta ATR: ratio=" + DoubleToString(m_sensors.atrRatio, 1) + " (max=" + DoubleToString(Inp_ATRRatioMax,1) + ")";

   // Sensor 5: Margin Guard
   m_sensors.marginOK = MarginGuardOK();
   if(!m_sensors.marginOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Margen insuf. para " + IntegerToString(Inp_MarginGuardLevels) + " niveles";

   // Todos OK si todos los sensores pasan (el sensor 3 se evalua por direccion en RunCTEngine)
   m_sensors.allOK = (m_sensors.timeOK && m_sensors.spreadOK &&
                      m_sensors.volatOK && m_sensors.marginOK);
}

//=================================================================
//  ADX (PRESERVADO DE V7.3)
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
//  CONTROL DIARIO (PRESERVADO DE V7.3)
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
      Print("[AQ V7.6] LIMITE DIARIO: pausa nuevas primarias, recovery y posiciones continuan");
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

double CalcExpectancy()
{
   int total = m_totalWins + m_totalLosses;
   if(total == 0) return 0;
   double wr  = (double)m_totalWins / total;
   double lr  = 1.0 - wr;
   double avgW = (m_totalWins  > 0) ? m_sumWins   / m_totalWins  : 0;
   double avgL = (m_totalLosses> 0) ? m_sumLosses / m_totalLosses: 0;
   return (wr * avgW) - (lr * avgL);
}

//=================================================================
//  CIERRE
//=================================================================
// ClosePos: cierra una posicion propia (magic = Inp_Magic)
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
         if(m_rec[idx].isLBC) {
            string comm = m_rec[idx].comment;
            if(StringFind(comm, "LBC_B") >= 0 && m_lbc.buyCount > 0)  m_lbc.buyCount--;
            if(StringFind(comm, "LBC_S") >= 0 && m_lbc.sellCount > 0) m_lbc.sellCount--;
            if(pf > 0) { m_lbc.harvestedTotal += pf; m_lbc.harvestCount++; }
         }
         Print("[AQ V7.6] CERRADA #", ticket, " $", NormalizeDouble(pf,2),
               (reason != "" ? " [" + reason + "]" : ""));
         ZeroMemory(m_rec[idx]);
      }
      return true;
   }
   return false;
}

// V7.5: CloseRescuePos cierra una posicion externa (cualquier magic)
// Solo se llama desde CloseBlockIfPositive cuando Inp_RescueAllTrades=true.
bool CloseRescuePos(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)) {
      m_totalPnL += pf; m_tradesClosed++;
      Print("[AQ V7.6] RESCATE CERRADA #", ticket, " $", NormalizeDouble(pf,2),
            " [", reason, "]");
      return true;
   }
   return false;
}

// UNICO CIERRE VALIDO: bloque neto > BlockTPTarget.
// V7.5: si Inp_RescueAllTrades, tambien cierra posiciones externas.
bool CloseBlockIfPositive(string reason)
{
   if(m_port.totalProfit < Inp_BlockTPTarget) return false;

   Print("[AQ V7.6] CIERRE POSITIVO: PnL=$", NormalizeDouble(m_port.totalProfit,2),
         " >= $", Inp_BlockTPTarget, " [", reason, "] | Rescatadas:", m_port.rescueCount);
   m_isProcessing = true;

   // Pass 0: cerrar ganadoras primero (propias), luego perdedoras
   for(int pass = 0; pass < 2; pass++) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(magic != Inp_Magic) continue; // Primero solo propias
         double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(pass == 0 && pf <  0) continue;
         if(pass == 1 && pf >= 0) continue;
         ClosePos(t, reason);
      }
   }

   // V7.5: cerrar posiciones externas rescatadas (ganadoras primero, luego perdedoras)
   if(Inp_RescueAllTrades) {
      for(int pass = 0; pass < 2; pass++) {
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            long magic = PositionGetInteger(POSITION_MAGIC);
            if(magic == Inp_Magic) continue; // Solo externas
            double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            if(pass == 0 && pf <  0) continue;
            if(pass == 1 && pf >= 0) continue;
            CloseRescuePos(t, "RESCUE_" + reason);
         }
      }
   }

   m_isProcessing   = false;
   m_recoveryActive = false;
   m_recoveryOrders = 0;
   m_recoveryTrendHedge = false; // V7.6
   // V7.6B: Reset net hedge flags al cerrar el bloque
   m_netHedge1Applied = false;
   m_netHedge2Applied = false;
   m_cycleResetTime = TimeCurrent();
   m_cycleInPause   = true;
   m_lastCTBuyPrice = m_lastCTSellPrice = 0;
   ZeroMemory(m_lbc);
   return true;
}

//=================================================================
//  LOTES (PRESERVADOS DE V7.3 - INTOCABLES)
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

// INTOCABLE: CalcRecoveryLot - logica matematica de recuperacion
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

   Print("[AQ V7.6] REC LOT: necesito ganar $", NormalizeDouble(totalNeeded,2),
         " en ", NormalizeDouble(moveDist,_Digits), " pts | 1lot=$",
         NormalizeDouble(profitPer1LotPerDist,2),
         " | calc=", NormalizeDouble(calcLot,2),
         " | min=",  NormalizeDouble(minRecLot,2),
         " | final=",NormalizeDouble(NormLot(finalLot),2));

   return NormLot(finalLot);
}

//=================================================================
//  APERTURA - SL=0, TP=0 siempre
//  Fix V7.3F preservado: skipPosLimit=true bypasa pausa/emergencia
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type, double lot, string comment, bool skipPosLimit = false)
{
   // Fix V7.3F: pausa/emergencia solo bloquea primarias (skipPosLimit=false)
   // Recovery y LBC usan skipPosLimit=true -> pasan incluso en emergencia
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

   if(!ok) { Print("[AQ V7.6] ERR apertura: ", m_trade.ResultRetcodeDescription()); return 0; }

   ulong ticket = m_trade.ResultOrder();
   if(ticket > 0) {
      m_tradesOpened++;
      Print("[AQ V7.6] ABIERTA #", ticket, " ",
            (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot=", lot, " @ ", NormalizeDouble(price, _Digits),
            " SL=0 TP=0",
            (m_inSession ? " [SESION]" : " [FUERA]"),
            " [", comment, "]",
            (m_emergencyMode ? " [RECOVERY-EMERGENCIA]" : ""));
   }
   return ticket;
}

//=================================================================
//  ManagePositions - Vacio intencionalmente (gestion por bloque)
//=================================================================
void ManagePositions() {}

//=================================================================
//  RECOVERY ENGINE (PRESERVADO DE V7.3 - INTOCABLE)
//=================================================================
void RunRecoveryEngine()
{
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD) {
      if(m_recoveryActive) { m_recoveryActive = false; m_recoveryOrders = 0; m_recoveryTrendHedge = false; }
      return;
   }
   if(m_port.totalPos == 0) return;
   if(m_isProcessing)        return;

   if(CloseBlockIfPositive("Recovery_TP")) return;

   if(!m_recoveryActive) {
      m_recoveryActive      = true;
      m_recoveryOrders      = m_port.recoveryCount;
      m_recoveryTrendHedge  = false; // V7.6: se determina en el primer intento
      Print("[AQ V7.6] RECOVERY ACTIVADO | PnL=$", NormalizeDouble(m_port.totalProfit,2),
            " | Rescate:", m_port.rescueCount, " pos externas");
   }

   // V7.6: el limite de ordenes depende del modo (hedge permite mas)
   int maxRec = m_recoveryTrendHedge ? Inp_RecoveryMaxOrdersTrend : Inp_RecoveryMaxOrders;
   if(m_recoveryOrders >= maxRec) return;
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

      double minDist = atr * Inp_RecoveryMinDistATR;
      if(distFromLoser < minDist) {
         Print("[AQ V7.6] RECOVERY: esperando dist | actual=",
               NormalizeDouble(distFromLoser, _Digits),
               " / min=", NormalizeDouble(minDist, _Digits));
         return;
      }
   }

   //=================================================================
   // V7.6 FIX CRITICO: Seleccion de direccion consciente de tendencia
   //
   // ANTES (BUG): si BUYs pierden -> abrir MAS BUYs (contra el mercado)
   // AHORA (FIX): si BUYs pierden + BEAR confirmado -> abrir SELL
   //              el SELL gana exactamente lo que pierde el BUY por el
   //              mismo movimiento. CalcRecoveryLot no cambia.
   //=================================================================
   ENUM_ORDER_TYPE recType;

   double adxLevel  = m_inSession ? Inp_ADXTrendLevel : Inp_ADXTrendLevelOff;
   bool   bearTrend = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.adx > adxLevel);
   bool   bullTrend = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.adx > adxLevel);

   if(m_port.buyProfit < m_port.sellProfit && bearTrend) {
      // BUYs perdiendo + tendencia BEAR confirmada -> SELL (hedge con el mercado)
      recType = ORDER_TYPE_SELL;
      m_recoveryTrendHedge = true;
      // No aplicar filtro de distancia CT en modo hedge: el mercado ya se movio
   } else if(m_port.sellProfit < m_port.buyProfit && bullTrend) {
      // SELLs perdiendo + tendencia BULL confirmada -> BUY (hedge con el mercado)
      recType = ORDER_TYPE_BUY;
      m_recoveryTrendHedge = true;
   } else {
      // Sin tendencia clara: promediado clasico (identico a V7.5)
      m_recoveryTrendHedge = false;
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
         recLot = NormLot(Inp_LotBase);
         if(!MarginOK(recLot, recType)) {
            Print("[AQ V7.6] RECOVERY: Sin margen -> Activando LBC");
            ActivateLBC();
            return;
         }
      }
   }

   string recMode = m_recoveryTrendHedge ? "HEDGE-TENDENCIA" : "PROMEDIADO";
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
      Print("[AQ V7.6] REC ABIERTO #", ticket, " [", recMode, "] ",
            (recType==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=", NormalizeDouble(recLot,2),
            " Orden=", m_recoveryOrders, "/", maxRec);
   }
}

//=================================================================
//  LBC ENGINE (PRESERVADO DE V7.3 - INTOCABLE)
//=================================================================
void ActivateLBC()
{
   if(m_lbc.active) return;
   m_lbc.active        = true;
   m_lbc.activatedTime = TimeCurrent();
   m_lbc.buyCount      = 0;
   m_lbc.sellCount     = 0;
   m_lbc.lastBuyPrice  = 0;
   m_lbc.lastSellPrice = 0;
   m_lbc.harvestedTotal= 0;
   m_lbc.harvestCount  = 0;

   double freeMarg   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margPer001 = CalcMarginFor001();
   double usableMarg = freeMarg * Inp_LBCMarginPct;
   m_lbc.maxOrdersCalc = (int)MathFloor(usableMarg / (2.0 * MathMax(margPer001, 0.01)));
   m_lbc.maxOrdersCalc = MathMax(1, MathMin(m_lbc.maxOrdersCalc, Inp_LBCMaxPairs));

   Print("[AQ V7.6] LBC ACTIVADO | LibreMarg=$", NormalizeDouble(freeMarg,2),
         " | MargPor0.01=$", NormalizeDouble(margPer001,2),
         " | MaxPares=", m_lbc.maxOrdersCalc);
}

// INTOCABLE: DeactivateLBC
void DeactivateLBC()
{
   if(!m_lbc.active) return;
   Print("[AQ V7.6] LBC DESACTIVADO | Cosechado: $",
         NormalizeDouble(m_lbc.harvestedTotal,2),
         " en ", m_lbc.harvestCount, " cosechas");
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
         double freeMarg   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         double margPer001 = CalcMarginFor001();
         m_lbc.maxOrdersCalc = (int)MathFloor(
            (freeMarg * Inp_LBCMarginPct) / (2.0 * MathMax(margPer001,0.01)));
         m_lbc.maxOrdersCalc = MathMax(1, MathMin(m_lbc.maxOrdersCalc, Inp_LBCMaxPairs));
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
      if(m_lbc.buyCount <= m_lbc.sellCount) {
         if(m_lbc.lastBuyPrice <= 0 || MathAbs(tk.ask - m_lbc.lastBuyPrice) >= gridSpace)
            needBuy = true;
      }
      if(m_lbc.sellCount <= m_lbc.buyCount) {
         if(m_lbc.lastSellPrice <= 0 || MathAbs(tk.bid - m_lbc.lastSellPrice) >= gridSpace)
            needSell = true;
      }
   }

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
         m_lbc.lastBuyPrice  = tk.ask;
         m_lbc.lastOrderTime = TimeCurrent();
         Print("[AQ V7.6] LBC BUY #", ticketB, " B=", m_lbc.buyCount, " S=", m_lbc.sellCount);
      }
   }

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
         m_lbc.lastSellPrice = tk.bid;
         m_lbc.lastOrderTime = TimeCurrent();
         Print("[AQ V7.6] LBC SELL #", ticketS, " B=", m_lbc.buyCount, " S=", m_lbc.sellCount);
      }
   }
}

//=================================================================
//  BASKET TP (PRESERVADO DE V7.3)
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

void CheckCycleMaxLoss()
{
   if(!Inp_UseCycleMaxLoss || m_port.totalPos == 0) return;
   if(m_port.totalProfit <= Inp_CycleMaxLossUSD) {
      Print("[AQ V7.6] CYCLE MAX LOSS: $", NormalizeDouble(m_port.totalProfit,2),
            " -> Forzando Recovery");
      if(!m_recoveryActive) { m_recoveryActive = true; m_recoveryOrders = 0; }
   }
}

//=================================================================
//  HARVEST (PRESERVADO DE V7.3)
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
      Print("[AQ V7.6] HARVEST: ", harvested, " cerradas | $", NormalizeDouble(totalH,2));
}

//=================================================================
//  EQUITY GUARD (fix V7.3F preservado: recovery sigue en emergencia)
//=================================================================
bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   if(m_port.totalProfit <= Inp_EmergencyLossUSD && !m_emergencyMode) {
      Print("[AQ V7.6] ALERTA EQUITY: $", NormalizeDouble(m_port.totalProfit,2),
            " -> Pausa primarias. Recovery/LBC/Rescue siguen activos.");
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
//  CT ENGINE - V7.5: Sensores aplicados SOLO a Primary_Entry
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType, double &ctLot, int &ctLevel)
{
   if(m_port.totalPos == 0) return false;
   if(m_port.totalPos >= Inp_MaxPositionsTotal) return false;
   if(m_port.totalProfit >= 0 && m_port.negativeSum == 0) return false;
   if(m_recoveryActive) return false;
   if(m_lbc.active)     return false;
   if(m_mkt.atr <= 0)   return false;

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
      // ==========================================================
      // ENTRADA PRIMARIA - Aqui se aplican los 5 sensores V7.5
      // Los sensores NO se aplican si hay un ciclo activo (rescue
      // o propio), solo bloquean el inicio de un nuevo ciclo.
      // ==========================================================

      // Verificar sensores completos (tiempo, spread, volat, margen)
      if(!m_sensors.allOK) {
         // Solo loguear cada 60 segundos para no saturar el journal
         static datetime lastSensorLog = 0;
         if(TimeCurrent() - lastSensorLog >= 60) {
            Print("[AQ V7.6] ENTRADA BLOQUEADA: ", m_sensors.blockReason);
            lastSensorLog = TimeCurrent();
         }
         return;
      }

      // V7.6C: Filtro de tormenta de volatilidad — SOLO Primary_Entry
      // Si m_stormActive=true el mercado esta en condiciones institucionales
      // adversas (ATR explotado, spread anomalo). Bloquear hasta que se despeje.
      // NUNCA afecta Recovery, CT activo, Net Hedge ni LBC.
      if(m_stormActive) {
         static datetime lastStormLog = 0;
         if(TimeCurrent() - lastStormLog >= 30) {
            Print("[AQ V7.6C] PRIMARY BLOQUEADA por TORMENTA | ATRratio=",
                  NormalizeDouble(m_stormLastATRRatio,2),
                  " SPRratio=", NormalizeDouble(m_stormLastSprRatio,2),
                  " | Despejado en ", Inp_StormCooldownSec-(int)(TimeCurrent()-m_stormDetectedTime), "s");
            lastStormLog = TimeCurrent();
         }
         return;
      }

      int cooldown = m_inSession ? Inp_PrimaryCooldownSec : Inp_PrimaryCooldownOff;
      if(TimeCurrent() - m_lastPrimaryTime < cooldown) return;

      ENUM_ORDER_TYPE initType;
      if(m_mkt.isBullish)                   initType = ORDER_TYPE_BUY;
      else if(m_mkt.isBearish)              initType = ORDER_TYPE_SELL;
      else if(m_mkt.emaFast > m_mkt.emaSlow) initType = ORDER_TYPE_BUY;
      else                                  initType = ORDER_TYPE_SELL;

      if(m_lastPrimaryLost && m_lastPrimaryDir != 0) {
         ENUM_ORDER_TYPE alt = (m_lastPrimaryDir == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         if(initType != alt) { initType = alt; m_lastPrimaryLost = false; }
      }
      if(!ADXAllowsEntry(initType)) return;

      // Sensor 3: EMA200 - filtro de tendencia institucional (direccion especifica)
      if(!TrendFilter200OK(initType)) {
         static datetime lastTrendLog = 0;
         if(TimeCurrent() - lastTrendLog >= 60) {
            string dir = (initType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
            Print("[AQ V7.6] ENTRADA BLOQUEADA por EMA200: ", dir,
                  " vs EMA200=", DoubleToString(m_mkt.ema200, _Digits));
            lastTrendLog = TimeCurrent();
         }
         return;
      }

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
         m_recoveryTrendHedge = false; // V7.6
         DeactivateLBC();
      }
      m_isProcessing = false;
      return;
   }

   // Ciclo activo: CT normal, sin filtro de sensores
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
//  V7.5: DASHBOARD DARK MODE INSTITUCIONAL
//  Diseno minimalista con fondo negro solido y bordes gris acero.
//  Muestra: estado, sensores (matriz 5 indicadores), cuenta, bloque.
//=================================================================

// Crear o actualizar un label de texto
void AQLbl(string n, string txt, int x, int y, color c, int fs = 9, bool bold = false)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTED,   false);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  fs);
   ObjectSetString(0,  n, OBJPROP_FONT,      bold ? "Consolas Bold" : "Consolas");
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
}

// Crear o actualizar un boton
void AQBtn(string n, string txt, int x, int y, int w, int h, color bg, color fg = clrWhite)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE,   8);
      ObjectSetString(0,  n, OBJPROP_FONT,       "Consolas");
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,     h);
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     fg);
}

// Panel de fondo: fondo negro solido, borde gris acero
void AQPanel(string n, int x, int y, int w, int h)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_BACK,       false);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTED,   false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,     true);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,       h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,     C'8,8,12');      // Negro solido
   ObjectSetInteger(0, n, OBJPROP_COLOR,       C'70,70,70');    // Borde gris acero
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_WIDTH,       1);
}

void DeleteDash()
{
   // Eliminar objetos V7.3 (migracion)
   string old73[] = {
      "D73_BG","D73_T0","D73_T1",
      "D73_L1","D73_L2","D73_L3","D73_L4","D73_L5","D73_L6","D73_L7",
      "D73_L8","D73_L9","D73_L10","D73_L11","D73_L12","D73_L13","D73_L14","D73_L15",
      "D73_B1","D73_B2"
   };
   for(int i = 0; i < ArraySize(old73); i++) ObjectDelete(0, old73[i]);

   // Eliminar objetos V7.5
   string aq75[] = {
      "AQ75_BG","AQ75_HDR","AQ75_SEP1","AQ75_STATE","AQ75_REASON",
      "AQ75_SEP2","AQ75_SENS_HDR",
      "AQ75_S1","AQ75_S2","AQ75_S3","AQ75_S4","AQ75_S5",
      "AQ75_SEP3","AQ75_RESCUE",
      "AQ75_SEP4","AQ75_ACC",
      "AQ75_SEP5","AQ75_PNL","AQ75_POS","AQ75_VWAP",
      "AQ75_REC","AQ75_NH","AQ75_SF","AQ75_SEP6","AQ75_HIST",
      "AQ75_SEP7","AQ75_DIAG",
      "AQ75_B1","AQ75_B2"
   };
   for(int i = 0; i < ArraySize(aq75); i++) ObjectDelete(0, aq75[i]);
}

// Genera texto de un sensor con estado OK o ALERTA
string SensorPill(string label, bool ok, string okTxt, string failTxt)
{
   return label + " : " + (ok ? okTxt : failTxt);
}

void UpdateDash()
{
   if(!Inp_ShowDashboard) return;
   if(TimeCurrent() - m_lastDashTime < 1) return;
   m_lastDashTime = TimeCurrent();

   // Paleta dark mode
   color cBG     = C'8,8,12';       // Negro fondo panel
   color cBorder = C'70,70,70';     // Gris acero
   color cWhite  = C'230,230,230';  // Blanco texto principal
   color cGray   = C'120,120,130';  // Gris texto secundario
   color cGreen  = C'0,220,80';     // Verde neon OK
   color cRed    = C'220,50,50';    // Rojo alerta
   color cOra    = C'220,150,30';   // Naranja atencion
   color cYel    = C'200,200,50';   // Amarillo advertencia
   color cCyan   = C'50,190,220';   // Cyan datos
   color cPurple = C'160,80,220';   // Purpura rescue

   int x0  = Inp_DashX;
   int y0  = Inp_DashY;
   int lh  = 16;
   int pad = 8;
   int w   = 540;
   int h   = 31 * lh + 60; // V7.6C: +3 lineas (Net Hedge + Storm Filter)

   // Fondo principal
   AQPanel("AQ75_BG", x0 - pad, y0 - pad, w, h);

   int x = x0, y = y0;

   // ENCABEZADO 
   AQLbl("AQ75_HDR",
         "[ " + VERSION_STR + " ]  " + _Symbol + "  |  24/7 GLOBAL RESCUE SYSTEM",
         x, y, cGreen, 10, true);
   y += lh + 2;

   // Linea separadora
   AQLbl("AQ75_SEP1",
         "                                                            ",
         x, y, cBorder, 8);
   y += lh - 4;

   // ESTADO ACTUAL 
   string stateStr;
   color  stateC;
   if(m_emergencyMode) {
      stateStr = "[ ALERTA EQUITY  -  RECOVERY ACTIVO ]";
      stateC   = cRed;
   } else if(m_dailyLimitHit) {
      stateStr = "[ LIMITE DIARIO  -  GESTION CONTINUA ]";
      stateC   = cOra;
   } else if(m_lbc.active) {
      stateStr = "[ MODO LBC ACTIVO  -  MICRO-GRID ]";
      stateC   = cOra;
   } else if(m_recoveryActive) {
      stateStr = "[ RESCATANDO OPERACIONES ]";
      stateC   = cYel;
   } else if(m_cycleInPause) {
      stateStr = "[ PAUSA ENTRE CICLOS ]";
      stateC   = cGray;
   } else if(m_isPaused) {
      stateStr = "[ ROBOT EN PAUSA  -  RECOVERY OPERA ]";
      stateC   = cYel;
   } else if(m_port.rescueCount > 0) {
      stateStr = "[ GESTIONANDO RESCATE  -  " + IntegerToString(m_port.rescueCount) + " POS EXTERNAS ]";
      stateC   = cPurple;
   } else if(!m_sensors.allOK) {
      stateStr = "[ BUSCANDO CONDICIONES ]";
      stateC   = cGray;
   } else {
      stateStr = "[ BUSCANDO ENTRADA ]";
      stateC   = cGreen;
   }
   AQLbl("AQ75_STATE", stateStr, x, y, stateC, 10, true);
   y += lh + 2;

   // Razon de bloqueo (si aplica)
   string diagStr = " Sin Bloqueos: ";
   if(!m_sensors.allOK && m_port.totalPos == 0)
      diagStr = "  Diagnostico: " + m_sensors.blockReason;
   else if(m_port.totalPos > 0 && m_port.totalProfit < 0)
      diagStr = " Gestionando bloque | Recovery sin restriccion de sensores";
   AQLbl("AQ75_REASON", diagStr, x, y, cGray, 8);
   y += lh - 2;

   // MATRIZ DE SENSORES 
   AQLbl("AQ75_SEP2",
         " SENSORES DE ENTRADA: ",
         x, y, C'50,50,80', 8);
   y += lh - 3; 

   // Los 5 sensores en una sola linea
   int curSpr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   string trendStr = m_sensors.trendBull ? "BULL" : "BEAR";
   color  trendC   = m_sensors.trendBull ? cGreen : cCyan;

   // Sensor 1: Horario
   AQLbl("AQ75_S1",
         SensorPill("TIME", m_sensors.timeOK, "PASS", "WAIT"),
         x, y, m_sensors.timeOK ? cGreen : cRed, 9);

   // Sensor 2: Spread
   AQLbl("AQ75_S2",
         SensorPill("SPR", m_sensors.spreadOK, "PASS("+IntegerToString(curSpr)+")", "ALTO("+IntegerToString(curSpr)+")"),
         x + 100, y, m_sensors.spreadOK ? cGreen : cRed, 9);

   // Sensor 3: Tendencia EMA200
   AQLbl("AQ75_S3",
         "TEND : " + trendStr + (m_mkt.ema200 > 0 ? "("+ DoubleToString(m_mkt.ema200,1) +")" : "(NO DATA)"),
         x + 210, y, trendC, 9);

   // Sensor 4: Volatilidad
   string ratioStr = (m_mkt.atrSlow > 0)
      ? DoubleToString(m_sensors.atrRatio, 2)
      : "N/A";
   AQLbl("AQ75_S4",
         SensorPill("VOLAT", m_sensors.volatOK, "CALM("+ratioStr+")", "STORM("+ratioStr+")"),
         x + 360, y, m_sensors.volatOK ? cGreen : cRed, 9);

   y += lh - 1;
   // Sensor 5: Margin Guard (en la siguiente linea por espacio)
   AQLbl("AQ75_S5",
         SensorPill("MARG", m_sensors.marginOK,
                    "PASS (>"+IntegerToString(Inp_MarginGuardLevels)+" niveles)",
                    "WAIT (<"+IntegerToString(Inp_MarginGuardLevels)+" niveles)"),
         x, y, m_sensors.marginOK ? cGreen : cOra, 9);
   y += lh;

   // MODO RESCATE UNIVERSAL
   AQLbl("AQ75_SEP3",
         " RESCATE UNIVERSAL: ",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   string rescueMode = Inp_RescueAllTrades ? "ACTIVO" : "INACTIVO";
   color  rescueC    = Inp_RescueAllTrades ? (m_port.rescueCount > 0 ? cPurple : cGreen) : cGray;
   string rescueDetail = "";
   if(Inp_RescueAllTrades && m_port.rescueCount > 0)
      rescueDetail = " | " + IntegerToString(m_port.rescueCount) + " pos externas | PnL externo: $" +
                     DoubleToString(m_port.rescueProfit, 2);
   else if(Inp_RescueAllTrades)
      rescueDetail = " | Sin posiciones externas en " + _Symbol;
   else
      rescueDetail = " | Solo gestiona magic=" + IntegerToString(Inp_Magic);

   AQLbl("AQ75_RESCUE",
         "MODO RESCATE: " + rescueMode + rescueDetail,
         x, y, rescueC, 9);
   y += lh;

   // CUENTA
   AQLbl("AQ75_SEP4",
         " CUENTA: ",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double ddPct = m_port.currentDD * 100.0;
   color  ddC   = (ddPct > 10.0) ? cRed : (ddPct > 5.0) ? cOra : cGreen;

   AQLbl("AQ75_ACC",
         "Saldo: $" + DoubleToString(bal,2) +
         "   Equity: $" + DoubleToString(eq,2) +
         "   LibreMarg: $" + DoubleToString(free,2) +
         "   DD: " + DoubleToString(ddPct,1) + "%",
         x, y, cCyan, 9);
   y += lh;

   // BLOQUE ACTIVO
   AQLbl("AQ75_SEP5",
         " BLOQUE ACTIVO: ",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   double pnl   = m_port.totalProfit;
   double falta = MathMax(0, Inp_BlockTPTarget - pnl);
   color  pnlC  = (pnl >= 0) ? cGreen : cRed;
   string pnlStr = (pnl >= 0)
      ? "PnL BLOQUE: +" + DoubleToString(pnl,2)
      : "PnL BLOQUE: " + DoubleToString(pnl,2);

   AQLbl("AQ75_PNL",
         pnlStr + "   Target: +$" + DoubleToString(Inp_BlockTPTarget,2) +
         "   Falta: $" + DoubleToString(falta,2),
         x, y, pnlC, 9);
   y += lh - 1;

   AQLbl("AQ75_POS",
         "Pos: " + IntegerToString(m_port.totalPos) +
         "   BUY: " + IntegerToString(m_port.buyCount) +
         " ($" + DoubleToString(m_port.buyProfit,2) + ")" +
         "   SELL: " + IntegerToString(m_port.sellCount) +
         " ($" + DoubleToString(m_port.sellProfit,2) + ")" +
         "   CT:" + IntegerToString(m_port.ctCount) +
         " REC:" + IntegerToString(m_port.recoveryCount) +
         " LBC:" + IntegerToString(m_port.lbcCount),
         x, y, cCyan, 9);
   y += lh - 1;

   string dirStr = (m_port.blockDir > 0) ? "LARGO" : (m_port.blockDir < 0) ? "CORTO" : "NEUTRO";
   string vwapStr = (m_port.blockVWAP > 0)
      ? "VWAP: " + DoubleToString(m_port.blockVWAP, _Digits) + "   Dir: " + dirStr
      : "Sin posiciones abiertas";
   AQLbl("AQ75_VWAP", vwapStr, x, y, cGray, 9);
   y += lh - 1;

   // Recovery y LBC
   string recStr = m_recoveryActive
      ? "RECOVERY: ACTIVO (" + IntegerToString(m_recoveryOrders) + "/" + IntegerToString(Inp_RecoveryMaxOrders) + ")"
      : "RECOVERY: en espera";
   color recC = m_recoveryActive ? cYel : cGray;
   string lbcStr = m_lbc.active
      ? "   LBC: ACTIVO B=" + IntegerToString(m_lbc.buyCount) + " S=" + IntegerToString(m_lbc.sellCount) +
        " Cos=$" + DoubleToString(m_lbc.harvestedTotal,2)
      : "   LBC: en espera";
   AQLbl("AQ75_REC", recStr + lbcStr, x, y, recC, 9);
   y += lh - 1;

   // V7.6B: Net Hedge status
   double netV76 = m_port.buyVolume - m_port.sellVolume;
   string nhStr;
   color  nhC;
   if(m_netHedge2Applied) {
      nhStr = "NET HEDGE L2 (100%) ACTIVO | Exposicion neta: " + DoubleToString(netV76,2) + " lotes";
      nhC   = cRed;
   } else if(m_netHedge1Applied) {
      nhStr = "NET HEDGE L1 (50%) ACTIVO | L2 activa si PnL <= $" + DoubleToString(Inp_NetHedgeTrigger2USD,2);
      nhC   = cOra;
   } else {
      nhStr = "NET HEDGE: en espera | L1@$" + DoubleToString(Inp_NetHedgeTrigger1USD,2) +
              " L2@$" + DoubleToString(Inp_NetHedgeTrigger2USD,2) +
              " | NetVol=" + DoubleToString(netV76,2);
      nhC   = cGray;
   }
   AQLbl("AQ75_NH", nhStr, x, y, nhC, 9);
   y += lh - 1;

   // V7.6C: Volatility Storm Filter status
   string sfStr;
   color  sfC;
   if(m_stormActive) {
      int remaining = Inp_StormCooldownSec - (int)(TimeCurrent() - m_stormDetectedTime);
      sfStr = "STORM FILTER: ACTIVO - PRIMARY BLOQUEADA | ATR=" + DoubleToString(m_stormLastATRRatio,2) +
              "x  SPR=" + DoubleToString(m_stormLastSprRatio,2) +
              "x  Libre en: " + IntegerToString(MathMax(0,remaining)) + "s";
      sfC   = cRed;
   } else {
      sfStr = "STORM FILTER: OK | ATR=" + DoubleToString(m_stormLastATRRatio,2) +
              "x (lim=" + DoubleToString(Inp_StormATRMult,1) +
              "x)  SPR=" + DoubleToString(m_stormLastSprRatio,2) + "x";
      sfC   = cGray;
   }
   AQLbl("AQ75_SF", sfStr, x, y, sfC, 9);
   y += lh;

   // HISTORIAL 
   AQLbl("AQ75_SEP6",
         " HISTORIAL:  ",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   int    totalT  = m_totalWins + m_totalLosses;
   double wrPct   = (totalT > 0) ? (double)m_totalWins / totalT * 100.0 : 0;
   double expect  = CalcExpectancy();
   color  expC    = (expect >= 0) ? cGreen : cOra;

   AQLbl("AQ75_HIST",
         "Win: " + DoubleToString(wrPct,1) + "% (" + IntegerToString(m_totalWins) + "/" + IntegerToString(totalT) + ")" +
         "   Expect: $" + DoubleToString(expect,3) +
         "   PnL cerrado: $" + DoubleToString(m_totalPnL,2) +
         "   Ticks: " + IntegerToString((int)m_tickCount),
         x, y, expC, 9);
   y += lh;

   // DIAGNOSTICO GMT
   AQLbl("AQ75_SEP7",
         " GMT: ",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   MqlDateTime dtNow; TimeToStruct(TimeCurrent(), dtNow);
   string brokerTime = StringFormat("%02d:%02d", dtNow.hour, dtNow.min);
   int sm = m_sensors.brokerStartMin;
   int em = m_sensors.brokerEndMin;
   string winStr = StringFormat("%02d:%02d-%02d:%02d broker", sm/60, sm%60, em/60, em%60);
   AQLbl("AQ75_DIAG",
         "Hora broker: " + brokerTime +
         "   Ventana: " + winStr +
         "   User GMT:" + IntegerToString(Inp_UserGMT) +
         "   Broker GMT:" + IntegerToString(Inp_BrokerGMT) +
         "   ATR: " + DoubleToString(m_mkt.atr,2) +
         "   EMA200: " + (m_mkt.ema200 > 0 ? DoubleToString(m_mkt.ema200,1) : "cargando..."),
         x, y, cGray, 8);
   y += lh + 4;

   // BOTONES 
   // Boton PAUSA/RESUME: afecta la operativa propia Y la logica de rescate
   string pauseTxt = m_isPaused ? ">> REANUDAR TODO <<" : "|| PAUSAR PRIMARIAS";
   color  pauseBG  = m_isPaused ? C'180,130,0' : C'0,90,40';
   AQBtn("AQ75_B1", pauseTxt, x, y, 180, 22, pauseBG);
   AQBtn("AQ75_B2", "CERRAR TODAS (MANUAL)", x + 190, y, 180, 22, C'150,20,20');

   ChartRedraw(0);
}

//=================================================================
//  V7.6C: VOLATILITY STORM FILTER — FUNCIONES DE SOPORTE
//
//  Las tres funciones son independientes y sin efectos secundarios.
//  Leen datos de mercado historicos y devuelven valores puros.
//=================================================================

// Funcion 1: Calcula el ATR promedio simple de las ultimas N barras M1.
// Devuelve 0 si no hay datos suficientes (primer arranque del EA).
double CalcAvgATR(int windowBars)
{
   if(windowBars <= 0 || h_ATR == INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf, true);
   // Leemos windowBars+1 valores y saltamos la barra 0 (incompleta)
   if(CopyBuffer(h_ATR, 0, 1, windowBars, buf) < windowBars) return 0;
   double sum = 0;
   for(int i = 0; i < windowBars; i++) sum += buf[i];
   return (sum / windowBars);
}

// Funcion 2: Calcula el spread promedio en puntos de las ultimas N barras M1.
// Usa datos de cierre Ask-Bid de barras historicas via CopyRates.
// Si no hay datos suficientes devuelve el spread actual para evitar falsos bloqueos.
double CalcAvgSpread(int windowBars)
{
   if(windowBars <= 0) return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, windowBars, rates) < windowBars)
      return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   // El spread en MqlRates no esta disponible directamente; usamos spread actual
   // pero calculamos la variacion del precio para aproximar el costo de transaccion.
   // En la practica usamos el spread del simbolo promediado con varianza de ticks.
   // Aqui usamos una aproximacion: spread actual como referencia base y lo comparamos
   // con el rango de cada barra / ATR para detectar spreads anomalos.
   double sumSpread = 0;
   for(int i = 0; i < windowBars; i++) {
      // Aproximacion: rango (H-L) de la barra como proxy de liquidez
      sumSpread += (rates[i].high - rates[i].low) / _Point;
   }
   // Devolvemos el rango promedio por barra como referencia relativa
   return (sumSpread / windowBars);
}

// Funcion 3: Evalua si estamos en tormenta de volatilidad institucional.
// Retorna true si NO es seguro abrir una nueva Primary_Entry.
// Actualiza m_stormActive, m_stormLastATRRatio, m_stormLastSprRatio.
bool IsVolatilityStormActive()
{
   if(!Inp_UseStormFilter) return false;

   double atrNow = m_mkt.atr;
   if(atrNow <= 0) return false; // ATR no disponible, no bloquear

   // --- Criterio 1: Aceleracion del ATR ---
   double atrAvg = CalcAvgATR(Inp_StormATRWindow);
   bool   atrStorm = false;
   if(atrAvg > 0) {
      m_stormLastATRRatio = atrNow / atrAvg;
      atrStorm = (m_stormLastATRRatio >= Inp_StormATRMult);
   }

   // --- Criterio 2: Explosion de spread ---
   double sprNow = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double sprAvg = CalcAvgSpread(Inp_StormSpreadWindow);
   bool   sprStorm = false;
   if(sprAvg > 0) {
      m_stormLastSprRatio = sprNow / sprAvg;
      // El spread en puntos vs el rango promedio de barra
      // Usamos una comparacion directa del spread actual vs el spread maximo normal
      // Para Pepperstone XAUUSD Razor: spread normal ~3-8 pts en sesion
      // Usamos la relacion spread_actual / Inp_MaxSpread como indicador
      double sprNorm = sprNow / (double)MathMax(Inp_MaxSpread, 1);
      sprStorm = (sprNorm > Inp_StormSpreadMult * 0.5); // Calibrado para Razor USD
   }

   // --- Decision combinada ---
   bool stormNow = (atrStorm || sprStorm);

   if(stormNow && !m_stormActive) {
      m_stormActive       = true;
      m_stormDetectedTime = TimeCurrent();
      Print("[AQ V7.6C] TORMENTA DETECTADA | ATR ratio=",
            NormalizeDouble(m_stormLastATRRatio, 2), " (lim=", Inp_StormATRMult, ")",
            " | SPR ratio=", NormalizeDouble(m_stormLastSprRatio, 2),
            " | Primaria bloqueada ", Inp_StormCooldownSec, "s");
   }

   if(m_stormActive) {
      // Mantener bloqueo durante el cooldown aunque el ATR baje momentaneamente
      if(TimeCurrent() - m_stormDetectedTime >= Inp_StormCooldownSec) {
         // Revaluar: si el ATR ya volvio a la normalidad, levantar el bloqueo
         if(!stormNow) {
            m_stormActive = false;
            Print("[AQ V7.6C] TORMENTA DESPEJADA | ATR ratio=",
                  NormalizeDouble(m_stormLastATRRatio, 2),
                  " | Primaria desbloqueada");
         }
         // Si aun hay tormenta, renovar el timer para otra ronda de cooldown
         else m_stormDetectedTime = TimeCurrent();
      }
      return true; // Bloquear durante toda la tormenta + cooldown
   }

   return false;
}

//=================================================================
//  V7.6C: RunVolatilityStormFilter — llamada unica por tick
//  Actualiza m_stormActive. Se llama en OnTick antes del CT Engine.
//  NO toma ninguna decision de apertura ni cierre aqui.
//=================================================================
void RunVolatilityStormFilter()
{
   // Solo actualizar el estado; la decision de bloqueo se aplica en RunCTEngine
   IsVolatilityStormActive();
}

//=================================================================
//  V7.6B: NET EXPOSURE HEDGE ENGINE
//
//  PROBLEMA RESUELTO:
//    Con BUY 0.01+0.02+0.03+0.04 = 0.10 lotes largos y mercado cayendo $20,
//    la perdida bruta es $200 en el lado BUY. Dos SELL de 0.01 compensan
//    apenas $0.40 por cada $1 de caida (2.5% del riesgo real).
//
//  SOLUCION: Hedge PROPORCIONAL a la exposicion neta:
//    Nivel 1 (perdida > Inp_NetHedgeTrigger1USD):
//      Abrir SELL = 50% del volumen neto largo
//      Ejemplo: neto LONG 0.08 -> abrir SELL 0.04
//      Resultado: cada $1 de caida cuesta $4 (no $8)
//
//    Nivel 2 (perdida > Inp_NetHedgeTrigger2USD):
//      Abrir SELL = 50% restante del volumen neto
//      Resultado: exposicion neta = 0, perdida congelada
//
//  REGLA ABSOLUTA: NUNCA cierra posiciones. Solo ABRE nuevas coberturas.
//  El bloque sigue vivo y se cierra normalmente cuando el PnL >= BlockTPTarget.
//=================================================================
void RunNetExposureHedge()
{
   if(!Inp_UseNetHedge || m_port.totalPos == 0 || m_isProcessing) return;

   double netVol = NormalizeDouble(m_port.buyVolume - m_port.sellVolume, 2);

   // Si ya estamos neutrales o cerca de 0, no hacer nada
   if(MathAbs(netVol) < 0.005) return;

   double loss = m_port.totalProfit;

   // Ninguno de los dos niveles aplica aun
   if(loss > Inp_NetHedgeTrigger1USD) return;

   // Respetar intervalo minimo entre hedges
   if(TimeCurrent() - m_lastNetHedgeTime < Inp_NetHedgeIntervalSec) return;

   if(!SpreadOK()) return;

   // La orden de cobertura es SIEMPRE opuesta al sesgo neto
   ENUM_ORDER_TYPE hedgeType = (netVol > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   //-----------------------------------------------------------
   // NIVEL 2: cubrir el 100% del volumen neto restante
   //-----------------------------------------------------------
   if(loss <= Inp_NetHedgeTrigger2USD && !m_netHedge2Applied) {
      // Si L1 ya cubrió el 50%, ahora cubrimos el otro 50%
      // Si L1 no se aplicó (saltamos directo a L2), cubrimos el 100%
      double pctAlreadyCovered = m_netHedge1Applied ? 0.50 : 0.0;
      double pctToAdd          = 1.0 - pctAlreadyCovered;
      double hedgeLot          = NormLot(MathAbs(netVol) * pctToAdd);

      if(hedgeLot > 0 && MarginOK_Hedge(hedgeLot, hedgeType)) {
         string comm = "NET_HEDGE_L2";
         m_isProcessing = true;
         ulong ticket = OpenOrder(hedgeType, hedgeLot, comm, true);
         m_isProcessing = false;

         if(ticket > 0) {
            m_netHedge2Applied = true;
            if(!m_netHedge1Applied) m_netHedge1Applied = true;
            m_lastNetHedgeTime = TimeCurrent();
            MqlTick tk; GetTick(tk);
            int idx = FreeRec();
            if(idx >= 0) {
               int    pt = (hedgeType==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
               double op = (hedgeType==ORDER_TYPE_BUY) ? tk.ask : tk.bid;
               InitRec(idx, ticket, pt, op, hedgeLot, comm, false, false, true, false);
            }
            Print("[AQ V7.6B] NET HEDGE L2 (100%) ABIERTO: ",
                  (hedgeType==ORDER_TYPE_BUY?"BUY":"SELL"), " ", hedgeLot,
                  " | PnL=$", NormalizeDouble(loss,2),
                  " | NetVol antes=", NormalizeDouble(netVol,2));
         }
      }
      return; // No evaluar L1 si ya llegamos a L2
   }

   //-----------------------------------------------------------
   // NIVEL 1: cubrir el 50% del volumen neto
   //-----------------------------------------------------------
   if(loss <= Inp_NetHedgeTrigger1USD && !m_netHedge1Applied) {
      double hedgeLot = NormLot(MathAbs(netVol) * 0.50);

      if(hedgeLot > 0 && MarginOK_Hedge(hedgeLot, hedgeType)) {
         string comm = "NET_HEDGE_L1";
         m_isProcessing = true;
         ulong ticket = OpenOrder(hedgeType, hedgeLot, comm, true);
         m_isProcessing = false;

         if(ticket > 0) {
            m_netHedge1Applied = true;
            m_lastNetHedgeTime = TimeCurrent();
            MqlTick tk; GetTick(tk);
            int idx = FreeRec();
            if(idx >= 0) {
               int    pt = (hedgeType==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
               double op = (hedgeType==ORDER_TYPE_BUY) ? tk.ask : tk.bid;
               InitRec(idx, ticket, pt, op, hedgeLot, comm, false, false, true, false);
            }
            Print("[AQ V7.6B] NET HEDGE L1 (50%) ABIERTO: ",
                  (hedgeType==ORDER_TYPE_BUY?"BUY":"SELL"), " ", hedgeLot,
                  " | PnL=$", NormalizeDouble(loss,2),
                  " | NetVol antes=", NormalizeDouble(netVol,2),
                  " | L2 activa si PnL <= $", Inp_NetHedgeTrigger2USD);
         }
      }
   }
}

//=================================================================
//  V7.6B: AUTO-DETECCION FILLING MODE (live + Strategy Tester)
//  Pepperstone live: acepta FOK.
//  Strategy Tester "ideal": solo acepta RETURN.
//=================================================================
ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   // En el Strategy Tester SOLO funciona ORDER_FILLING_RETURN
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
   Print("  " + VERSION_STR + " - TREND-AWARE RECOVERY ENGINE (V7.6)");
   Print("  SL=0 en TODAS las ordenes - broker no cierra auto");
   Print("  Fix V7.3F: Recovery opera incluso en modo emergencia");
   Print("  Fix V7.6: Recovery sigue tendencia (BEAR->SELL, BULL->BUY)");
   Print("  V7.6B: Net Exposure Hedge graduado (L1@$",Inp_NetHedgeTrigger1USD," L2@$",Inp_NetHedgeTrigger2USD,") - NUNCA cierra negativos");
   Print("  V7.6C: Storm Filter - bloquea Primary_Entry en tormenta ATR/spread (nunca bloquea recovery)");
   Print("  5 Sensores: TIME | SPREAD | EMA200 | VOLAT | MARGIN");
   Print("  RescueAllTrades: ", Inp_RescueAllTrades ? "ACTIVO" : "INACTIVO");
   Print("  GMT User:", Inp_UserGMT, "  Broker:", Inp_BrokerGMT,
         "  Ventana:", Inp_StartTime, "-", Inp_EndTime, " local");
   Print("=============================================================");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   // V7.6B: Auto-detectar filling mode (FOK en live, RETURN en tester)
   m_trade.SetTypeFilling(DetectFillingMode());

   // Indicadores base
   h_ATR     = iATR(_Symbol,  PERIOD_M1, Inp_ATRPeriod);
   h_EMAFast = iMA(_Symbol,   PERIOD_M1, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMASlow = iMA(_Symbol,   PERIOD_M1, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol,  PERIOD_M1, Inp_RSIPeriod, PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol, PERIOD_M1, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);

   if(h_ATR == INVALID_HANDLE || h_EMAFast == INVALID_HANDLE ||
      h_EMASlow == INVALID_HANDLE || h_RSI == INVALID_HANDLE ||
      h_MACD == INVALID_HANDLE) {
      Print("[AQ V7.6] ERROR: Indicadores base no iniciados correctamente");
      return INIT_FAILED;
   }

   h_ADX        = iADX(_Symbol, PERIOD_M1, Inp_ADXPeriod);
   h_HTFEMAFast = iMA(_Symbol, Inp_HTFTF, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_HTFEMASlow = iMA(_Symbol, Inp_HTFTF, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);

   // V7.5: Indicadores nuevos
   h_EMA200  = iMA(_Symbol,  PERIOD_M1, Inp_EMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ATRSlow = iATR(_Symbol, PERIOD_M1, Inp_ATRSlowPeriod);

   if(h_EMA200 == INVALID_HANDLE)
      Print("[AQ V7.6] AVISO: EMA200 no pudo crearse. Sensor 3 desactivado.");
   if(h_ATRSlow == INVALID_HANDLE)
      Print("[AQ V7.6] AVISO: ATR lento no pudo crearse. Sensor 4 desactivado.");

   // Inicializar estructuras
   for(int i = 0; i < MAX_RECORDS; i++) ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc);
   ZeroMemory(m_sensors);
   ZeroMemory(m_mkt);

   m_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance   = m_initialBalance;
   m_lastDailyReset = TimeCurrent();

   // Calcular ventana horaria broker (una vez al inicio)
   CalcBrokerTimeWindow();
   Print("[AQ V7.6] Ventana broker: ",
         m_sensors.brokerStartMin / 60, ":", m_sensors.brokerStartMin % 60, " - ",
         m_sensors.brokerEndMin   / 60, ":", m_sensors.brokerEndMin   % 60);

   SyncPositions();
   UpdatePortfolio();

   if(m_port.lbcCount > 0) {
      m_lbc.active        = true;
      m_lbc.activatedTime = TimeCurrent();
      m_lbc.maxOrdersCalc = Inp_LBCMaxPairs;
      Print("[AQ V7.6] LBC: detectadas ", m_port.lbcCount, " posiciones LBC existentes");
   }

   if(m_port.rescueCount > 0)
      Print("[AQ V7.6] RESCATE: detectadas ", m_port.rescueCount,
            " posiciones externas en ", _Symbol);

   if(Inp_ShowDashboard) { DeleteDash(); UpdateDash(); }

   Print("[AQ V7.6] LISTO | Saldo=$", m_initialBalance,
         " | MargPor0.01=$", NormalizeDouble(CalcMarginFor001(),2),
         " | RescueAllTrades=", Inp_RescueAllTrades);
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[AQ V7.6] DETENIDO | PnL=$", NormalizeDouble(m_totalPnL,2),
         " | Abiertas:", m_tradesOpened,
         " | Cerradas:", m_tradesClosed,
         " | Win%:", NormalizeDouble((m_totalWins+m_totalLosses > 0) ?
            (double)m_totalWins/(m_totalWins+m_totalLosses)*100 : 0, 1),
         " | LBC cosechado:$", NormalizeDouble(m_lbc.harvestedTotal,2));

   IndicatorRelease(h_ATR);
   IndicatorRelease(h_EMAFast);
   IndicatorRelease(h_EMASlow);
   IndicatorRelease(h_RSI);
   IndicatorRelease(h_MACD);
   if(h_ADX        != INVALID_HANDLE) IndicatorRelease(h_ADX);
   if(h_HTFEMAFast != INVALID_HANDLE) IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow != INVALID_HANDLE) IndicatorRelease(h_HTFEMASlow);
   // V7.5
   if(h_EMA200     != INVALID_HANDLE) IndicatorRelease(h_EMA200);
   if(h_ATRSlow    != INVALID_HANDLE) IndicatorRelease(h_ATRSlow);

   if(Inp_ShowDashboard) DeleteDash();
}

//=================================================================
//  OnTick - Flujo principal V7.5
//=================================================================
void OnTick()
{
   m_tickCount++;
   UpdateMarket();    // Actualiza bid/ask/ATR/indicadores/EMA200/ATRSlow
   UpdateKalman();    // Suaviza PnL de posiciones propias
   UpdatePortfolio(); // Estado del bloque (propias + rescatadas si Inp_RescueAllTrades)

   // PRIORIDAD 0: NET EXPOSURE HEDGE — cobertura proporcional graduada
   // Se ejecuta ANTES de todo lo demas para blindar la cuenta en movimientos fuertes.
   // NUNCA cierra posiciones existentes, solo abre nuevas coberturas.
   RunNetExposureHedge();

   CheckEquityGuard(); // Solo pausa primarias, recovery sigue (fix V7.3F)
   m_inSession = IsInMainSession();
   ResetDailyIfNeeded();
   bool dailyPaused = DailyLimitReached();

   // Actualizar sensores una vez por tick (eficiente)
   UpdateSensors();

   // V7.6C: Actualizar estado del filtro de tormenta de volatilidad
   // Solo modifica m_stormActive; la decision de bloqueo se aplica en RunCTEngine
   RunVolatilityStormFilter();

   // --- Pausa de ciclo ---
   if(m_cycleInPause) {
      if(TimeCurrent() - m_cycleResetTime >= Inp_CyclePauseSec) {
         m_cycleInPause   = false;
         m_recoveryActive = false;
         m_recoveryOrders = 0;
         m_recoveryTrendHedge = false; // V7.6
         DeactivateLBC();
      } else {
         UpdatePortfolio();
         if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget)
            CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard) UpdateDash();
         return;
      }
   }

   // --- Modo emergencia (fix V7.3F: recovery sigue activo) ---
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
      RunRecoveryEngine(); // Fix V7.3F: recovery opera en emergencia
      RunLBCEngine();
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // Mantenimiento de registros
   if(TimeCurrent() - m_lastCleanupTime > 5) {
      CleanupRecs(); SyncPositions();
      m_lastCleanupTime = TimeCurrent();
   }

   ManagePositions();

   // PRIORIDAD 1: Cierre del bloque cuando es positivo
   if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget) {
      CloseBlockIfPositive("BlockTP");
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // PRIORIDAD 2: Recovery matematico
   RunRecoveryEngine();

   // PRIORIDAD 3: LBC (micro-grid de contingencia)
   RunLBCEngine();

   // PRIORIDAD 4: Basket TP
   RunBasketTP();

   // PRIORIDAD 5: Cycle max loss
   CheckCycleMaxLoss();

   // PRIORIDAD 6: Harvest (solo si bloque positivo)
   RunHarvest();

   // PRIORIDAD 7: CT Engine (sensores solo actuan en Primary_Entry dentro de RunCTEngine)
   if(!m_isPaused && !m_recoveryActive && !m_lbc.active && !dailyPaused)
      RunCTEngine();

   if(Inp_ShowDashboard) UpdateDash();
}

//=================================================================
//  OnChartEvent - Botones del dashboard V7.5
//=================================================================
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp)
{
   if(id == CHARTEVENT_OBJECT_CLICK) {
      // Boton PAUSA/RESUME: afecta operativa propia Y logica de rescate
      if(sp == "AQ75_B1") {
         m_isPaused = !m_isPaused;
         if(!m_isPaused) {
            m_emergencyMode  = false;
            m_dailyLimitHit  = false;
            m_recoveryActive = false;
            m_recoveryOrders = 0;
         m_recoveryTrendHedge = false; // V7.6
            m_netHedge1Applied = false; // V7.6B
            m_netHedge2Applied = false; // V7.6B
            DeactivateLBC();
            Print("[AQ V7.6B] SISTEMA REANUDADO (propias + rescate)");
         } else {
            Print("[AQ V7.6] SISTEMA PAUSADO (recovery/LBC/rescue siguen si hay posiciones)");
         }
      }

      // Boton CERRAR TODAS: cierra posiciones propias Y rescatadas
      if(sp == "AQ75_B2") {
         Print("[AQ V7.6] CIERRE MANUAL solicitado...");
         int closed = 0;

         // Cerrar propias primero
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
            if(ClosePos(t, "Manual")) closed++;
         }

         // Si rescate activo, cerrar externas tambien
         if(Inp_RescueAllTrades) {
            for(int i = PositionsTotal() - 1; i >= 0; i--) {
               ulong t = PositionGetTicket(i);
               if(!PositionSelectByTicket(t)) continue;
               if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
               if(PositionGetInteger(POSITION_MAGIC) == Inp_Magic) continue; // Ya cerradas
               if(CloseRescuePos(t, "Manual_Rescue")) closed++;
            }
         }

         m_lastCTBuyPrice    = m_lastCTSellPrice = 0;
         m_consecutiveLosses = 0;
         m_lotMultiplier     = 1.0;
         m_cycleInPause      = false;
         m_recoveryActive    = false;
         m_recoveryOrders    = 0;
         m_lastPrimaryDir    = 0;
         m_lastPrimaryLost   = false;
         m_netHedge1Applied  = false; // V7.6B
         m_netHedge2Applied  = false; // V7.6B
         DeactivateLBC();
         Print("[AQ V7.6B] CIERRE MANUAL completo: ", closed, " posiciones cerradas");
      }

      // Compatibilidad hacia atras: botones del dashboard V7.3
      if(sp == "D73_B1") {
         m_isPaused = !m_isPaused;
         Print("[AQ V7.6] Boton V7.3 detectado -> redirigido");
      }

      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+