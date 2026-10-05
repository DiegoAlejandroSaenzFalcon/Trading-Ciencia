//+------------------------------------------------------------------+
//|   APEXQUANT - V7.7  "USD CONTROL + ANTI-CATASTROPHE ENGINE"     |
//|                                                                  |
//|   BASE: V7.5 (Rescue Universal) + V7.6 (Trend-Aware Recovery)  |
//|                                                                  |
//|   NUEVAS CARACTERISTICAS V7.7:                                   |
//|                                                                  |
//|   [1] MODO USD PURO (Inp_UseUSDMode = true):                    |
//|       Toda la logica de apertura/recovery/CT se basa en         |
//|       perdidas y ganancias en dolares. Sin dependencia de ATR   |
//|       para decisiones criticas. Parametros clave:               |
//|         Inp_CTTriggerUSD    -> CT abre cuando lado pierde $X    |
//|         Inp_RecoveryStepUSD -> Siguiente recovery cada $X mas   |
//|         Inp_PanicHedgeUSD   -> Hedge total al llegar a -$X      |
//|                                                                  |
//|   [2] PANIC HEDGE MEJORADO (de Gemini, corregido):              |
//|       Calcula volumen neto y abre orden opuesta para dejar      |
//|       exposure = 0. Congela la perdida maxima. EA pausa normal  |
//|       pero Recovery sigue activo para intentar recuperar.       |
//|       NUEVO: seguimiento de m_panicHedgeActive para evitar      |
//|       hedges multiples y permitir unwind manual.                |
//|                                                                  |
//|   [3] RECOVERY TREND-AWARE (fix critico V7.6 preservado):      |
//|       BUYs perdiendo + BEAR confirmado -> abre SELL.            |
//|       SELLs perdiendo + BULL confirmado -> abre BUY.            |
//|       Sin tendencia clara -> promediado clasico.                |
//|       CalcRecoveryLot: INTOCABLE (solo cambia direccion).       |
//|                                                                  |
//|   [4] RECOVERY POR ESCALONES USD:                               |
//|       En lugar de esperar distancia ATR, el engine abre el      |
//|       siguiente recovery cada vez que la perdida cae un         |
//|       escalon adicional de Inp_RecoveryStepUSD.                 |
//|                                                                  |
//|   INVARIANTES INAMOVIBLES (heredados de V7.3F):                |
//|   - SL = 0 en TODAS las ordenes                                 |
//|   - TP individual = 0                                           |
//|   - UNICO cierre: bloque neto > BlockTPTarget                  |
//|   - EquityGuard NO bloquea Recovery/LBC                        |
//|   - CalcRecoveryLot: INTOCABLE                                  |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V7.7 - USD Control Anti-Catastrophe"
#property version   "7.70"
#property strict
#property description "XAUUSD 24/7 | ApexQuant V7.7 | USD Mode + Panic Hedge + Trend Recovery"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS  80
#define VERSION_STR  "APEXQUANT_V7.7"

enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

//=================================================================
//  PARAMETROS
//=================================================================
input group "=== [V7.7] MODO USD PURO ==="
// Si true: toda la logica de distancias usa USD en lugar de ATR
input bool   Inp_UseUSDMode           = true;
// CT se abre cuando el lado perdedor supera esta perdida en USD
input double Inp_CTTriggerUSD         = 0.30;
// Recovery adicional cada vez que la perdida baja X dolares mas
input double Inp_RecoveryStepUSD      = 0.40;

input group "=== [V7.7] PANIC HEDGE (CONGELADOR DE PERDIDAS) ==="
// Activar el hedge de panico
input bool   Inp_UsePanicHedge        = true;
// Si el bloque llega a esta perdida en USD, se cubre el 100% del volumen neto
input double Inp_PanicHedgeUSD        = -15.0;

input group "=== CONFIGURACION PRINCIPAL ==="
input long   Inp_Magic                = 7001;
input int    Inp_MaxPositionsTotal    = 8;
input double Inp_LotBase              = 0.01;
input double Inp_LotMaximum           = 0.10;
input double Inp_RiskPerTradePct      = 0.01;
input bool   Inp_UseDynamicLot        = true;
input double Inp_CTMinBalanceUSD      = 40.0;
input double Inp_MinFreeMarginPct     = 0.20;

input group "=== [V7.5] RESCATE UNIVERSAL ==="
input bool   Inp_RescueAllTrades      = true;

input group "=== CIERRE DEL BLOQUE ==="
input double Inp_BlockTPTarget        = 0.50;
input double Inp_TP_ATR               = 2.5;
input double Inp_SL_ATR               = 1.2;
input double Inp_OffSessionTP_ATR     = 2.2;
input double Inp_OffSessionSL_ATR     = 1.0;

input group "=== RECOVERY ENGINE ==="
// Disparador: activa recovery cuando el bloque pierde este USD
input double Inp_RecoveryTriggerUSD   = -0.50;
// Distancia ATR (solo si Inp_UseUSDMode = false)
input double Inp_RecoveryMinDistATR   = 1.5;
input double Inp_RecoveryMoveATR      = 0.5;
input double Inp_RecoveryMinLotMult   = 2.0;
// Max ordenes en modo promediado clasico (sin tendencia clara)
input int    Inp_RecoveryMaxOrders    = 3;
// Max ordenes en modo hedge tendencia (bear->sell, bull->buy)
input int    Inp_RecoveryMaxOrdersTrend = 5;
input int    Inp_RecoveryIntervalSec  = 10;

input group "=== LBC: CONTINGENCIA BALANCE BAJO ==="
input int    Inp_LBCMaxPairs          = 4;
input double Inp_LBCGridATR           = 0.30;
input double Inp_LBCHarvestATR        = 0.15;
input int    Inp_LBCIntervalSec       = 8;
input double Inp_LBCMarginPct         = 0.55;

input group "=== COUNTER-TRADE ENGINE ==="
input ENUM_CT_MODE Inp_CTMode         = CT_ATR_DISTANCE;
input double Inp_CTDistanceATR        = 1.2;
input int    Inp_CTFixedPoints        = 100;
input int    Inp_CTIntervalSec        = 10;
input int    Inp_CTMaxSameDir         = 3;
input int    Inp_PrimaryCooldownSec   = 90;
input int    Inp_PrimaryCooldownOff   = 150;
input double Inp_CTMaxSpreadPoints    = 30;
input double Inp_CTMaxSpreadOff       = 20;

input group "=== [V7.5] SENSORES INSTITUCIONALES ==="
input bool   Inp_UseTimeFilter        = true;
input int    Inp_UserGMT              = -5;
input int    Inp_BrokerGMT            = 2;
input string Inp_StartTime            = "07:30";
input string Inp_EndTime              = "15:00";
input int    Inp_MaxSpread            = 35;
input bool   Inp_UseTrendFilter200    = true;
input int    Inp_EMA200Period         = 200;
input bool   Inp_UseVolatFilter       = true;
input int    Inp_ATRSlowPeriod        = 100;
input double Inp_ATRRatioMax          = 2.5;
input bool   Inp_UseMarginGuard       = true;
input int    Inp_MarginGuardLevels    = 3;

input group "=== SESIONES ==="
input int    Inp_GMTOffset            = 0;
input int    Inp_LondonOpen           = 7;
input int    Inp_LondonClose          = 17;
input int    Inp_NYOpen               = 13;
input int    Inp_NYClose              = 22;
input double Inp_OffSessionLotFactor  = 0.50;

input group "=== BASKET TP ==="
input bool   Inp_UseBasketTP          = true;
input double Inp_BasketTPFactor       = 0.60;
input double Inp_BasketTPRatio        = 1.5;
input int    Inp_BasketCheckSec       = 3;

input group "=== HARVEST ==="
input double Inp_HarvestMinUSD        = 0.80;
input double Inp_HarvestATRMult       = 0.20;
input bool   Inp_HarvestContinuous    = true;
input int    Inp_HarvestIntervalSec   = 3;

input group "=== CYCLE CONTROL ==="
input bool   Inp_UseCycleMaxLoss      = true;
input double Inp_CycleMaxLossUSD      = -3.00;
input int    Inp_CyclePauseSec        = 30;

input group "=== ADX + HTF ==="
input bool   Inp_UseADX               = true;
input int    Inp_ADXPeriod            = 14;
input double Inp_ADXTrendLevel        = 30.0;
input double Inp_ADXTrendLevelOff     = 22.0;
input bool   Inp_UseHTF               = true;
input ENUM_TIMEFRAMES Inp_HTFTF       = PERIOD_M5;

input group "=== PROTECCION DIARIA ==="
input bool   Inp_UseDailyLimit        = true;
input double Inp_DailyLossUSD         = -5.0;
input double Inp_DailyLossPct         = 0.025;
input int    Inp_LossStreakMax         = 4;
input double Inp_LossStreakReduce      = 0.70;

input group "=== EQUITY GUARD ==="
input bool   Inp_UseEquityGuard       = true;
input double Inp_EmergencyLossUSD     = -8.0;
input double Inp_MaxDrawdownPct       = 0.20;
input int    Inp_EmergencyCooldown    = 180;

input group "=== INDICADORES BASE ==="
input int    Inp_ATRPeriod            = 14;
input int    Inp_EMAFast              = 21;
input int    Inp_EMASlow              = 55;
input int    Inp_RSIPeriod            = 7;
input int    Inp_MACDFast             = 12;
input int    Inp_MACDSlow             = 26;
input int    Inp_MACDSig              = 9;

input group "=== CONTROL VISUAL ==="
input bool   Inp_ShowDashboard        = true;
input int    Inp_DashX                = 12;
input int    Inp_DashY                = 28;

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
   int    buyCount,  sellCount;
   double buyProfit, sellProfit;
   double buyVolume, sellVolume;   // V7.7: para calculo de hedge
   double totalProfit;
   double positiveSum, negativeSum;
   ulong  worstTicket;
   double worstProfit;
   int    ctCount, recoveryCount, lbcCount;
   double currentDD;
   double blockVWAP;
   int    blockDir;
   int    rescueCount;
   double rescueProfit;
};

struct MarketSnap {
   double bid, ask, atr, emaFast, emaSlow, rsi, macdMain, macdSig, adx, spread;
   int    htfTrend;
   bool   isBullish, isBearish;
   double atrSlow;
   double ema200;
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

struct SensorState {
   bool   timeOK, spreadOK, trendBull, volatOK, marginOK, allOK;
   string blockReason;
   double atrRatio;
   int    brokerStartMin, brokerEndMin;
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

double   m_initialBalance     = 0;
double   m_bestEquity         = 0;
bool     m_isPaused           = false;
bool     m_emergencyMode      = false;
bool     m_dailyLimitHit      = false;
bool     m_inSession          = false;

// Recovery state
bool     m_recoveryActive     = false;
int      m_recoveryOrders     = 0;
bool     m_recoveryTrendHedge = false; // V7.7: true = modo hedge tendencia
double   m_lastRecoveryUSD    = 0;     // V7.7: nivel USD del ultimo recovery

// Panic hedge state
bool     m_panicHedgeActive   = false; // V7.7: hedge de panico activo

// Cycle state
double   m_cycleWinsSum       = 0;
int      m_cycleWinsCount     = 0;
double   m_cycleLossSum       = 0;
bool     m_cycleInPause       = false;
datetime m_cycleResetTime     = 0;

// Streaks
int      m_consecutiveLosses  = 0;
double   m_lotMultiplier      = 1.0;
double   m_dailyBalance       = 0;
datetime m_lastDailyReset     = 0;
int      m_lastPrimaryDir     = 0;
datetime m_lastPrimaryTime    = 0;
bool     m_lastPrimaryLost    = false;

// CT tracking
double   m_lastCTBuyPrice     = 0;
double   m_lastCTSellPrice    = 0;

// Timers
datetime m_lastCTTime         = 0;
datetime m_lastRecoveryTime   = 0;
datetime m_lastBasketCheck    = 0;
datetime m_lastHarvestTime    = 0;
datetime m_lastDashTime       = 0;
datetime m_lastCleanupTime    = 0;

// Stats
double   m_totalPnL           = 0;
int      m_tradesOpened       = 0;
int      m_tradesClosed       = 0;
double   m_bestClosed         = 0;
double   m_worstClosed        = 0;
int      m_totalWins          = 0;
int      m_totalLosses        = 0;
double   m_sumWins            = 0;
double   m_sumLosses          = 0;
long     m_tickCount          = 0;
bool     m_isProcessing       = false;
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

bool GetTick(MqlTick &t)   { return SymbolInfoTick(_Symbol, t); }
double GetATR()            { double b[1]; return (CopyBuffer(h_ATR,0,1,1,b)==1) ? b[0] : _Point*200; }
double GetTickVal()        { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize()       { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); }

double DistToUSD(double dist, double lot)
{
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv<=0 || ts<=0 || dist<=0 || lot<=0) return 0;
   return NormalizeDouble((dist/ts)*tv*lot, 2);
}

// V7.7: Convierte USD a distancia de precio para un lote dado
double USDToDist(double usd, double lot)
{
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv<=0 || ts<=0 || lot<=0) return m_mkt.atr * 0.5;
   double pplp = tv / ts; // profit per lot per point
   if(pplp <= 0) return m_mkt.atr * 0.5;
   return MathAbs(usd) / (lot * pplp);
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

// MarginOK_Panic: solo verifica margen minimo absoluto (para hedges de emergencia)
bool MarginOK_Panic(double lot, ENUM_ORDER_TYPE type)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free <= 0) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg))
      return (marg <= free * 0.90);
   return true;
}

double CalcMarginFor001()
{
   double marg = 0; MqlTick t; GetTick(t);
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 0.01, t.ask, marg)) return 2.0;
   return (marg > 0) ? marg : 2.0;
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
             string comment, bool isPri, bool isCT, bool isRec=false, bool isLBC=false)
{
   if(idx<0 || idx>=MAX_RECORDS) return;
   ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket    = ticket;   m_rec[idx].posType   = posType;
   m_rec[idx].openPrice = openPrice; m_rec[idx].volume    = vol;
   m_rec[idx].openTime  = TimeCurrent(); m_rec[idx].comment = comment;
   m_rec[idx].isPrimary = isPri;    m_rec[idx].isCounter = isCT;
   m_rec[idx].isRecovery= isRec;    m_rec[idx].isLBC     = isLBC;
   m_rec[idx].kP = 1.0;             m_rec[idx].kK        = 1.0;
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
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;
      if(FindRec(t) >= 0) continue;
      int idx = FreeRec(); if(idx < 0) continue;
      string comm = PositionGetString(POSITION_COMMENT);
      InitRec(idx, t,
              (int)PositionGetInteger(POSITION_TYPE),
              PositionGetDouble(POSITION_PRICE_OPEN),
              PositionGetDouble(POSITION_VOLUME), comm,
              StringFind(comm,"Primary")>=0, StringFind(comm,"CT_")>=0,
              StringFind(comm,"REC_")>=0,     StringFind(comm,"LBC_")>=0);
   }
}

//=================================================================
//  KALMAN
//=================================================================
void KalmanUpdate(int idx, double meas)
{
   if(!m_rec[idx].kInit) {
      m_rec[idx].kX=meas; m_rec[idx].kP=1.0; m_rec[idx].kK=1.0; m_rec[idx].kInit=true; return;
   }
   double pP = m_rec[idx].kP + 0.01;
   double K  = pP / (pP + 0.20);
   m_rec[idx].kX = m_rec[idx].kX + K*(meas - m_rec[idx].kX);
   m_rec[idx].kP = (1.0-K)*pP; m_rec[idx].kK = K;
}
void UpdateKalman()
{
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      int idx = FindRec(t); if(idx < 0) continue;
      double pf = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit = pf;
      if(pf > m_rec[idx].peakProfit) m_rec[idx].peakProfit = pf;
      KalmanUpdate(idx, pf);
   }
}

//=================================================================
//  MERCADO Y PORTFOLIO
//=================================================================
bool IsInMainSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week==0 || dt.day_of_week==6) return false;
   int gmtHour = (dt.hour - Inp_GMTOffset + 24) % 24;
   return ((gmtHour>=Inp_LondonOpen && gmtHour<Inp_LondonClose) ||
           (gmtHour>=Inp_NYOpen     && gmtHour<Inp_NYClose));
}

void UpdateMarket()
{
   MqlTick t; if(!GetTick(t)) return;
   m_mkt.bid=t.bid; m_mkt.ask=t.ask; m_mkt.spread=(t.ask-t.bid)/_Point; m_mkt.atr=GetATR();
   double f[1],s[1],r[1],m[1],sg[1];
   if(CopyBuffer(h_EMAFast,0,0,1,f)==1) m_mkt.emaFast=f[0];
   if(CopyBuffer(h_EMASlow,0,0,1,s)==1) m_mkt.emaSlow=s[0];
   if(CopyBuffer(h_RSI,0,0,1,r)==1)     m_mkt.rsi=r[0];
   if(CopyBuffer(h_MACD,0,0,1,m)==1)    m_mkt.macdMain=m[0];
   if(CopyBuffer(h_MACD,1,0,1,sg)==1)   m_mkt.macdSig=sg[0];
   if(h_ADX!=INVALID_HANDLE) { double a[1]; if(CopyBuffer(h_ADX,0,0,1,a)==1) m_mkt.adx=a[0]; }
   if(h_HTFEMAFast!=INVALID_HANDLE && h_HTFEMASlow!=INVALID_HANDLE) {
      double hf[1],hs[1];
      if(CopyBuffer(h_HTFEMAFast,0,0,1,hf)==1 && CopyBuffer(h_HTFEMASlow,0,0,1,hs)==1)
         m_mkt.htfTrend=(hf[0]>hs[0]*1.0001)?1:(hf[0]<hs[0]*0.9999)?-1:0;
   }
   if(h_EMA200!=INVALID_HANDLE)  { double e[1]; if(CopyBuffer(h_EMA200,0,1,1,e)==1)  m_mkt.ema200=e[0]; }
   if(h_ATRSlow!=INVALID_HANDLE) { double a[1]; if(CopyBuffer(h_ATRSlow,0,1,1,a)==1) m_mkt.atrSlow=a[0]; }
   m_mkt.isBullish=(m_mkt.emaFast>m_mkt.emaSlow && m_mkt.rsi>52 && m_mkt.macdMain>m_mkt.macdSig);
   m_mkt.isBearish=(m_mkt.emaFast<m_mkt.emaSlow && m_mkt.rsi<48 && m_mkt.macdMain<m_mkt.macdSig);
}

void UpdatePortfolio()
{
   ZeroMemory(m_port);
   m_port.worstProfit=0; m_losingPosOpenPrice=0; m_losingPosType=-1;
   double vwapN=0, vwapD=0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      long   magic = PositionGetInteger(POSITION_MAGIC);
      bool   isOwn = (magic == Inp_Magic);
      bool   isExt = (!isOwn && Inp_RescueAllTrades);
      if(!isOwn && !isExt) continue;
      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double pf   = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      string comm = PositionGetString(POSITION_COMMENT);
      m_port.totalPos++;
      m_port.totalProfit += pf;
      if(pf>=0) m_port.positiveSum+=pf; else m_port.negativeSum+=MathAbs(pf);
      if(pt==POSITION_TYPE_BUY)
         { m_port.buyCount++;  m_port.buyProfit +=pf; m_port.buyVolume +=vol; }
      else
         { m_port.sellCount++; m_port.sellProfit+=pf; m_port.sellVolume+=vol; }
      vwapN+=op*vol; vwapD+=vol;
      m_port.blockDir += (pt==POSITION_TYPE_BUY)?1:-1;
      if(pf < m_port.worstProfit) {
         m_port.worstProfit=pf; m_port.worstTicket=t;
         m_losingPosOpenPrice=op; m_losingPosType=pt;
      }
      if(isOwn) {
         if(StringFind(comm,"CT_") >=0) m_port.ctCount++;
         if(StringFind(comm,"REC_")>=0) m_port.recoveryCount++;
         if(StringFind(comm,"LBC_")>=0) m_port.lbcCount++;
      }
      if(isExt) { m_port.rescueCount++; m_port.rescueProfit+=pf; }
   }
   if(vwapD>0) m_port.blockVWAP=vwapN/vwapD;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>m_bestEquity) m_bestEquity=eq;
   m_port.currentDD=(m_bestEquity>0)?(m_bestEquity-eq)/m_bestEquity:0;
}

//=================================================================
//  SENSORES V7.5
//=================================================================
int ParseHH(string t) { return (int)StringToInteger(StringSubstr(t,0,2)); }
int ParseMM(string t) { return (int)StringToInteger(StringSubstr(t,3,2)); }

void CalcBrokerTimeWindow()
{
   int sU=ParseHH(Inp_StartTime)*60+ParseMM(Inp_StartTime);
   int eU=ParseHH(Inp_EndTime)  *60+ParseMM(Inp_EndTime);
   int off=(Inp_BrokerGMT-Inp_UserGMT)*60;
   m_sensors.brokerStartMin=((sU+off)%1440+1440)%1440;
   m_sensors.brokerEndMin  =((eU+off)%1440+1440)%1440;
}
bool IsInTradingWindow()
{
   if(!Inp_UseTimeFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int now=dt.hour*60+dt.min, s=m_sensors.brokerStartMin, e=m_sensors.brokerEndMin;
   return (s<=e)?(now>=s && now<e):(now>=s || now<e);
}
bool TrendFilter200OK(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseTrendFilter200 || m_mkt.ema200<=0) return true;
   MqlTick tk; if(!GetTick(tk)) return true;
   double mid=(tk.bid+tk.ask)/2.0;
   if(type==ORDER_TYPE_BUY)  return (mid>m_mkt.ema200);
   if(type==ORDER_TYPE_SELL) return (mid<m_mkt.ema200);
   return true;
}
bool VolatilityOK()
{
   if(!Inp_UseVolatFilter || m_mkt.atrSlow<=0) return true;
   m_sensors.atrRatio=m_mkt.atr/m_mkt.atrSlow;
   return (m_sensors.atrRatio<=Inp_ATRRatioMax);
}
bool MarginGuardOK()
{
   if(!Inp_UseMarginGuard) return true;
   double lot=NormLot(Inp_LotBase), marg1=0;
   MqlTick tk; if(!GetTick(tk)) return true;
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,lot,tk.ask,marg1)) return true;
   if(marg1<=0) return true;
   return (AccountInfoDouble(ACCOUNT_MARGIN_FREE) >= marg1*(1.0+Inp_MarginGuardLevels));
}
bool ADXAllowsEntry(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseADX) return true;
   double lv=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   if(m_mkt.adx<lv) return true;
   int htf=m_mkt.htfTrend; if(htf==0) return false;
   return (type==ORDER_TYPE_BUY&&htf==1)||(type==ORDER_TYPE_SELL&&htf==-1);
}
void UpdateSensors()
{
   m_sensors.blockReason="";
   m_sensors.timeOK  =IsInTradingWindow();
   if(!m_sensors.timeOK   && m_sensors.blockReason=="") m_sensors.blockReason="Fuera de ventana horaria";
   m_sensors.spreadOK=SpreadOK();
   if(!m_sensors.spreadOK && m_sensors.blockReason=="") m_sensors.blockReason="Spread alto";
   if(m_mkt.ema200>0) { MqlTick tk; GetTick(tk); m_sensors.trendBull=((tk.bid+tk.ask)/2.0>m_mkt.ema200); } else m_sensors.trendBull=true;
   m_sensors.volatOK =VolatilityOK();
   if(!m_sensors.volatOK  && m_sensors.blockReason=="") m_sensors.blockReason="Tormenta ATR";
   m_sensors.marginOK=MarginGuardOK();
   if(!m_sensors.marginOK && m_sensors.blockReason=="") m_sensors.blockReason="Margen insuf.";
   m_sensors.allOK=(m_sensors.timeOK&&m_sensors.spreadOK&&m_sensors.volatOK&&m_sensors.marginOK);
}

//=================================================================
//  DIARIO
//=================================================================
void ResetDailyIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int sec=dt.hour*3600+dt.min*60+dt.sec;
   datetime midnight=TimeCurrent()-sec;
   if(m_lastDailyReset<midnight) {
      m_dailyBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      m_dailyLimitHit=false; m_lastDailyReset=midnight;
   }
}
bool DailyLimitReached()
{
   if(!Inp_UseDailyLimit) return false;
   if(m_dailyLimitHit) return true;
   double eff=(AccountInfoDouble(ACCOUNT_BALANCE)-m_dailyBalance)+m_port.totalProfit;
   double lim=MathMin(MathAbs(Inp_DailyLossUSD),m_dailyBalance*MathAbs(Inp_DailyLossPct));
   if(eff<=-lim) { m_dailyLimitHit=true; m_isPaused=true; }
   return m_dailyLimitHit;
}
void UpdateStreak(double pnl)
{
   if(pnl < -0.01) {
      m_consecutiveLosses++;
      if(m_consecutiveLosses>=Inp_LossStreakMax && m_lotMultiplier==1.0) m_lotMultiplier=Inp_LossStreakReduce;
   } else if(pnl > 0.01) { m_lotMultiplier=1.0; m_consecutiveLosses=0; }
}
double CalcExpectancy()
{
   int total=m_totalWins+m_totalLosses; if(total==0) return 0;
   double wr=(double)m_totalWins/total;
   return wr*(m_totalWins>0?m_sumWins/m_totalWins:0) - (1.0-wr)*(m_totalLosses>0?m_sumLosses/m_totalLosses:0);
}

//=================================================================
//  CIERRE
//=================================================================
bool ClosePos(ulong ticket, string reason="")
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) return false;
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)) {
      UpdateStreak(pf);
      if(pf>0) { m_cycleWinsSum+=pf; m_cycleWinsCount++; m_totalWins++;   m_sumWins  +=pf; }
      else      { m_cycleLossSum+=pf; m_totalLosses++;                     m_sumLosses+=MathAbs(pf); }
      m_totalPnL+=pf; m_tradesClosed++;
      if(pf>m_bestClosed)  m_bestClosed =pf;
      if(pf<m_worstClosed) m_worstClosed=pf;
      int idx=FindRec(ticket);
      if(idx>=0) {
         if(m_rec[idx].isPrimary) m_lastPrimaryLost=(pf<0);
         if(m_rec[idx].isLBC) {
            if(StringFind(m_rec[idx].comment,"LBC_B")>=0 && m_lbc.buyCount>0)  m_lbc.buyCount--;
            if(StringFind(m_rec[idx].comment,"LBC_S")>=0 && m_lbc.sellCount>0) m_lbc.sellCount--;
            if(pf>0) { m_lbc.harvestedTotal+=pf; m_lbc.harvestCount++; }
         }
         Print("[AQ V7.7] CERRADA #",ticket," $",NormalizeDouble(pf,2)," [",reason,"]");
         ZeroMemory(m_rec[idx]);
      }
      return true;
   }
   return false;
}
bool CloseRescuePos(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)) { m_totalPnL+=pf; m_tradesClosed++; return true; }
   return false;
}
bool CloseBlockIfPositive(string reason)
{
   if(m_port.totalProfit < Inp_BlockTPTarget) return false;
   Print("[AQ V7.7] CIERRE POSITIVO: $",NormalizeDouble(m_port.totalProfit,2)," [",reason,"]");
   m_isProcessing=true;
   for(int pass=0; pass<2; pass++) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pass==0&&pf<0) continue; if(pass==1&&pf>=0) continue;
         ClosePos(t,reason);
      }
   }
   if(Inp_RescueAllTrades) {
      for(int pass=0; pass<2; pass++) {
         for(int i=PositionsTotal()-1; i>=0; i--) {
            ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC)==Inp_Magic) continue;
            double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
            if(pass==0&&pf<0) continue; if(pass==1&&pf>=0) continue;
            CloseRescuePos(t,"RESCUE_"+reason);
         }
      }
   }
   m_isProcessing=false;
   m_recoveryActive=false; m_recoveryOrders=0; m_recoveryTrendHedge=false;
   m_lastRecoveryUSD=0;    m_panicHedgeActive=false;
   m_cycleResetTime=TimeCurrent(); m_cycleInPause=true;
   m_lastCTBuyPrice=m_lastCTSellPrice=0; ZeroMemory(m_lbc);
   m_emergencyMode=false;
   return true;
}

//=================================================================
//  APERTURA - SL=0, TP=0 siempre
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type, double lot, string comment,
                bool skipPosLimit=false, bool isPanic=false)
{
   // Fix V7.3F: pausa/emergencia solo bloquea primarias
   if((m_isPaused||m_emergencyMode) && !skipPosLimit && !isPanic) return 0;
   if(!SpreadOK() && !isPanic) return 0;
   if(!skipPosLimit && PositionsTotal()>=Inp_MaxPositionsTotal) return 0;
   if(skipPosLimit && !isPanic && PositionsTotal()>=Inp_MaxPositionsTotal+4) return 0;
   lot=NormLot(lot); if(lot<=0) return 0;
   if(!isPanic && !MarginOK(lot,type)) return 0;
   if(isPanic  && !MarginOK_Panic(lot,type)) return 0;

   MqlTick t; if(!GetTick(t)) return 0;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid;
   bool ok=(type==ORDER_TYPE_BUY)
      ? m_trade.Buy( lot,_Symbol,price,0,0,comment)
      : m_trade.Sell(lot,_Symbol,price,0,0,comment);
   if(!ok) { Print("[AQ V7.7] ERR apertura: ",m_trade.ResultRetcodeDescription()); return 0; }
   ulong ticket=m_trade.ResultOrder();
   if(ticket>0) {
      m_tradesOpened++;
      Print("[AQ V7.7] ABIERTA #",ticket," ",(type==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=",lot," @ ",NormalizeDouble(price,_Digits)," [",comment,"]");
   }
   return ticket;
}

//=================================================================
//  LOTES
//=================================================================
double CalcLot(int level=0)
{
   double sf=m_inSession?1.0:Inp_OffSessionLotFactor;
   if(!Inp_UseDynamicLot || m_mkt.atr<=0) return NormLot(Inp_LotBase*m_lotMultiplier*sf);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double rUSD=bal*Inp_RiskPerTradePct;
   double slDist=m_mkt.atr*(m_inSession?Inp_SL_ATR:Inp_OffSessionSL_ATR);
   double tv=GetTickVal(), ts=GetTickSize(), lot=Inp_LotBase;
   if(tv>0&&ts>0&&slDist>0) { double pv=tv/ts; if(pv>0) lot=rUSD/(slDist*pv); }
   return NormLot(MathMax(lot,Inp_LotBase)*m_lotMultiplier*sf);
}

// INTOCABLE: CalcRecoveryLot
double CalcRecoveryLot()
{
   double atr=m_mkt.atr;
   if(atr<=0) return NormLot(Inp_LotBase*Inp_RecoveryMinLotMult);
   double totalNeeded=MathAbs(m_port.totalProfit)+Inp_BlockTPTarget;
   double moveDist=atr*Inp_RecoveryMoveATR; if(moveDist<=0) moveDist=atr*0.5;
   double tv=GetTickVal(), ts=GetTickSize(), ppl=0;
   if(tv>0&&ts>0) ppl=(moveDist/ts)*tv;
   double calcLot=Inp_LotBase; if(ppl>0) calcLot=totalNeeded/ppl;
   double loserLot=Inp_LotBase;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pf==m_port.worstProfit) { loserLot=PositionGetDouble(POSITION_VOLUME); break; }
   }
   double finalLot=MathMax(calcLot, loserLot*Inp_RecoveryMinLotMult);
   Print("[AQ V7.7] REC LOT: necesito $",NormalizeDouble(totalNeeded,2),
         " | calc=",NormalizeDouble(calcLot,2)," | final=",NormalizeDouble(NormLot(finalLot),2));
   return NormLot(finalLot);
}

//=================================================================
//  V7.7: PANIC HEDGE - CONGELADOR DE PERDIDAS
//  Cuando el bloque toca Inp_PanicHedgeUSD, abre una orden opuesta
//  por el volumen neto para que la perdida no pueda crecer mas.
//  Solo se activa una vez por ciclo (m_panicHedgeActive lo protege).
//=================================================================
void RunPanicHedge()
{
   if(!Inp_UsePanicHedge || m_port.totalPos==0 || m_isProcessing) return;
   if(m_panicHedgeActive) return; // Ya cubiertos en este ciclo
   if(m_port.totalProfit > Inp_PanicHedgeUSD) return;

   double netVol = NormalizeDouble(m_port.buyVolume - m_port.sellVolume, 2);
   if(netVol == 0) { m_panicHedgeActive=true; return; } // Ya hedgeados

   ENUM_ORDER_TYPE hedgeType = (netVol>0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   double hedgeLot = NormLot(MathAbs(netVol));
   if(hedgeLot <= 0) return;

   Print("[AQ V7.7] !!! PANIC HEDGE !!! PnL=$",NormalizeDouble(m_port.totalProfit,2),
         " Limite=$",Inp_PanicHedgeUSD,
         " | Cubriendo ",hedgeLot," lotes con ",(hedgeType==ORDER_TYPE_BUY?"BUY":"SELL"));

   m_isProcessing=true;
   ulong ticket=OpenOrder(hedgeType, hedgeLot, "PANIC_HEDGE", true, true);
   m_isProcessing=false;

   if(ticket>0) {
      m_panicHedgeActive=true;
      // La perdida queda congelada. Activamos emergencia para bloquear
      // nuevas primarias pero el recovery sigue activo para intentar recuperar
      m_emergencyMode=true;
      m_isPaused=true;
      int idx=FreeRec();
      if(idx>=0) {
         MqlTick tk; GetTick(tk);
         int pt=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
         double op=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
         InitRec(idx,ticket,pt,op,hedgeLot,"PANIC_HEDGE",false,false,true,false);
      }
   }
}

//=================================================================
//  V7.7: RECOVERY ENGINE - TREND-AWARE + USD STEPS
//
//  Modo USD (Inp_UseUSDMode=true):
//    Primer recovery: cuando totalProfit < Inp_RecoveryTriggerUSD
//    Siguientes:      cada vez que la perdida baja Inp_RecoveryStepUSD mas
//    Sin filtro de distancia ATR.
//
//  Modo ATR (Inp_UseUSDMode=false):
//    Comportamiento clasico de V7.5.
//
//  Direccion (V7.6 fix preservado):
//    BEAR confirmado + BUYs pierden  -> SELL (hedge tendencia)
//    BULL confirmado + SELLs pierden -> BUY  (hedge tendencia)
//    Sin tendencia clara             -> Promediado clasico
//=================================================================
void RunRecoveryEngine()
{
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD) {
      if(m_recoveryActive) {
         m_recoveryActive=false; m_recoveryOrders=0;
         m_recoveryTrendHedge=false; m_lastRecoveryUSD=0;
      }
      return;
   }
   if(m_port.totalPos==0 || m_isProcessing) return;
   if(CloseBlockIfPositive("Recovery_TP")) return;

   if(!m_recoveryActive) {
      m_recoveryActive     =true;
      m_recoveryOrders     =m_port.recoveryCount;
      m_recoveryTrendHedge =false;
      m_lastRecoveryUSD    =m_port.totalProfit; // anclar al nivel actual
      Print("[AQ V7.7] RECOVERY ACTIVADO | PnL=$",NormalizeDouble(m_port.totalProfit,2),
            " | Rescate:",m_port.rescueCount," pos externas");
   }

   // Limite de ordenes segun modo
   int maxRec = m_recoveryTrendHedge ? Inp_RecoveryMaxOrdersTrend : Inp_RecoveryMaxOrders;
   if(m_recoveryOrders >= maxRec) return;
   if(TimeCurrent() - m_lastRecoveryTime < Inp_RecoveryIntervalSec) return;
   if(!SpreadOK()) return;

   MqlTick tk; if(!GetTick(tk)) return;
   double atr=m_mkt.atr; if(atr<=0) return;

   //--------------------------------------------------------------
   // GATE DE DISTANCIA: USD o ATR segun modo
   //--------------------------------------------------------------
   if(Inp_UseUSDMode) {
      // Modo USD: abrir siguiente recovery cuando la perdida aumenta un escalon
      // El primer recovery se abre inmediatamente (m_recoveryOrders==0 o initial)
      if(m_recoveryOrders > 0) {
         double stepNeeded = m_lastRecoveryUSD - Inp_RecoveryStepUSD;
         if(m_port.totalProfit > stepNeeded) {
            // Todavia no ha caido lo suficiente para el siguiente escalon
            return;
         }
      }
   } else {
      // Modo ATR clasico (V7.5 original)
      if(m_losingPosOpenPrice>0 && m_losingPosType>=0) {
         double dist=(m_losingPosType==POSITION_TYPE_SELL)
            ? (tk.bid-m_losingPosOpenPrice) : (m_losingPosOpenPrice-tk.ask);
         if(dist < atr*Inp_RecoveryMinDistATR) {
            Print("[AQ V7.7] REC: esperando dist | actual=",NormalizeDouble(dist,_Digits),
                  " / min=",NormalizeDouble(atr*Inp_RecoveryMinDistATR,_Digits));
            return;
         }
      }
   }

   //--------------------------------------------------------------
   // V7.6 FIX: Seleccion de direccion consciente de tendencia
   //--------------------------------------------------------------
   ENUM_ORDER_TYPE recType;
   double adxLv = m_inSession ? Inp_ADXTrendLevel : Inp_ADXTrendLevelOff;
   bool bearTrend = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.adx > adxLv);
   bool bullTrend = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.adx > adxLv);

   if(m_port.buyProfit < m_port.sellProfit && bearTrend) {
      // BUYs perdiendo + BEAR confirmado -> SELL (sigue el mercado)
      recType=ORDER_TYPE_SELL;
      m_recoveryTrendHedge=true;
   } else if(m_port.sellProfit < m_port.buyProfit && bullTrend) {
      // SELLs perdiendo + BULL confirmado -> BUY (sigue el mercado)
      recType=ORDER_TYPE_BUY;
      m_recoveryTrendHedge=true;
   } else {
      // Sin tendencia clara: promediado clasico
      m_recoveryTrendHedge=false;
      if(m_port.buyProfit < m_port.sellProfit) {
         recType=ORDER_TYPE_BUY;
         if(!Inp_UseUSDMode && m_lastCTBuyPrice>0 && MathAbs(tk.ask-m_lastCTBuyPrice)<atr*0.3) return;
      } else {
         recType=ORDER_TYPE_SELL;
         if(!Inp_UseUSDMode && m_lastCTSellPrice>0 && MathAbs(tk.bid-m_lastCTSellPrice)<atr*0.3) return;
      }
   }

   double recLot=CalcRecoveryLot();
   if(!MarginOK(recLot,recType)) {
      recLot=NormLot(recLot*0.5);
      if(!MarginOK(recLot,recType)) {
         recLot=NormLot(Inp_LotBase);
         if(!MarginOK(recLot,recType)) {
            Print("[AQ V7.7] RECOVERY: Sin margen -> Activando LBC");
            ActivateLBC(); return;
         }
      }
   }

   string recMode = m_recoveryTrendHedge ? "HEDGE-TENDENCIA" : "PROMEDIADO";
   string recComm = "REC_"+(recType==ORDER_TYPE_BUY?"B":"S")+"_"+IntegerToString(m_recoveryOrders+1);
   m_isProcessing=true;
   ulong ticket=OpenOrder(recType,recLot,recComm,true);
   m_isProcessing=false;

   if(ticket>0) {
      int idx=FreeRec();
      if(idx>=0) {
         int    pt=(recType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
         double op=(recType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
         InitRec(idx,ticket,pt,op,recLot,recComm,false,false,true,false);
      }
      if(recType==ORDER_TYPE_BUY) m_lastCTBuyPrice=tk.ask; else m_lastCTSellPrice=tk.bid;
      m_lastRecoveryUSD = m_port.totalProfit; // anclar para el siguiente escalon
      m_recoveryOrders++;
      m_lastRecoveryTime=TimeCurrent();
      Print("[AQ V7.7] REC ABIERTO #",ticket," [",recMode,"] ",
            (recType==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=",NormalizeDouble(recLot,2),
            " Orden=",m_recoveryOrders,"/",maxRec,
            " PnL=$",NormalizeDouble(m_port.totalProfit,2));
   }
}

//=================================================================
//  LBC ENGINE (PRESERVADO INTOCABLE)
//=================================================================
void ActivateLBC()
{
   if(m_lbc.active) return;
   m_lbc.active=true; m_lbc.activatedTime=TimeCurrent();
   m_lbc.buyCount=0; m_lbc.sellCount=0;
   m_lbc.lastBuyPrice=0; m_lbc.lastSellPrice=0;
   m_lbc.harvestedTotal=0; m_lbc.harvestCount=0;
   double freeMarg=AccountInfoDouble(ACCOUNT_MARGIN_FREE), mp=CalcMarginFor001();
   m_lbc.maxOrdersCalc=(int)MathFloor((freeMarg*Inp_LBCMarginPct)/(2.0*MathMax(mp,0.01)));
   m_lbc.maxOrdersCalc=MathMax(1,MathMin(m_lbc.maxOrdersCalc,Inp_LBCMaxPairs));
   Print("[AQ V7.7] LBC ACTIVADO | MaxPares=",m_lbc.maxOrdersCalc);
}
void DeactivateLBC()
{
   if(!m_lbc.active) return;
   Print("[AQ V7.7] LBC DESACTIVADO | Cosechado: $",NormalizeDouble(m_lbc.harvestedTotal,2));
   ZeroMemory(m_lbc);
}
void RunLBCEngine()
{
   if(!m_lbc.active) return;
   if(m_port.totalPos==0) { DeactivateLBC(); return; }
   if(m_isProcessing) return;
   if(m_port.totalProfit>=Inp_BlockTPTarget) return;
   if(m_port.totalProfit>=Inp_RecoveryTriggerUSD*0.5) { DeactivateLBC(); return; }
   MqlTick tk; if(!GetTick(tk)) return;
   double atr=m_mkt.atr; if(atr<=0) return;
   double harvestMin=MathMax(DistToUSD(atr*Inp_LBCHarvestATR,0.01),0.02);
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT),"LBC_")<0) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pf>=harvestMin) ClosePos(t,"LBC_Harvest");
   }
   if(TimeCurrent()-m_lbc.lastOrderTime<Inp_LBCIntervalSec) return;
   if(!SpreadOK()) return;
   if(MathMin(m_lbc.buyCount,m_lbc.sellCount)>=m_lbc.maxOrdersCalc) return;
   double gs=atr*Inp_LBCGridATR*(m_inSession?1.2:1.0), lot=NormLot(Inp_LotBase);
   bool nb=false, ns=false;
   if(m_lbc.buyCount==0&&m_lbc.sellCount==0) { nb=true; ns=true; }
   else {
      if(m_lbc.buyCount<=m_lbc.sellCount&&(m_lbc.lastBuyPrice<=0||MathAbs(tk.ask-m_lbc.lastBuyPrice)>=gs)) nb=true;
      if(m_lbc.sellCount<=m_lbc.buyCount&&(m_lbc.lastSellPrice<=0||MathAbs(tk.bid-m_lbc.lastSellPrice)>=gs)) ns=true;
   }
   if(nb&&MarginOK(lot,ORDER_TYPE_BUY)) {
      string c="LBC_B"+IntegerToString(m_lbc.buyCount+1); m_isProcessing=true;
      ulong tB=OpenOrder(ORDER_TYPE_BUY,lot,c,true); m_isProcessing=false;
      if(tB>0) { int idx=FreeRec(); if(idx>=0) InitRec(idx,tB,POSITION_TYPE_BUY,tk.ask,lot,c,false,false,false,true); m_lbc.buyCount++; m_lbc.lastBuyPrice=tk.ask; m_lbc.lastOrderTime=TimeCurrent(); }
   }
   if(ns&&MarginOK(lot,ORDER_TYPE_SELL)) {
      string c="LBC_S"+IntegerToString(m_lbc.sellCount+1); m_isProcessing=true;
      ulong tS=OpenOrder(ORDER_TYPE_SELL,lot,c,true); m_isProcessing=false;
      if(tS>0) { int idx=FreeRec(); if(idx>=0) InitRec(idx,tS,POSITION_TYPE_SELL,tk.bid,lot,c,false,false,false,true); m_lbc.sellCount++; m_lbc.lastSellPrice=tk.bid; m_lbc.lastOrderTime=TimeCurrent(); }
   }
}

//=================================================================
//  BASKET, HARVEST, CYCLE, EQUITY (PRESERVADOS)
//=================================================================
void RunBasketTP()
{
   if(!Inp_UseBasketTP||TimeCurrent()-m_lastBasketCheck<Inp_BasketCheckSec) return;
   m_lastBasketCheck=TimeCurrent();
   if(m_port.totalPos<2||m_port.totalProfit<Inp_BlockTPTarget) return;
   double target=MathMax(Inp_BlockTPTarget,(m_cycleWinsCount>0?m_cycleWinsSum/m_cycleWinsCount:Inp_BasketTPFactor)*Inp_BasketTPRatio);
   if(m_port.totalProfit>=target) CloseBlockIfPositive("BasketTP");
}
void CheckCycleMaxLoss()
{
   if(!Inp_UseCycleMaxLoss||m_port.totalPos==0) return;
   if(m_port.totalProfit<=Inp_CycleMaxLossUSD && !m_recoveryActive)
      { m_recoveryActive=true; m_recoveryOrders=0; m_lastRecoveryUSD=m_port.totalProfit; }
}
void RunHarvest()
{
   if(!Inp_HarvestContinuous||m_isProcessing) return;
   if(TimeCurrent()-m_lastHarvestTime<Inp_HarvestIntervalSec) return;
   m_lastHarvestTime=TimeCurrent();
   if(m_port.totalProfit<Inp_BlockTPTarget) return;
   double atr=m_mkt.atr,tv=GetTickVal(),ts=GetTickSize(),sm=m_inSession?1.0:1.5;
   double hMin=Inp_HarvestMinUSD*sm;
   if(atr>0&&tv>0&&ts>0) hMin=MathMax(hMin,NormalizeDouble((atr/ts)*tv*SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)*Inp_HarvestATRMult*sm,2));
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      int idx=FindRec(t); double kpf=(idx>=0&&m_rec[idx].kInit)?m_rec[idx].kX:pf;
      if(m_port.negativeSum>pf*1.5&&pf>0) continue;
      if((pf>=hMin*3.0)||(kpf>=hMin&&idx>=0&&m_rec[idx].kInit&&m_rec[idx].kK<=0.30))
         ClosePos(t,"Harvest");
   }
}
bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   if(m_port.totalProfit<=Inp_EmergencyLossUSD&&!m_emergencyMode)
      { m_emergencyMode=true; m_isPaused=true; return true; }
   if(m_port.currentDD>=Inp_MaxDrawdownPct) m_isPaused=true;
   else if(m_isPaused&&!m_emergencyMode&&!m_dailyLimitHit&&m_port.currentDD<Inp_MaxDrawdownPct*0.5)
      m_isPaused=false;
   return false;
}

//=================================================================
//  CT ENGINE - V7.7: USD mode para distancias
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType, double &ctLot, int &ctLevel)
{
   if(m_port.totalPos==0||m_port.totalPos>=Inp_MaxPositionsTotal) return false;
   if(m_port.totalProfit>=0&&m_port.negativeSum==0) return false;
   if(m_recoveryActive||m_lbc.active||m_mkt.atr<=0) return false;
   int bc=m_port.buyCount, sc=m_port.sellCount;
   bool bl=(m_port.buyProfit<-0.05&&bc>0), sl=(m_port.sellProfit<-0.05&&sc>0);
   bool ob=false, os=false;
   if(bl&&!sl)      { if(sc>=Inp_CTMaxSameDir) return false; os=true; }
   else if(sl&&!bl) { if(bc>=Inp_CTMaxSameDir) return false; ob=true; }
   else if(bl&&sl) {
      if(m_mkt.htfTrend==1&&bc<Inp_CTMaxSameDir) ob=true;
      else if(m_mkt.htfTrend==-1&&sc<Inp_CTMaxSameDir) os=true;
      else if(m_port.buyProfit<m_port.sellProfit&&sc<Inp_CTMaxSameDir) os=true;
      else if(bc<Inp_CTMaxSameDir) ob=true; else return false;
   } else return false;

   ENUM_ORDER_TYPE testType=ob?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!ADXAllowsEntry(testType)) return false;

   MqlTick t; if(!GetTick(t)) return false;

   if(Inp_UseUSDMode) {
      // Modo USD: CT abre cuando el lado perdedor supera Inp_CTTriggerUSD
      // + distancia minima para evitar clustering en el mismo precio
      double losingSide = ob ? m_port.sellProfit : m_port.buyProfit;
      if(losingSide > -Inp_CTTriggerUSD) return false;
      // Distancia minima = mitad del CTTrigger convertida a precio
      double minDist = USDToDist(Inp_CTTriggerUSD*0.5, NormLot(Inp_LotBase));
      if(ob  && m_lastCTBuyPrice >0 && MathAbs(t.ask-m_lastCTBuyPrice) <minDist) return false;
      if(!ob && m_lastCTSellPrice>0 && MathAbs(t.bid-m_lastCTSellPrice)<minDist) return false;
   } else {
      // Modo ATR clasico
      double ctDist=(Inp_CTMode==CT_ATR_DISTANCE)?m_mkt.atr*Inp_CTDistanceATR:Inp_CTFixedPoints*_Point;
      if(ctDist>0) {
         if(ob  && m_lastCTBuyPrice >0 && MathAbs(t.ask-m_lastCTBuyPrice) <ctDist) return false;
         if(!ob && m_lastCTSellPrice>0 && MathAbs(t.bid-m_lastCTSellPrice)<ctDist) return false;
      }
   }

   ctLevel=ob?bc:sc; ctLot=CalcLot(ctLevel); ctType=ob?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine()
{
   if(m_isProcessing||m_isPaused||m_emergencyMode||m_cycleInPause) return;
   if(TimeCurrent()-m_lastCTTime<Inp_CTIntervalSec) return;
   m_lastCTTime=TimeCurrent();
   MqlTick ts; if(!GetTick(ts)) return;
   if((ts.ask-ts.bid)/_Point>(m_inSession?Inp_MaxSpread:Inp_CTMaxSpreadOff)) return;

   if(m_port.totalPos==0) {
      if(!m_sensors.allOK) return;
      int cd=m_inSession?Inp_PrimaryCooldownSec:Inp_PrimaryCooldownOff;
      if(TimeCurrent()-m_lastPrimaryTime<cd) return;
      ENUM_ORDER_TYPE initType;
      if(m_mkt.isBullish) initType=ORDER_TYPE_BUY;
      else if(m_mkt.isBearish) initType=ORDER_TYPE_SELL;
      else if(m_mkt.emaFast>m_mkt.emaSlow) initType=ORDER_TYPE_BUY;
      else initType=ORDER_TYPE_SELL;
      if(m_lastPrimaryLost&&m_lastPrimaryDir!=0) {
         ENUM_ORDER_TYPE alt=(m_lastPrimaryDir==1)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
         if(initType!=alt) { initType=alt; m_lastPrimaryLost=false; }
      }
      if(!ADXAllowsEntry(initType)||!TrendFilter200OK(initType)) return;
      if(!m_inSession&&!((m_mkt.isBullish&&initType==ORDER_TYPE_BUY)||(m_mkt.isBearish&&initType==ORDER_TYPE_SELL))) return;
      double lot=CalcLot(0); m_isProcessing=true;
      ulong ticket=OpenOrder(initType,lot,"Primary_Entry");
      if(ticket>0) {
         int idx=FreeRec();
         if(idx>=0) InitRec(idx,ticket,(initType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(initType==ORDER_TYPE_BUY)?ts.ask:ts.bid,lot,"Primary_Entry",true,false,false,false);
         m_lastPrimaryDir=(initType==ORDER_TYPE_BUY)?1:-1; m_lastPrimaryTime=TimeCurrent();
         if(initType==ORDER_TYPE_BUY) m_lastCTBuyPrice=ts.ask; else m_lastCTSellPrice=ts.bid;
         m_recoveryActive=false; m_recoveryOrders=0;
         m_recoveryTrendHedge=false; m_lastRecoveryUSD=0;
         m_panicHedgeActive=false;
         DeactivateLBC();
      }
      m_isProcessing=false; return;
   }

   ENUM_ORDER_TYPE ctType; double ctLot; int ctLevel;
   if(!ShouldOpenCT(ctType,ctLot,ctLevel)||!MarginOK(ctLot,ctType)) return;
   string ctComm="CT_"+(ctType==ORDER_TYPE_BUY?"B":"S")+"_L"+IntegerToString(ctLevel+1);
   m_isProcessing=true;
   ulong ticket=OpenOrder(ctType,ctLot,ctComm);
   m_isProcessing=false;
   if(ticket>0) {
      int idx=FreeRec();
      if(idx>=0) InitRec(idx,ticket,(ctType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL,(ctType==ORDER_TYPE_BUY)?ts.ask:ts.bid,ctLot,ctComm,false,true,false,false);
      if(ctType==ORDER_TYPE_BUY) m_lastCTBuyPrice=ts.ask; else m_lastCTSellPrice=ts.bid;
   }
}

//=================================================================
//  DASHBOARD - V7.7 USD CONTROL
//=================================================================
void AQLbl(string n,string txt,int x,int y,color c,int fs=9,bool bold=false) {
   if(ObjectFind(0,n)<0) { ObjectCreate(0,n,OBJ_LABEL,0,0,0); ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString(0,n,OBJPROP_FONT,bold?"Consolas Bold":"Consolas");
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
}
void AQBtn(string n,string txt,int x,int y,int w,int h,color bg,color fg=clrWhite) {
   if(ObjectFind(0,n)<0) { ObjectCreate(0,n,OBJ_BUTTON,0,0,0); ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8); ObjectSetString(0,n,OBJPROP_FONT,"Consolas"); }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x); ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);     ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);      ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,fg);
}
void AQPanel(string n,int x,int y,int w,int h) {
   if(ObjectFind(0,n)<0) { ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0); ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER); ObjectSetInteger(0,n,OBJPROP_BACK,false); ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false); ObjectSetInteger(0,n,OBJPROP_HIDDEN,true); }
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);        ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'8,8,12'); ObjectSetInteger(0,n,OBJPROP_COLOR,C'70,70,70');
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT); ObjectSetInteger(0,n,OBJPROP_WIDTH,1);
}
void DeleteDash() {
   string objs[]={"AQ77_BG","AQ77_HDR","AQ77_SEP1","AQ77_STATE","AQ77_REASON",
                  "AQ77_SEP2","AQ77_SENS","AQ77_SEP3","AQ77_USD",
                  "AQ77_SEP4","AQ77_ACC","AQ77_PNL","AQ77_POS","AQ77_VOL",
                  "AQ77_REC","AQ77_PANIC","AQ77_SEP5","AQ77_HIST",
                  "AQ77_SEP6","AQ77_GMT","AQ77_B1","AQ77_B2"};
   for(int i=0;i<ArraySize(objs);i++) ObjectDelete(0,objs[i]);
   // Limpiar objetos V7.5 que puedan quedar
   string old[]={"AQ75_BG","AQ75_HDR","AQ75_SEP1","AQ75_STATE","AQ75_B1","AQ75_B2"};
   for(int i=0;i<ArraySize(old);i++) ObjectDelete(0,old[i]);
}
void UpdateDash() {
   if(!Inp_ShowDashboard||TimeCurrent()-m_lastDashTime<1) return;
   m_lastDashTime=TimeCurrent();
   color cG=C'0,220,80',cR=C'220,50,50',cO=C'220,150,30',cY=C'200,200,50',
         cC=C'50,190,220',cP=C'160,80,220',cGr=C'120,120,130',cBo=C'70,70,70';
   int x=Inp_DashX,y=Inp_DashY,lh=16,pad=8,w=560,h=30*lh+60;
   AQPanel("AQ77_BG",x-pad,y-pad,w,h);

   AQLbl("AQ77_HDR","[ "+VERSION_STR+" ] "+_Symbol+" | USD CONTROL + ANTI-CATASTROPHE",x,y,cG,10,true); y+=lh+2;
   AQLbl("AQ77_SEP1","────────────────────────────────────────────────────────────────",x,y,cBo,8); y+=lh-4;

   // Estado principal
   string st; color sc;
   if(m_panicHedgeActive)    { st="[ !!! PANIC HEDGE ACTIVO - PERDIDA CONGELADA !!! ]"; sc=cR; }
   else if(m_emergencyMode)  { st="[ EMERGENCIA - RECOVERY OPERA SIN RESTRICCION ]";    sc=cR; }
   else if(m_recoveryActive) { st="[ RECOVERY ACTIVO - "+(m_recoveryTrendHedge?"HEDGE TENDENCIA":"PROMEDIADO")+" ]"; sc=cY; }
   else if(!m_sensors.allOK) { st="[ ESPERANDO CONDICIONES ]";                           sc=cGr; }
   else                      { st="[ BUSCANDO ENTRADA PRIMARIA ]";                        sc=cG; }
   AQLbl("AQ77_STATE",st,x,y,sc,10,true); y+=lh+2;
   AQLbl("AQ77_REASON",(!m_sensors.allOK&&m_port.totalPos==0)?("  Bloqueo: "+m_sensors.blockReason):"",x,y,cGr,8); y+=lh-2;

   // Sensores compactos
   AQLbl("AQ77_SEP2","── SENSORES ────────────────────────────────────────────────────",x,y,C'50,50,80',8); y+=lh-3;
   int curSpr=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   AQLbl("AQ77_SENS",
      "TIME:"+(m_sensors.timeOK?"PASS":"WAIT")+
      "  SPR:"+(m_sensors.spreadOK?"PASS("+IntegerToString(curSpr)+")":"ALTO("+IntegerToString(curSpr)+")")+
      "  TEND:"+(m_sensors.trendBull?"BULL":"BEAR")+
      (m_mkt.ema200>0?"("+DoubleToString(m_mkt.ema200,1)+")":"")+
      "  VOLAT:"+(m_sensors.volatOK?"OK":"HIGH")+
      "  MARG:"+(m_sensors.marginOK?"OK":"BAJO"),
      x,y,cGr,9); y+=lh;

   // Umbrales USD
   AQLbl("AQ77_SEP3","── UMBRALES USD ────────────────────────────────────────────────",x,y,C'50,50,80',8); y+=lh-3;
   AQLbl("AQ77_USD",
      "CT: -$"+DoubleToString(Inp_CTTriggerUSD,2)+
      "  REC: $"+DoubleToString(Inp_RecoveryTriggerUSD,2)+
      "  REC Step: -$"+DoubleToString(Inp_RecoveryStepUSD,2)+
      "  PANIC: $"+DoubleToString(Inp_PanicHedgeUSD,2)+
      "  TP: $"+DoubleToString(Inp_BlockTPTarget,2)+
      "  Modo: "+(Inp_UseUSDMode?"USD PURO":"ATR"),
      x,y,cC,9); y+=lh;

   // Cuenta
   AQLbl("AQ77_SEP4","── CUENTA & BLOQUE ─────────────────────────────────────────────",x,y,C'50,50,80',8); y+=lh-3;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE),eq=AccountInfoDouble(ACCOUNT_EQUITY),fr=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double ddPct=m_port.currentDD*100.0;
   AQLbl("AQ77_ACC","Saldo: $"+DoubleToString(bal,2)+"  Equity: $"+DoubleToString(eq,2)+"  Libre: $"+DoubleToString(fr,2)+"  DD: "+DoubleToString(ddPct,1)+"%",x,y,(ddPct>10.0?cR:ddPct>5.0?cO:cC),9); y+=lh;

   double pnl=m_port.totalProfit;
   // Barra de progreso USD (texto)
   double pctToTP = (Inp_BlockTPTarget>0) ? (pnl/Inp_BlockTPTarget)*100.0 : 0;
   double pctToPanic = (Inp_PanicHedgeUSD<0) ? (pnl/Inp_PanicHedgeUSD)*100.0 : 0;
   AQLbl("AQ77_PNL","PnL: $"+DoubleToString(pnl,2)+
      "  TP: $"+DoubleToString(Inp_BlockTPTarget,2)+" ["+DoubleToString(MathMin(MathMax(pctToTP,0),100),0)+"%]"+
      "  PANIC: $"+DoubleToString(Inp_PanicHedgeUSD,2)+" ["+DoubleToString(MathMin(pctToPanic,100),0)+"%]",
      x,y,(pnl>=0)?cG:cR,9); y+=lh-1;

   double netV=m_port.buyVolume-m_port.sellVolume;
   AQLbl("AQ77_POS","Pos: "+IntegerToString(m_port.totalPos)+
      "  BUY: "+IntegerToString(m_port.buyCount)+" ($"+DoubleToString(m_port.buyProfit,2)+") vol="+DoubleToString(m_port.buyVolume,2)+
      "  SELL: "+IntegerToString(m_port.sellCount)+" ($"+DoubleToString(m_port.sellProfit,2)+") vol="+DoubleToString(m_port.sellVolume,2),
      x,y,cC,9); y+=lh-1;
   AQLbl("AQ77_VOL","Volumen neto: "+DoubleToString(netV,2)+(netV>0?" (LARGO)":(netV<0?" (CORTO)":" (NEUTRO-HEDGEADO)"))+"  CT:"+IntegerToString(m_port.ctCount)+" REC:"+IntegerToString(m_port.recoveryCount)+" LBC:"+IntegerToString(m_port.lbcCount),x,y,(MathAbs(netV)>0.05?cO:cG),9); y+=lh-1;

   int maxRec=m_recoveryTrendHedge?Inp_RecoveryMaxOrdersTrend:Inp_RecoveryMaxOrders;
   string recStr=m_recoveryActive?("RECOVERY: "+IntegerToString(m_recoveryOrders)+"/"+IntegerToString(maxRec)+
      (m_recoveryTrendHedge?" [HEDGE-TEND]":" [PROMEDIADO]")+
      " Prox. escalon: $"+DoubleToString(m_lastRecoveryUSD-Inp_RecoveryStepUSD,2)):"RECOVERY: en espera";
   AQLbl("AQ77_REC",recStr,x,y,m_recoveryActive?cY:cGr,9); y+=lh-1;
   AQLbl("AQ77_PANIC",m_panicHedgeActive?"!!! PANIC HEDGE ACTIVO - perdida congelada en ~$"+DoubleToString(Inp_PanicHedgeUSD,2)+" !!!":"PANIC HEDGE: en espera ($"+DoubleToString(Inp_PanicHedgeUSD,2)+")",x,y,m_panicHedgeActive?cR:cGr,9); y+=lh;

   // Historial
   AQLbl("AQ77_SEP5","── HISTORIAL ───────────────────────────────────────────────────",x,y,C'50,50,80',8); y+=lh-3;
   int tot=m_totalWins+m_totalLosses; double wr=(tot>0)?(double)m_totalWins/tot*100.0:0;
   AQLbl("AQ77_HIST","Win: "+DoubleToString(wr,1)+"% ("+IntegerToString(m_totalWins)+"/"+IntegerToString(tot)+")  Expect: $"+DoubleToString(CalcExpectancy(),3)+"  PnL cerrado: $"+DoubleToString(m_totalPnL,2)+"  Ticks: "+IntegerToString((int)m_tickCount),x,y,(CalcExpectancy()>=0?cG:cO),9); y+=lh;

   // GMT
   AQLbl("AQ77_SEP6","── GMT & ATR ───────────────────────────────────────────────────",x,y,C'50,50,80',8); y+=lh-3;
   MqlDateTime dtN; TimeToStruct(TimeCurrent(),dtN);
   int sm=m_sensors.brokerStartMin, em=m_sensors.brokerEndMin;
   AQLbl("AQ77_GMT","Broker: "+StringFormat("%02d:%02d",dtN.hour,dtN.min)+"  Ventana: "+StringFormat("%02d:%02d-%02d:%02d",sm/60,sm%60,em/60,em%60)+"  ATR: "+DoubleToString(m_mkt.atr,2)+"  EMA200: "+(m_mkt.ema200>0?DoubleToString(m_mkt.ema200,1):"cargando"),x,y,cGr,8); y+=lh+4;

   // Botones
   string pTxt=m_isPaused?">> REANUDAR TODO <<":(m_panicHedgeActive?">> REANUDAR (DESHEDGE MANUAL) <<":"|| PAUSAR PRIMARIAS");
   AQBtn("AQ77_B1",pTxt,x,y,230,22,m_isPaused?C'180,130,0':C'0,90,40');
   AQBtn("AQ77_B2","CERRAR TODAS (MANUAL)",x+240,y,190,22,C'150,20,20');
   ChartRedraw(0);
}

//=================================================================
//  OnInit
//=================================================================
int OnInit()
{
   Print("=============================================================");
   Print("  ",VERSION_STR," - USD CONTROL + ANTI-CATASTROPHE ENGINE");
   Print("  Modo USD: ",(Inp_UseUSDMode?"ACTIVO":"INACTIVO"),
         " | CT trigger: $",Inp_CTTriggerUSD,
         " | Rec step: $",Inp_RecoveryStepUSD);
   Print("  Recovery trigger: $",Inp_RecoveryTriggerUSD,
         " | Panic hedge: $",Inp_PanicHedgeUSD,
         " | TP: $",Inp_BlockTPTarget);
   Print("  Trend-Aware Recovery: ACTIVO (BEAR->SELL, BULL->BUY)");
   Print("  Panic Hedge: ",(Inp_UsePanicHedge?"ACTIVO":"INACTIVO"));
   Print("  RescueAllTrades: ",(Inp_RescueAllTrades?"ACTIVO":"INACTIVO"));
   Print("=============================================================");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);

   h_ATR     = iATR(_Symbol, PERIOD_M1, Inp_ATRPeriod);
   h_EMAFast = iMA(_Symbol,  PERIOD_M1, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMASlow = iMA(_Symbol,  PERIOD_M1, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol, PERIOD_M1, Inp_RSIPeriod, PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol,PERIOD_M1, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);
   if(h_ATR==INVALID_HANDLE||h_EMAFast==INVALID_HANDLE||h_EMASlow==INVALID_HANDLE||
      h_RSI==INVALID_HANDLE||h_MACD==INVALID_HANDLE) {
      Print("[AQ V7.7] ERROR: indicadores base no iniciados"); return INIT_FAILED;
   }
   h_ADX        = iADX(_Symbol, PERIOD_M1, Inp_ADXPeriod);
   h_HTFEMAFast = iMA(_Symbol,  Inp_HTFTF, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_HTFEMASlow = iMA(_Symbol,  Inp_HTFTF, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA200     = iMA(_Symbol,  PERIOD_M1, Inp_EMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ATRSlow    = iATR(_Symbol, PERIOD_M1, Inp_ATRSlowPeriod);

   for(int i=0;i<MAX_RECORDS;i++) ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc); ZeroMemory(m_sensors); ZeroMemory(m_mkt);

   m_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance   = m_initialBalance;
   m_lastDailyReset = TimeCurrent();

   CalcBrokerTimeWindow();
   SyncPositions();
   UpdatePortfolio();

   if(m_port.lbcCount>0) {
      m_lbc.active=true; m_lbc.activatedTime=TimeCurrent(); m_lbc.maxOrdersCalc=Inp_LBCMaxPairs;
   }
   if(m_port.rescueCount>0)
      Print("[AQ V7.7] RESCATE: detectadas ",m_port.rescueCount," posiciones externas");
   if(m_port.recoveryCount>0) {
      m_recoveryActive=true; m_recoveryOrders=m_port.recoveryCount;
      m_lastRecoveryUSD=m_port.totalProfit;
   }

   if(Inp_ShowDashboard) { DeleteDash(); UpdateDash(); }
   Print("[AQ V7.7] LISTO | Saldo=$",m_initialBalance,
         " | MargPor0.01=$",NormalizeDouble(CalcMarginFor001(),2));
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[AQ V7.7] DETENIDO | PnL=$",NormalizeDouble(m_totalPnL,2),
         " | Win%:",NormalizeDouble((m_totalWins+m_totalLosses>0)?(double)m_totalWins/(m_totalWins+m_totalLosses)*100:0,1),
         " | LBC=$",NormalizeDouble(m_lbc.harvestedTotal,2));
   IndicatorRelease(h_ATR); IndicatorRelease(h_EMAFast); IndicatorRelease(h_EMASlow);
   IndicatorRelease(h_RSI); IndicatorRelease(h_MACD);
   if(h_ADX       !=INVALID_HANDLE) IndicatorRelease(h_ADX);
   if(h_HTFEMAFast!=INVALID_HANDLE) IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow!=INVALID_HANDLE) IndicatorRelease(h_HTFEMASlow);
   if(h_EMA200    !=INVALID_HANDLE) IndicatorRelease(h_EMA200);
   if(h_ATRSlow   !=INVALID_HANDLE) IndicatorRelease(h_ATRSlow);
   if(Inp_ShowDashboard) DeleteDash();
}

//=================================================================
//  OnTick - Flujo principal V7.7
//=================================================================
void OnTick()
{
   m_tickCount++;
   UpdateMarket();
   UpdateKalman();
   UpdatePortfolio();

   // PRIORIDAD 0 (ABSOLUTA): PANIC HEDGE - congela la perdida catastrofica
   RunPanicHedge();

   CheckEquityGuard();
   m_inSession = IsInMainSession();
   ResetDailyIfNeeded();
   bool dailyPaused = DailyLimitReached();
   UpdateSensors();

   // --- Pausa de ciclo ---
   if(m_cycleInPause) {
      if(TimeCurrent()-m_cycleResetTime>=Inp_CyclePauseSec) {
         m_cycleInPause=false; m_recoveryActive=false; m_recoveryOrders=0;
         m_recoveryTrendHedge=false; m_lastRecoveryUSD=0;
         DeactivateLBC();
      } else {
         UpdatePortfolio();
         if(m_port.totalPos>0&&m_port.totalProfit>=Inp_BlockTPTarget) CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard) UpdateDash();
         return;
      }
   }

   // --- Modo emergencia (fix V7.3F: recovery sigue activo) ---
   if(m_emergencyMode) {
      static datetime emgTime=0;
      UpdatePortfolio();
      if(m_port.totalPos>0&&m_port.totalProfit>=Inp_BlockTPTarget) {
         CloseBlockIfPositive("Emergency_TP");
         m_emergencyMode=false; emgTime=0;
      }
      if(m_port.totalPos==0&&emgTime==0) emgTime=TimeCurrent();
      if(emgTime>0&&TimeCurrent()-emgTime>=Inp_EmergencyCooldown) { m_emergencyMode=false; emgTime=0; }
      RunRecoveryEngine(); // Recovery sigue en emergencia
      RunLBCEngine();
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   if(TimeCurrent()-m_lastCleanupTime>5) { CleanupRecs(); SyncPositions(); m_lastCleanupTime=TimeCurrent(); }

   // PRIORIDAD 1: Cierre del bloque
   if(m_port.totalPos>0&&m_port.totalProfit>=Inp_BlockTPTarget) {
      CloseBlockIfPositive("BlockTP");
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // PRIORIDAD 2: Recovery matematico
   RunRecoveryEngine();

   // PRIORIDAD 3: LBC
   RunLBCEngine();

   // PRIORIDAD 4: Basket TP
   RunBasketTP();

   // PRIORIDAD 5: Cycle max loss
   CheckCycleMaxLoss();

   // PRIORIDAD 6: Harvest
   RunHarvest();

   // PRIORIDAD 7: CT Engine (primarias solo si no pausado)
   if(!m_isPaused&&!m_recoveryActive&&!m_lbc.active&&!dailyPaused)
      RunCTEngine();

   if(Inp_ShowDashboard) UpdateDash();
}

//=================================================================
//  OnChartEvent
//=================================================================
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{
   if(id==CHARTEVENT_OBJECT_CLICK) {
      if(sp=="AQ77_B1") {
         m_isPaused=!m_isPaused;
         if(!m_isPaused) {
            m_emergencyMode=false; m_dailyLimitHit=false;
            m_recoveryActive=false; m_recoveryOrders=0;
            m_recoveryTrendHedge=false; m_lastRecoveryUSD=0;
            m_panicHedgeActive=false;
            DeactivateLBC();
            Print("[AQ V7.7] SISTEMA REANUDADO");
         } else {
            Print("[AQ V7.7] SISTEMA PAUSADO (recovery/LBC siguen si hay posiciones)");
         }
      }
      if(sp=="AQ77_B2") {
         Print("[AQ V7.7] CIERRE MANUAL...");
         int closed=0;
         for(int i=PositionsTotal()-1;i>=0;i--) {
            ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC)==Inp_Magic && ClosePos(t,"Manual")) closed++;
         }
         if(Inp_RescueAllTrades) {
            for(int i=PositionsTotal()-1;i>=0;i--) {
               ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
               if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
               if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic && CloseRescuePos(t,"Manual_Rescue")) closed++;
            }
         }
         m_lastCTBuyPrice=m_lastCTSellPrice=0; m_consecutiveLosses=0; m_lotMultiplier=1.0;
         m_cycleInPause=false; m_recoveryActive=false; m_recoveryOrders=0;
         m_recoveryTrendHedge=false; m_lastRecoveryUSD=0; m_lastPrimaryDir=0;
         m_lastPrimaryLost=false; m_panicHedgeActive=false; m_emergencyMode=false;
         DeactivateLBC();
         Print("[AQ V7.7] CIERRE MANUAL: ",closed," posiciones cerradas");
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+