//+------------------------------------------------------------------+
//|   APEXQUANT - V8.0.0-FSM-ASYMMETRIC-BTC-OPT                      |
//|   "FSM CENTRALIZED DIRECTIONAL RECOVERY ENGINE"                  |
//|   OPTIMIZADO PARA HFT / PEPPERSTONE RAZOR / MICRO-ACCOUNT        |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V8.0.0-BTC | FSM Anti-Symmetric Engine"
#property version   "8.00"
#property strict
#property description "BTCUSD | V8.0.0-FSM | FSM Centralizado | MaxDD 35% | Async Polling + Grid Expansion"

#define VERSION_STR   "APEXQUANT_V8.0.0-FSM-BTC-OPT"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   80

//=================================================================
//  ENUMERACIONES DE ESTADO Y CONFIGURACION
//=================================================================
enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

enum ENUM_SESSION_STATE {
   SESSION_ASIAN   = 0,
   SESSION_LONDON  = 1,
   SESSION_OVERLAP = 2,
   SESSION_NY      = 3,
   SESSION_OFF     = 4
};

enum ENUM_VOL_REGIME {
   VOL_LOW    = 0,
   VOL_NORMAL = 1,
   VOL_HIGH   = 2
};

// [NUEVO] Definición de la Máquina de Estados Finitos (FSM)
enum ENUM_EA_STATE {
   STATE_INIT            = 0, // Inicialización
   STATE_IDLE            = 1, // Esperando oportunidad, sin posiciones
   STATE_PRIMARY_TRADING = 2, // Operación principal activa, gestionando bloques
   STATE_BSE_RECOVERY    = 3, // Recuperación agresiva activa
   STATE_LBC_CONTINGENCY = 4, // Contingencia de margen bajo activa
   STATE_EMERGENCY       = 5, // Límite de Drawdown alcanzado, pausado
   STATE_CYCLE_PAUSE     = 6  // Pausa tras cierre de ciclo
};

//=================================================================
//  PARAMETROS
//=================================================================
input group "=== [V7.9] BREATHING ROOM ==="
input int    Inp_PrimaryMinHoldSec   = 120;
input double Inp_StageEmergMult      = 2.0;

input group "=== [V7.9] ASYMMETRIC HEDGE ==="
input double Inp_HedgeRatio          = 0.50;
input bool   Inp_UseDirectionalStage = true;
input double Inp_ReinforceLotMult    = 2.0;

input group "=== [V7.9] DETANGLE ENGINE ==="
input int    Inp_DetangleSec         = 180;
input double Inp_DetangleNetThresh   = 0.005;
input double Inp_DetangleMinLoss     = -3.00;

input group "=== [V7.8] DYNAMIC THRESHOLD ENGINE ==="
input double Inp_DynStage1Mult       = 1.20;
input double Inp_DynStage3Mult       = 2.50;
input double Inp_DynTPMult           = 0.80;
input double Inp_DynRecovMult        = 0.60;
input double Inp_DynMaxStage1USD     = 10.00;
input double Inp_DynMaxStage3USD     = 20.00;
input double Inp_DynMaxTPUSD         = 5.00;

input group "=== [V7.8] SESSION FACTORS (BTCUSD) ==="
input double Inp_SessFactorAsian     = 0.65;
input double Inp_SessFactorLondon    = 1.00;
input double Inp_SessFactorOverlap   = 1.25;
input double Inp_SessFactorNY        = 1.10;
input double Inp_SessFactorOff       = 0.55;

input group "=== [V7.8] STAGE2 DELAY POR SESION ==="
input int    Inp_Stage2DelayAsian    = 20;
input int    Inp_Stage2DelayLondon   = 6;
input int    Inp_Stage2DelayOverlap  = 3;
input int    Inp_Stage2DelayNY       = 5;

input group "=== [V7.8] RECOVERY DISTANCE ADAPTATIVO ==="
input double Inp_RecovDistLow        = 0.30;
input double Inp_RecovDistNormal     = 0.50;
input double Inp_RecovDistHigh       = 0.85;

input group "=== [V7.7] TEMA + KALMAN TREND ENGINE ==="
input bool   Inp_UseTEMAKalman       = true;
input int    Inp_TEMAFastPeriod      = 21;
input int    Inp_TEMASlowPeriod      = 55;
input double Inp_KalmanQ             = 0.0001;
input double Inp_KalmanR             = 0.005;

input group "=== [V7.7] BLOCK STAGE ENGINE (FLOORS) ==="
input double Inp_Stage1Trigger       = -1.50;
input double Inp_Stage3Trigger       = -3.00;
input int    Inp_Stage2DelaySec      = 5;

input group "=== [V7.6C] VOLATILITY STORM FILTER ==="
input bool   Inp_UseStormFilter      = true;
input int    Inp_StormATRWindow      = 20;
input double Inp_StormATRMult        = 2.0;
input double Inp_StormSpreadMult     = 2.5;
input int    Inp_StormSpreadWindow   = 20;
input int    Inp_StormCooldownSec    = 30;

input group "=== [V7.6B] NET EXPOSURE HEDGE ==="
input bool   Inp_UseNetHedge         = true;
input double Inp_NetHedgeTrigger1USD = -5.0;
input double Inp_NetHedgeTrigger2USD = -8.0;
input double Inp_NetHedgeMult1       = 2.0;
input double Inp_NetHedgeMult2       = 3.5;
input int    Inp_NetHedgeIntervalSec = 5;

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
input double Inp_BlockTPTarget       = 1.00;
input double Inp_TP_ATR              = 2.5;
input double Inp_SL_ATR              = 1.2;
input double Inp_OffSessionTP_ATR    = 2.2;
input double Inp_OffSessionSL_ATR    = 1.0;

input group "=== RECOVERY ENGINE (fallback) ==="
input double Inp_RecoveryTriggerUSD  = -1.00;
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
input int    Inp_CTFixedPoints       = 1000;
input int    Inp_CTIntervalSec       = 10;
input int    Inp_CTMaxSameDir        = 3;
input int    Inp_PrimaryCooldownSec  = 10;
input int    Inp_PrimaryCooldownOff  = 20;
input double Inp_CTMaxSpreadPoints   = 2000;
input double Inp_CTMaxSpreadOff      = 3000;

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
input int    Inp_LossStreakMax       = 4;
input double Inp_LossStreakReduce    = 0.70;

input group "=== EQUITY GUARD ==="
input bool   Inp_UseEquityGuard      = true;
input double Inp_EmergencyLossUSD    = -15.0; 
input double Inp_MaxDrawdownPct      = 35.0; 
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
input int    Inp_MaxSpread           = 2500;
input bool   Inp_ShowDashboard       = false;
input int    Inp_DashX               = 12;
input int    Inp_DashY               = 28;

input group "=== [V7.5] RESCATE UNIVERSAL ==="
input bool   Inp_RescueAllTrades     = true;

input group "=== [V7.5] SENSOR HORARIO GMT ==="
input bool   Inp_UseTimeFilter       = false; 
input int    Inp_UserGMT             = -5;
input int    Inp_BrokerGMT           = 2;
input string Inp_StartTime           = "00:00"; 
input string Inp_EndTime             = "23:59"; 

input group "=== [V7.5] SENSOR TENDENCIA ==="
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
   double temaFast, temaSlow;
   double kalmanFast, kalmanSlow;
   int    trendConfirmed;
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

struct DynThresholds {
   double stage1Trigger;
   double stage3Trigger;
   double blockTP;
   double recovTrigger;
   double recovDistATR;
   int    stage2Delay;
   double netHedgeTrig1;
   double netHedgeTrig2;
   double sessionFactor;
   ENUM_SESSION_STATE session;
   ENUM_VOL_REGIME    volRegime;
   double atr2usd;
};

//=================================================================
//  HANDLES
//=================================================================
int h_ATR, h_EMAFast, h_EMASlow, h_RSI, h_MACD;
int h_ADX=INVALID_HANDLE, h_HTFEMAFast=INVALID_HANDLE, h_HTFEMASlow=INVALID_HANDLE;
int h_ATRSlow=INVALID_HANDLE, h_EMA200=INVALID_HANDLE;

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade      m_trade;
PosRecord   m_rec[MAX_RECORDS];
Portfolio   m_port;
MarketSnap  m_mkt;
LBCState    m_lbc;
SensorState m_sensors;
DynThresholds m_dyn;
ENUM_EA_STATE m_currentState = STATE_INIT; // [NUEVO] Variable Central FSM

double   m_initialBalance=0, m_bestEquity=0;
bool     m_isPaused=false, m_emergencyMode=false, m_dailyLimitHit=false, m_inSession=false;
bool     m_recoveryActive=false;
int      m_recoveryOrders=0;
bool     m_recoveryTrendHedge=false;

bool     m_netHedge1Applied=false, m_netHedge2Applied=false;
datetime m_lastNetHedgeTime=0;

bool     m_stormActive=false;
datetime m_stormDetectedTime=0;
double   m_stormLastATRRatio=0.0, m_stormLastSprRatio=0.0;

double   m_cycleWinsSum=0;
int      m_cycleWinsCount=0;
double   m_cycleLossSum=0;
bool     m_cycleInPause=false;
datetime m_cycleResetTime=0;

int      m_consecutiveLosses=0;
double   m_lotMultiplier=1.0;
double   m_dailyBalance=0;
datetime m_lastDailyReset=0;

int      m_lastPrimaryDir=0;
datetime m_lastPrimaryTime=0;
bool     m_lastPrimaryLost=false;

double   m_lastCTBuyPrice=0, m_lastCTSellPrice=0;
datetime m_lastCTTime=0, m_lastRecoveryTime=0, m_lastBasketCheck=0;
datetime m_lastHarvestTime=0, m_lastDashTime=0, m_lastCleanupTime=0;

double   m_totalPnL=0;
int      m_tradesOpened=0, m_tradesClosed=0;
double   m_bestClosed=0, m_worstClosed=0;
int      m_totalWins=0, m_totalLosses=0;
double   m_sumWins=0, m_sumLosses=0;

long     m_tickCount=0;
bool     m_isProcessing=false;

double   m_losingPosOpenPrice=0;
int      m_losingPosType=-1;

double   m_temaF_e1=0,m_temaF_e2=0,m_temaF_e3=0; bool m_temaF_init=false;
double   m_temaS_e1=0,m_temaS_e2=0,m_temaS_e3=0; bool m_temaS_init=false;
double   m_kalF_x=0,m_kalF_p=1.0; bool m_kalF_init=false;
double   m_kalS_x=0,m_kalS_p=1.0; bool m_kalS_init=false;

int              m_blockStage=0;
ENUM_ORDER_TYPE  m_primaryType=ORDER_TYPE_BUY;
datetime         m_stage2Time=0;
bool             m_stageFollowHedge=false;
double           m_stage1TriggerAtOpen=0.0;
double           m_stage3TriggerAtOpen=0.0;

datetime         m_detangleDetectTime=0;   
bool             m_detangleActive=false;   

datetime         m_primaryOpenTime=0;

//=================================================================
//  V7.8: DYNAMIC THRESHOLD ENGINE
//=================================================================
double ATR2USD_Lot(double atrMult, double lot)
{
   double tv=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0||m_mkt.atr<=0||lot<=0) return 0;
   return NormalizeDouble((m_mkt.atr*atrMult/ts)*tv*lot,4);
}
double ATR2USD(double atrMult=1.0) { return ATR2USD_Lot(atrMult,Inp_LotBase); }

ENUM_SESSION_STATE GetCurrentSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   int gmtH=(dt.hour-Inp_GMTOffset+24)%24;
   if(gmtH>=12&&gmtH<17) return SESSION_OVERLAP;
   if(gmtH>=7 &&gmtH<12) return SESSION_LONDON;
   if(gmtH>=17&&gmtH<22) return SESSION_NY;
   if(gmtH>=2 &&gmtH<7)  return SESSION_ASIAN;
   return SESSION_OFF; 
}

double GetSessionFactor(ENUM_SESSION_STATE s)
{
   switch(s){
      case SESSION_ASIAN:   return Inp_SessFactorAsian;
      case SESSION_LONDON:  return Inp_SessFactorLondon;
      case SESSION_OVERLAP: return Inp_SessFactorOverlap;
      case SESSION_NY:      return Inp_SessFactorNY;
      default:              return Inp_SessFactorOff;
   }
}

ENUM_VOL_REGIME GetVolatilityRegime()
{
   if(m_mkt.atrSlow<=0||m_mkt.atr<=0) return VOL_NORMAL;
   double r=m_mkt.atr/m_mkt.atrSlow;
   if(r>1.50) return VOL_HIGH;
   if(r<0.65) return VOL_LOW;
   return VOL_NORMAL;
}

string VolRegimeName(ENUM_VOL_REGIME r)
{ switch(r){case VOL_LOW:return "LOW";case VOL_HIGH:return "HIGH";default:return "NORMAL";} }

string SessionName(ENUM_SESSION_STATE s)
{ switch(s){case SESSION_ASIAN:return"ASIAN";case SESSION_LONDON:return"LONDON";
  case SESSION_OVERLAP:return"OVERLAP";case SESSION_NY:return"NY";default:return"OFF";} }

int GetStage2Delay(ENUM_SESSION_STATE s)
{
   switch(s){
      case SESSION_ASIAN:   return Inp_Stage2DelayAsian;
      case SESSION_LONDON:  return Inp_Stage2DelayLondon;
      case SESSION_OVERLAP: return Inp_Stage2DelayOverlap;
      case SESSION_NY:      return Inp_Stage2DelayNY;
      default:              return Inp_Stage2DelayAsian;
   }
}

double GetRecovDistATR(ENUM_VOL_REGIME r)
{
   switch(r){case VOL_LOW:return Inp_RecovDistLow;case VOL_HIGH:return Inp_RecovDistHigh;
   default:return Inp_RecovDistNormal;}
}

void UpdateDynamicThresholds()
{
   m_dyn.session       = GetCurrentSession();
   m_dyn.volRegime     = GetVolatilityRegime();
   m_dyn.sessionFactor = GetSessionFactor(m_dyn.session);
   m_dyn.atr2usd       = ATR2USD(1.0);
   double atr          = m_dyn.atr2usd;

   if(atr<=0.01){
      m_dyn.stage1Trigger=Inp_Stage1Trigger; m_dyn.stage3Trigger=Inp_Stage3Trigger;
      m_dyn.blockTP=Inp_BlockTPTarget;       m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;
      m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD; m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;
   } else {
      double sf=m_dyn.sessionFactor;
      double s1Raw=-(atr*Inp_DynStage1Mult*sf); s1Raw=MathMax(s1Raw,-Inp_DynMaxStage1USD);
      m_dyn.stage1Trigger=MathMin(s1Raw,Inp_Stage1Trigger);
      double s3Raw=-(atr*Inp_DynStage3Mult*sf); s3Raw=MathMax(s3Raw,-Inp_DynMaxStage3USD);
      m_dyn.stage3Trigger=MathMin(s3Raw,Inp_Stage3Trigger);
      
      double tpMultiplier = 1.0;
      if(m_blockStage >= 2) tpMultiplier += (m_blockStage * 0.35);
      
      double tpRaw=atr*Inp_DynTPMult*sf*tpMultiplier; tpRaw=MathMin(tpRaw,Inp_DynMaxTPUSD*tpMultiplier);
      m_dyn.blockTP=MathMax(tpRaw,Inp_BlockTPTarget*tpMultiplier);
      
      m_dyn.recovTrigger=MathMin(-(atr*Inp_DynRecovMult*sf),Inp_RecoveryTriggerUSD);
      m_dyn.netHedgeTrig1=MathMin(-(atr*Inp_NetHedgeMult1),Inp_NetHedgeTrigger1USD);
      m_dyn.netHedgeTrig2=MathMin(-(atr*Inp_NetHedgeMult2),Inp_NetHedgeTrigger2USD);
   }
   m_dyn.stage2Delay  = GetStage2Delay(m_dyn.session);
   m_dyn.recovDistATR = GetRecovDistATR(m_dyn.volRegime);
}

//=================================================================
//  [V7.9.1] ANTI-SYMMETRIC GUARD 
//=================================================================
bool AntiSymmetricOK(ENUM_ORDER_TYPE type, double lot)
{
   double netVol = m_port.buyVolume - m_port.sellVolume;
   double newNet = (type==ORDER_TYPE_BUY) ? netVol+lot : netVol-lot;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(minLot <= 0) minLot = 0.01;
   
   if(MathAbs(newNet) >= minLot * 0.99) return true;
   return false;
}

//=================================================================
//  HELPERS
//=================================================================
double NormLot(double lot)
{
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=MathMin(SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX),Inp_LotMaximum);
   if(step<=0) step=0.01;
   lot=MathFloor(lot/step)*step;
   return NormalizeDouble(MathMax(minL,MathMin(maxL,lot)),2);
}

double NormPrice(double p)  { return NormalizeDouble(p,_Digits); }
bool   GetTick(MqlTick &t) { return SymbolInfoTick(_Symbol,t); }

double GetATR()
{ double b[1]; if(CopyBuffer(h_ATR,0,1,1,b)==1) return b[0]; return _Point*200; }

double GetTickVal()  { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize() { return SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); }

double DistToUSD(double dist, double lot)
{
   double tv=GetTickVal(),ts=GetTickSize();
   if(tv<=0||ts<=0||dist<=0||lot<=0) return 0;
   return NormalizeDouble((dist/ts)*tv*lot,2);
}

bool SpreadOK()
{
   int maxSpr=m_inSession?Inp_MaxSpread:(int)Inp_CTMaxSpreadOff;
   return (SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=maxSpr);
}

bool MarginOK(double lot, ENUM_ORDER_TYPE type)
{
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY),bal=AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal<Inp_CTMinBalanceUSD) return false;
   if(free<eq*Inp_MinFreeMarginPct) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)) if(marg>free*0.60) return false;
   return true;
}

bool MarginOK_Hedge(double lot, ENUM_ORDER_TYPE type)
{
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE); if(free<=0) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid,marg=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,marg)){if(marg<=0)return false;return(marg<=free*0.90);}
   return false;
}

double CalcMarginFor001()
{
   double marg=0; MqlTick t; GetTick(t);
   if(!OrderCalcMargin(ORDER_TYPE_BUY,_Symbol,0.01,t.ask,marg)) return 2.0;
   return (marg>0)?marg:2.0;
}

//=================================================================
//  RECORDS
//=================================================================
int FindRec(ulong ticket)
{ for(int i=0;i<MAX_RECORDS;i++) if(m_rec[i].ticket==ticket) return i; return -1; }

int FreeRec()
{ for(int i=0;i<MAX_RECORDS;i++) if(m_rec[i].ticket==0) return i; return -1; }

void InitRec(int idx,ulong ticket,int posType,double openPrice,double vol,
             string comment,bool isPrimary,bool isCounter,
             bool isRecovery=false,bool isLBC=false)
{
   if(idx<0||idx>=MAX_RECORDS) return;
   ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket=ticket; m_rec[idx].posType=posType; m_rec[idx].openPrice=openPrice;
   m_rec[idx].volume=vol;    m_rec[idx].openTime=TimeCurrent(); m_rec[idx].comment=comment;
   m_rec[idx].isPrimary=isPrimary; m_rec[idx].isCounter=isCounter;
   m_rec[idx].isRecovery=isRecovery; m_rec[idx].isLBC=isLBC;
   m_rec[idx].kP=1.0; m_rec[idx].kK=1.0;
}

void CleanupRecs()
{
   for(int i=0;i<MAX_RECORDS;i++){
      if(m_rec[i].ticket==0) continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)){
         double pnl=m_rec[i].netProfit;
         if(pnl!=0){
            m_totalPnL+=pnl; m_tradesClosed++;
            if(pnl>0){m_totalWins++;m_sumWins+=pnl;}
            else{m_totalLosses++;m_sumLosses+=MathAbs(pnl);}
            if(pnl>m_bestClosed)m_bestClosed=pnl;
            if(pnl<m_worstClosed)m_worstClosed=pnl;
         }
         ZeroMemory(m_rec[i]);
      }
   }
}

void SyncPositions()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(FindRec(t)>=0) continue;
      int idx=FreeRec(); if(idx<0) continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);
      double op=PositionGetDouble(POSITION_PRICE_OPEN),vol=PositionGetDouble(POSITION_VOLUME);
      string comm=PositionGetString(POSITION_COMMENT);
      bool isPri=(StringFind(comm,"Primary")>=0),isCT=(StringFind(comm,"CT_")>=0);
      bool isRec=(StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0);
      bool isLBC=(StringFind(comm,"LBC_")>=0);
      InitRec(idx,t,pt,op,vol,comm,isPri,isCT,isRec,isLBC);
   }
}

//=================================================================
//  KALMAN
//=================================================================
void KalmanUpdate(int idx,double meas)
{
   if(!m_rec[idx].kInit){m_rec[idx].kX=meas;m_rec[idx].kP=1.0;m_rec[idx].kK=1.0;m_rec[idx].kInit=true;return;}
   double pP=m_rec[idx].kP+0.01,K=pP/(pP+0.20);
   m_rec[idx].kX+=K*(meas-m_rec[idx].kX); m_rec[idx].kP=(1.0-K)*pP; m_rec[idx].kK=K;
}

void UpdateKalman()
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      int idx=FindRec(t); if(idx<0) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit=pf;
      if(pf>m_rec[idx].peakProfit) m_rec[idx].peakProfit=pf;
      KalmanUpdate(idx,pf);
   }
}

//=================================================================
//  SESION
//=================================================================
bool IsInMainSession()
{
   return true; 
}

//=================================================================
//  TEMA + KALMAN
//=================================================================
void UpdateTEMAKalman()
{
   if(!Inp_UseTEMAKalman){
      m_mkt.trendConfirmed=m_mkt.isBullish?1:(m_mkt.isBearish?-1:0); return;
   }
   MqlTick tk; if(!GetTick(tk)) return;
   double price=(tk.bid+tk.ask)/2.0; if(price<=0) return;

   double alphaF=2.0/(double)(Inp_TEMAFastPeriod+1);
   if(!m_temaF_init){m_temaF_e1=m_temaF_e2=m_temaF_e3=price;m_temaF_init=true;}
   m_temaF_e1+=alphaF*(price-m_temaF_e1); m_temaF_e2+=alphaF*(m_temaF_e1-m_temaF_e2);
   m_temaF_e3+=alphaF*(m_temaF_e2-m_temaF_e3);
   m_mkt.temaFast=3.0*m_temaF_e1-3.0*m_temaF_e2+m_temaF_e3;

   double alphaS=2.0/(double)(Inp_TEMASlowPeriod+1);
   if(!m_temaS_init){m_temaS_e1=m_temaS_e2=m_temaS_e3=price;m_temaS_init=true;}
   m_temaS_e1+=alphaS*(price-m_temaS_e1); m_temaS_e2+=alphaS*(m_temaS_e1-m_temaS_e2);
   m_temaS_e3+=alphaS*(m_temaS_e2-m_temaS_e3);
   m_mkt.temaSlow=3.0*m_temaS_e1-3.0*m_temaS_e2+m_temaS_e3;

   if(!m_kalF_init){m_kalF_x=m_mkt.temaFast;m_kalF_p=1.0;m_kalF_init=true;}
   m_kalF_p+=Inp_KalmanQ; double kgF=m_kalF_p/(m_kalF_p+Inp_KalmanR);
   m_kalF_x+=kgF*(m_mkt.temaFast-m_kalF_x); m_kalF_p*=(1.0-kgF); m_mkt.kalmanFast=m_kalF_x;

   if(!m_kalS_init){m_kalS_x=m_mkt.temaSlow;m_kalS_p=1.0;m_kalS_init=true;}
   m_kalS_p+=Inp_KalmanQ; double kgS=m_kalS_p/(m_kalS_p+Inp_KalmanR);
   m_kalS_x+=kgS*(m_mkt.temaSlow-m_kalS_x); m_kalS_p*=(1.0-kgS); m_mkt.kalmanSlow=m_kalS_x;

   bool temaBull=(m_mkt.temaFast>m_mkt.temaSlow), temaBear=(m_mkt.temaFast<m_mkt.temaSlow);
   bool kalBull=(m_mkt.kalmanFast>m_mkt.kalmanSlow), kalBear=(m_mkt.kalmanFast<m_mkt.kalmanSlow);
   if(temaBull&&kalBull) m_mkt.trendConfirmed=1;
   else if(temaBear&&kalBear) m_mkt.trendConfirmed=-1;
   else m_mkt.trendConfirmed=0;
   m_mkt.isBullish=(m_mkt.trendConfirmed==1); m_mkt.isBearish=(m_mkt.trendConfirmed==-1);
}

//=================================================================
//  ACTUALIZACION DE MERCADO (THROTTLE ASÍNCRONO)
//=================================================================
void UpdateMarket()
{
   MqlTick t; if(!GetTick(t)) return;
   
   m_mkt.bid=t.bid; m_mkt.ask=t.ask; m_mkt.spread=(t.ask-t.bid)/_Point; 
   
   static datetime lastIndCalc=0;
   datetime now=TimeCurrent();
   
   if(now != lastIndCalc) {
      m_mkt.atr=GetATR();
      double f[1],s[1],r[1],m[1],sg[1];
      if(CopyBuffer(h_EMAFast,0,0,1,f)==1) m_mkt.emaFast=f[0];
      if(CopyBuffer(h_EMASlow,0,0,1,s)==1) m_mkt.emaSlow=s[0];
      if(CopyBuffer(h_RSI,0,0,1,r)==1) m_mkt.rsi=r[0];
      if(CopyBuffer(h_MACD,0,0,1,m)==1) m_mkt.macdMain=m[0];
      if(CopyBuffer(h_MACD,1,0,1,sg)==1) m_mkt.macdSig=sg[0];
      if(h_ADX!=INVALID_HANDLE){double adxB[1];if(CopyBuffer(h_ADX,0,0,1,adxB)==1) m_mkt.adx=adxB[0];}
      if(h_HTFEMAFast!=INVALID_HANDLE&&h_HTFEMASlow!=INVALID_HANDLE){
         double hf[1],hs[1];
         if(CopyBuffer(h_HTFEMAFast,0,0,1,hf)==1&&CopyBuffer(h_HTFEMASlow,0,0,1,hs)==1)
            m_mkt.htfTrend=(hf[0]>hs[0]*1.0001)?1:(hf[0]<hs[0]*0.9999)?-1:0;
      }
      if(h_EMA200!=INVALID_HANDLE){double e200[1];if(CopyBuffer(h_EMA200,0,1,1,e200)==1) m_mkt.ema200=e200[0];}
      if(h_ATRSlow!=INVALID_HANDLE){double atrS[1];if(CopyBuffer(h_ATRSlow,0,1,1,atrS)==1) m_mkt.atrSlow=atrS[0];}

      m_mkt.isBullish=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.rsi>52&&m_mkt.macdMain>m_mkt.macdSig);
      m_mkt.isBearish=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.rsi<48&&m_mkt.macdMain<m_mkt.macdSig);
      UpdateTEMAKalman();
      UpdateDynamicThresholds();
      
      lastIndCalc = now;
   }
}

//=================================================================
//  PORTFOLIO
//=================================================================
void UpdatePortfolio()
{
   ZeroMemory(m_port); m_port.worstProfit=0;
   m_losingPosOpenPrice=0; m_losingPosType=-1;
   double vwapN=0,vwapD=0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      long magic=PositionGetInteger(POSITION_MAGIC);
      bool isOwn=(magic==Inp_Magic), isExt=(!isOwn&&Inp_RescueAllTrades);
      if(!isOwn&&!isExt) continue;
      int pt=(int)PositionGetInteger(POSITION_TYPE);
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol=PositionGetDouble(POSITION_VOLUME),op=PositionGetDouble(POSITION_PRICE_OPEN);
      string comm=PositionGetString(POSITION_COMMENT);
      m_port.totalPos++; m_port.totalProfit+=pf;
      if(pf>=0) m_port.positiveSum+=pf; else m_port.negativeSum+=MathAbs(pf);
      if(pt==POSITION_TYPE_BUY){m_port.buyCount++;m_port.buyProfit+=pf;m_port.buyVolume+=vol;}
      else{m_port.sellCount++;m_port.sellProfit+=pf;m_port.sellVolume+=vol;}
      vwapN+=op*vol; vwapD+=vol;
      m_port.blockDir+=(pt==POSITION_TYPE_BUY)?1:-1;
      if(pf<m_port.worstProfit){
         m_port.worstProfit=pf;m_port.worstTicket=t;
         m_losingPosOpenPrice=op;m_losingPosType=pt;
      }
      if(isOwn){
         if(StringFind(comm,"CT_")>=0) m_port.ctCount++;
         if(StringFind(comm,"REC_")>=0||StringFind(comm,"BSE_")>=0) m_port.recoveryCount++;
         if(StringFind(comm,"LBC_")>=0) m_port.lbcCount++;
      }
      if(isExt){m_port.rescueCount++;m_port.rescueProfit+=pf;}
   }
   if(vwapD>0) m_port.blockVWAP=vwapN/vwapD;
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq>m_bestEquity) m_bestEquity=eq;
   m_port.currentDD=(m_bestEquity>0)?(m_bestEquity-eq)/m_bestEquity:0;
}

//=================================================================
//  SENSORES
//=================================================================
int ParseHH(string t){return(int)StringToInteger(StringSubstr(t,0,2));}
int ParseMM(string t){return(int)StringToInteger(StringSubstr(t,3,2));}

void CalcBrokerTimeWindow()
{
   int s=ParseHH(Inp_StartTime)*60+ParseMM(Inp_StartTime);
   int e=ParseHH(Inp_EndTime)*60+ParseMM(Inp_EndTime);
   int off=(Inp_BrokerGMT-Inp_UserGMT)*60;
   m_sensors.brokerStartMin=((s+off)%1440+1440)%1440;
   m_sensors.brokerEndMin=((e+off)%1440+1440)%1440;
}

bool IsInTradingWindow()
{
   return true; 
}

bool TrendFilter200OK(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseTrendFilter200||m_mkt.ema200<=0) return true;
   MqlTick tk; if(!GetTick(tk)) return true;
   double mid=(tk.bid+tk.ask)/2.0;
   if(type==ORDER_TYPE_BUY) return(mid>m_mkt.ema200);
   if(type==ORDER_TYPE_SELL) return(mid<m_mkt.ema200);
   return true;
}

bool VolatilityOK()
{
   if(!Inp_UseVolatFilter||m_mkt.atrSlow<=0) return true;
   m_sensors.atrRatio=m_mkt.atr/m_mkt.atrSlow;
   return(m_sensors.atrRatio<=Inp_ATRRatioMax);
}

bool MarginGuardOK()
{
   if(!Inp_UseMarginGuard) return true;
   double lot = CalcLot(0), marg1 = 0;
   MqlTick tk; if(!GetTick(tk)) return true;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, tk.ask, marg1) || marg1 <= 0) return true;
   
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double adaptiveLevels = (bal <= 200.0) ? 0.0 : Inp_MarginGuardLevels;
   
   return (AccountInfoDouble(ACCOUNT_MARGIN_FREE) >= marg1 * (1.0 + adaptiveLevels));
}

void UpdateSensors()
{
   m_sensors.blockReason="";
   m_sensors.timeOK=IsInTradingWindow();
   if(!m_sensors.timeOK&&m_sensors.blockReason=="") m_sensors.blockReason="Fuera de ventana horaria";
   m_sensors.spreadOK=SpreadOK();
   if(!m_sensors.spreadOK&&m_sensors.blockReason==""){
      int cs=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
      m_sensors.blockReason="Spread muy alto: "+IntegerToString(cs)+" pts";
   }
   if(m_mkt.ema200>0){MqlTick tk;GetTick(tk);m_sensors.trendBull=((tk.bid+tk.ask)/2.0>m_mkt.ema200);}
   else m_sensors.trendBull=true;
   m_sensors.volatOK=VolatilityOK();
   if(!m_sensors.volatOK&&m_sensors.blockReason=="")
      m_sensors.blockReason="Tormenta ATR ratio="+DoubleToString(m_sensors.atrRatio,1);
   if(m_dyn.volRegime==VOL_HIGH&&m_sensors.volatOK&&m_sensors.blockReason=="")
      m_sensors.blockReason="Vol.Regime HIGH bloqueando";
   m_sensors.marginOK=MarginGuardOK();
   if(!m_sensors.marginOK&&m_sensors.blockReason=="")
      m_sensors.blockReason="Margen libre insuficiente";
   m_sensors.allOK=(m_sensors.timeOK&&m_sensors.spreadOK&&m_sensors.volatOK&&
                    m_sensors.marginOK&&m_dyn.volRegime!=VOL_HIGH);
}

bool ADXAllowsEntry(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseADX) return true;
   double adxLevel=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   if(m_mkt.adx<adxLevel) return true;
   int htf=m_mkt.htfTrend; if(htf==0) return false;
   return(type==ORDER_TYPE_BUY&&htf==1)||(type==ORDER_TYPE_SELL&&htf==-1);
}

void ResetDailyIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt);
   datetime midnight=TimeCurrent()-(dt.hour*3600+dt.min*60+dt.sec);
   if(m_lastDailyReset<midnight){m_dailyBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_dailyLimitHit=false;m_lastDailyReset=midnight;}
}

bool DailyLimitReached()
{
   if(!Inp_UseDailyLimit||m_dailyLimitHit) return m_dailyLimitHit;
   double eff=(AccountInfoDouble(ACCOUNT_BALANCE)-m_dailyBalance)+m_port.totalProfit;
   double lim=MathMin(MathAbs(Inp_DailyLossUSD),m_dailyBalance*MathAbs(Inp_DailyLossPct));
   if(eff<=-lim){Print("[AQ V8.0.0-FSM] LIMITE DIARIO ALCANZADO");m_dailyLimitHit=true;m_isPaused=true;}
   return m_dailyLimitHit;
}

void UpdateStreak(double pnl)
{
   if(pnl<-0.01){m_consecutiveLosses++;if(m_consecutiveLosses>=Inp_LossStreakMax&&m_lotMultiplier==1.0)m_lotMultiplier=Inp_LossStreakReduce;}
   else if(pnl>0.01){m_lotMultiplier=1.0;m_consecutiveLosses=0;}
}

double CalcExpectancy()
{
   int total=m_totalWins+m_totalLosses; if(total==0) return 0;
   double wr=(double)m_totalWins/total;
   double avgW=(m_totalWins>0)?m_sumWins/m_totalWins:0;
   double avgL=(m_totalLosses>0)?m_sumLosses/m_totalLosses:0;
   return (wr*avgW)-((1.0-wr)*avgL);
}

//=================================================================
//  CIERRE
//=================================================================
bool ClosePos(ulong ticket, string reason="")
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) return false;
   if(!m_isProcessing&&m_port.totalPos>1){
      return false;
   }
   double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)){
      UpdateStreak(pf);
      if(pf>0){m_cycleWinsSum+=pf;m_cycleWinsCount++;m_totalWins++;m_sumWins+=pf;}
      else{m_cycleLossSum+=pf;m_totalLosses++;m_sumLosses+=MathAbs(pf);}
      m_totalPnL+=pf;m_tradesClosed++;
      if(pf>m_bestClosed)m_bestClosed=pf; if(pf<m_worstClosed)m_worstClosed=pf;
      int idx=FindRec(ticket);
      if(idx>=0){
         if(m_rec[idx].isPrimary) m_lastPrimaryLost=(pf<0);
         if(m_rec[idx].isLBC){
            string comm=m_rec[idx].comment;
            if(StringFind(comm,"LBC_B")>=0&&m_lbc.buyCount>0)m_lbc.buyCount--;
            if(StringFind(comm,"LBC_S")>=0&&m_lbc.sellCount>0)m_lbc.sellCount--;
            if(pf>0){m_lbc.harvestedTotal+=pf;m_lbc.harvestCount++;}
         }
         Print("[AQ V8.0.0-FSM] CERRADA #",ticket," $",NormalizeDouble(pf,2),(reason!=""?" ["+reason+"]":""));
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
   if(m_trade.PositionClose(ticket)){m_totalPnL+=pf;m_tradesClosed++;
      Print("[AQ V8.0.0-FSM] RESCATE #",ticket," $",NormalizeDouble(pf,2)," [",reason,"]"); return true;}
   return false;
}

bool CloseBlockIfPositive(string reason)
{
   if(m_port.totalProfit<m_dyn.blockTP) return false;
   Print("[AQ V8.0.0-FSM] CIERRE POSITIVO: PnL=$",NormalizeDouble(m_port.totalProfit,2),
         " >= $",NormalizeDouble(m_dyn.blockTP,2)," [",reason,"] Stage=",m_blockStage);
   m_isProcessing=true;
   for(int pass=0;pass<2;pass++){
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pass==0&&pf<0) continue; if(pass==1&&pf>=0) continue;
         ClosePos(t,reason);
      }
   }
   if(Inp_RescueAllTrades){
      for(int pass=0;pass<2;pass++){
         for(int i=PositionsTotal()-1;i>=0;i--){
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
   m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
   m_netHedge1Applied=false;m_netHedge2Applied=false;
   m_blockStage=0;m_stageFollowHedge=false;
   m_stage1TriggerAtOpen=0;m_stage3TriggerAtOpen=0;
   m_detangleDetectTime=0;m_detangleActive=false;
   m_primaryOpenTime=0;
   m_cycleResetTime=TimeCurrent();m_cycleInPause=true;
   m_lastCTBuyPrice=m_lastCTSellPrice=0;
   ZeroMemory(m_lbc);
   return true;
}

//=================================================================
//  LOTES
//=================================================================
double CalcLot(int level=0)
{
   double sessionFactor=m_inSession?1.0:Inp_OffSessionLotFactor;
   if(!Inp_UseDynamicLot||m_mkt.atr<=0) return NormLot(Inp_LotBase*m_lotMultiplier*sessionFactor);
   double bal=AccountInfoDouble(ACCOUNT_BALANCE),riskUSD=bal*Inp_RiskPerTradePct;
   double slATR=m_inSession?Inp_SL_ATR:Inp_OffSessionSL_ATR,slDist=m_mkt.atr*slATR;
   double tv=GetTickVal(),ts=GetTickSize(),lot=Inp_LotBase;
   if(tv>0&&ts>0&&slDist>0){double pipV=tv/ts;if(pipV>0) lot=riskUSD/(slDist*pipV);}
   return NormLot(MathMax(lot,Inp_LotBase)*m_lotMultiplier*sessionFactor);
}

double CalcDirectionalLot(int targetDir)
{
   double atr=m_mkt.atr; if(atr<=0) return NormLot(Inp_LotBase*2.0);
   double blockLoss=MathAbs(m_port.totalProfit);
   double totalNeeded=blockLoss+m_dyn.blockTP;
   double moveDist=atr*Inp_RecoveryMoveATR; if(moveDist<=0) moveDist=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),calcLot=Inp_LotBase*2.0;
   if(tv>0&&ts>0&&moveDist>0){
      double profitPer=(moveDist/ts)*tv;
      if(profitPer>0) calcLot=totalNeeded/profitPer;
   }
   double netVol=m_port.buyVolume-m_port.sellVolume;
   double projectedNet=(targetDir==1)?netVol+calcLot:netVol-calcLot;
   double minNetNeeded=Inp_LotBase*1.5;
   if(targetDir==1&&projectedNet<minNetNeeded)
      calcLot=MathMax(calcLot,minNetNeeded-netVol);
   else if(targetDir==-1&&projectedNet>-minNetNeeded)
      calcLot=MathMax(calcLot,netVol+minNetNeeded);
   return NormLot(MathMax(calcLot,Inp_LotBase*2.0));
}

double CalcRecoveryLot()
{
   double atr=m_mkt.atr;
   if(atr<=0) return NormLot(Inp_LotBase*Inp_RecoveryMinLotMult);
   double blockLoss=MathAbs(m_port.totalProfit),totalNeeded=blockLoss+m_dyn.blockTP;
   double moveDist=atr*Inp_RecoveryMoveATR; if(moveDist<=0) moveDist=atr*0.5;
   double tv=GetTickVal(),ts=GetTickSize(),profitPer1=0;
   if(tv>0&&ts>0) profitPer1=(moveDist/ts)*tv;
   double calcLot=Inp_LotBase;
   if(profitPer1>0) calcLot=totalNeeded/profitPer1;
   double loserLot=Inp_LotBase;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol=PositionGetDouble(POSITION_VOLUME);
      if(pf==m_port.worstProfit){loserLot=vol;break;}
   }
   return NormLot(MathMax(calcLot,loserLot*Inp_RecoveryMinLotMult));
}

//=================================================================
//  APERTURA
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type,double lot,string comment,bool skipPosLimit=false)
{
   if(m_emergencyMode) return 0; 
   if(m_isPaused && !skipPosLimit) return 0;
   if(!SpreadOK()) return 0;
   
   if(!skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal) return 0;
   if(skipPosLimit&&PositionsTotal()>=Inp_MaxPositionsTotal+4) return 0;
   lot=NormLot(lot); if(lot<=0) return 0;
   if(!MarginOK(lot,type)) return 0;
   MqlTick t; if(!GetTick(t)) return 0;
   double price=(type==ORDER_TYPE_BUY)?t.ask:t.bid;
   bool ok=(type==ORDER_TYPE_BUY)?m_trade.Buy(lot,_Symbol,price,0,0,comment):m_trade.Sell(lot,_Symbol,price,0,0,comment);
   if(!ok){Print("[AQ V8.0.0-FSM] ERR apertura: ",m_trade.ResultRetcodeDescription());return 0;}
   ulong ticket=m_trade.ResultOrder();
   if(ticket>0){
      m_tradesOpened++;
      Print("[AQ V8.0.0-FSM] ABIERTA #",ticket," ",(type==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=",lot," @ ",NormalizeDouble(price,_Digits),
            " SL=0 TP=0 [",comment,"] Stage=",m_blockStage,
            " Sesion=",SessionName(m_dyn.session));
   }
   return ticket;
}

void ManagePositions() {}

//=================================================================
//  DETANGLE ENGINE
//=================================================================
void RunDetangle()
{
   if(m_isProcessing||m_port.totalPos<2) return;
   double netVol=MathAbs(m_port.buyVolume-m_port.sellVolume);
   bool isSym=(netVol<Inp_DetangleNetThresh);
   bool isPnLBad=(m_port.totalProfit<Inp_DetangleMinLoss);

   if(!isSym||!isPnLBad){
      if(!isSym){m_detangleDetectTime=0;m_detangleActive=false;}
      return;
   }

   if(m_detangleDetectTime==0){
      m_detangleDetectTime=TimeCurrent();
      m_detangleActive=true;
      Print("[AQ V8.0.0-FSM] DETANGLE: jaula simetrica detectada | NetVol=",
            NormalizeDouble(netVol,3)," PnL=",NormalizeDouble(m_port.totalProfit,2));
      return;
   }

   if((int)(TimeCurrent()-m_detangleDetectTime)<Inp_DetangleSec) return;
   if(!SpreadOK()) return;

   if(m_port.worstTicket>0&&m_port.worstProfit<0){
      Print("[AQ V8.0.0-FSM] DETANGLE EJECUTANDO: cerrando peor pos #",m_port.worstTicket,
            " PnL=",NormalizeDouble(m_port.worstProfit,2),
            " | Rompe simetria en beneficio del lado contrario");
      m_isProcessing=true;
      bool closed=ClosePos(m_port.worstTicket,"Detangle_BreakSym");
      m_isProcessing=false;
      if(closed){
         m_detangleDetectTime=TimeCurrent(); 
         m_detangleActive=false;
         UpdatePortfolio();
      }
   }
}

//=================================================================
//  BLOCK STAGE ENGINE
//=================================================================
void RunBlockStageEngine()
{
   if(m_isProcessing)    return;
   if(m_blockStage==0)   return;

   int mainPosCount=m_port.totalPos-m_port.lbcCount;

   if(mainPosCount<=0&&m_port.totalPos==0){m_blockStage=0;m_stageFollowHedge=false;return;}
   if(mainPosCount<=0) return; 

   MqlTick tk; if(!GetTick(tk)) return;
   double totalPnL=m_port.totalProfit;

   if(m_blockStage==1&&mainPosCount==1){
      double trigger1=(m_stage1TriggerAtOpen!=0)?m_stage1TriggerAtOpen:m_dyn.stage1Trigger;
      int holdTimeSec=(int)(TimeCurrent()-m_primaryOpenTime);
      bool emergencyOverride=(totalPnL<=trigger1*Inp_StageEmergMult);

      if(holdTimeSec<Inp_PrimaryMinHoldSec&&!emergencyOverride){
         return;
      }

      if(totalPnL<=trigger1){
         int trendDir=m_mkt.trendConfirmed;
         int primaryDir=(m_primaryType==ORDER_TYPE_BUY)?1:-1;

         if(Inp_UseDirectionalStage&&trendDir==primaryDir&&trendDir!=0){
            ENUM_ORDER_TYPE reinType=m_primaryType;
            double reinLot=NormLot(Inp_LotBase*Inp_ReinforceLotMult);

            if(MarginOK(reinLot,reinType)&&AntiSymmetricOK(reinType,reinLot)){
               m_isProcessing=true;
               ulong t1=OpenOrder(reinType,reinLot,"BSE_REINF1",true);
               m_isProcessing=false;
               if(t1>0){
                  int idx=FreeRec();
                  if(idx>=0){
                     int pt1=(reinType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
                     double op1=(reinType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
                     InitRec(idx,t1,pt1,op1,reinLot,"BSE_REINF1",false,false,true,false);
                  }
                  m_blockStage=2;m_stage2Time=TimeCurrent();m_recoveryActive=true;
                  m_stageFollowHedge=false; 
                  m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
                  Print("[AQ V8.0.0-FSM] >>> STAGE 2 via REFUERZO...");
               }
            }
         } else {
            ENUM_ORDER_TYPE hedgeType=(m_primaryType==ORDER_TYPE_BUY)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
            double hedgeLot=NormLot(Inp_LotBase*Inp_HedgeRatio);
            hedgeLot=MathMax(hedgeLot,NormLot(Inp_LotBase));

            if(!AntiSymmetricOK(hedgeType, hedgeLot)) {
                double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
                if (volStep <= 0) volStep = 0.01;
                hedgeLot = NormLot(hedgeLot + volStep);
            }

            if(MarginOK(hedgeLot,hedgeType)){
               m_isProcessing=true;
               ulong t1=OpenOrder(hedgeType,hedgeLot,"BSE_H1",true);
               m_isProcessing=false;
               if(t1>0){
                  int idx=FreeRec();
                  if(idx>=0){
                     int pt1=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
                     double op1=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
                     InitRec(idx,t1,pt1,op1,hedgeLot,"BSE_H1",false,false,true,false);
                  }
                  m_blockStage=2;m_stage2Time=TimeCurrent();m_recoveryActive=true;
                  m_stageFollowHedge=true; 
                  m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
                  Print("[AQ V8.0.0-FSM] >>> STAGE 2 via HEDGE ASIMETRICO...");
               }
            }
         }
      }
      return;
   }

   if(m_blockStage==2&&mainPosCount==2){
      if((int)(TimeCurrent()-m_stage2Time)<m_dyn.stage2Delay) return;
      if(!SpreadOK()) return;

      int trendDir=m_mkt.trendConfirmed;
      ENUM_ORDER_TYPE thirdType;
      int targetDir;

      if(trendDir==1){
         thirdType=ORDER_TYPE_BUY; targetDir=1;
      } else if(trendDir==-1){
         thirdType=ORDER_TYPE_SELL; targetDir=-1;
      } else {
         if(m_port.buyProfit<m_port.sellProfit){
            thirdType=ORDER_TYPE_SELL; targetDir=-1;
         } else {
            thirdType=ORDER_TYPE_BUY; targetDir=1;
         }
      }

      double thirdLot=CalcDirectionalLot(targetDir);

      if(!AntiSymmetricOK(thirdType,thirdLot)){
         double netVol=m_port.buyVolume-m_port.sellVolume;
         double minNeeded=(targetDir==1)?Inp_LotBase*1.5-netVol:netVol+Inp_LotBase*1.5;
         thirdLot=NormLot(MathMax(thirdLot,MathAbs(minNeeded)));
      }

      string stage3Label=(targetDir==1)?"BSE_DIR_LONG":"BSE_DIR_SHORT";
      m_stageFollowHedge=(thirdType!=m_primaryType);

      if(MarginOK(thirdLot,thirdType)){
         m_isProcessing=true;
         ulong t2=OpenOrder(thirdType,thirdLot,stage3Label,true);
         m_isProcessing=false;
         if(t2>0){
            int idx=FreeRec();
            if(idx>=0){
               int pt2=(thirdType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
               double op2=(thirdType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
               InitRec(idx,t2,pt2,op2,thirdLot,stage3Label,false,false,true,false);
            }
            m_blockStage=3;
            Print("[AQ V8.0.0-FSM] >>> STAGE 3: 3ra DIRECCIONAL #",t2);
         }
      } else {
         ActivateLBC();
      }
      return;
   }

   if(m_blockStage==3){
      double trigger3=(m_stage3TriggerAtOpen!=0)?m_stage3TriggerAtOpen:m_dyn.stage3Trigger;
      if(totalPnL<=trigger3){
         if(!SpreadOK()) return;
         int trendDir=m_mkt.trendConfirmed;
         ENUM_ORDER_TYPE fourthType;
         int target4Dir;
         if(trendDir==1){fourthType=ORDER_TYPE_BUY;target4Dir=1;}
         else if(trendDir==-1){fourthType=ORDER_TYPE_SELL;target4Dir=-1;}
         else{
            if(m_port.buyProfit>m_port.sellProfit){fourthType=ORDER_TYPE_BUY;target4Dir=1;}
            else{fourthType=ORDER_TYPE_SELL;target4Dir=-1;}
         }
         double fourthLot=CalcDirectionalLot(target4Dir);
         if(!AntiSymmetricOK(fourthType,fourthLot)){
            double netVol=m_port.buyVolume-m_port.sellVolume;
            double minN=(target4Dir==1)?Inp_LotBase*2.0-netVol:netVol+Inp_LotBase*2.0;
            fourthLot=NormLot(MathMax(fourthLot,MathAbs(minN)));
         }
         if(MarginOK(fourthLot,fourthType)){
            m_isProcessing=true;
            ulong t3=OpenOrder(fourthType,fourthLot,"BSE_CON4",true);
            m_isProcessing=false;
            if(t3>0){
               int idx=FreeRec();
               if(idx>=0){
                  int pt3=(fourthType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;
                  double op3=(fourthType==ORDER_TYPE_BUY)?tk.ask:tk.bid;
                  InitRec(idx,t3,pt3,op3,fourthLot,"BSE_CON4",false,false,true,false);
               }
               m_blockStage=4;
               Print("[AQ V8.0.0-FSM] >>> STAGE 4: Consolidacion #",t3);
            }
         } else {ActivateLBC();}
      }
      return;
   }

   if(m_blockStage==4){
      double lbcTrigger=m_dyn.stage3Trigger*1.5;
      if(!m_lbc.active&&totalPnL<lbcTrigger) ActivateLBC();
   }
}

//=================================================================
//  RECOVERY ENGINE FALLBACK (MICRO-ACCOUNT EXPANSION + STORM INTEG)
//=================================================================
void RunRecoveryEngine()
{
   if(m_port.totalProfit>=m_dyn.recovTrigger){
      if(m_recoveryActive&&m_blockStage==0){m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;}
      return;
   }
   if(m_port.totalPos==0||m_isProcessing) return;
   
   if(!m_recoveryActive){
      m_recoveryActive=true;m_recoveryOrders=m_port.recoveryCount;m_recoveryTrendHedge=false;
   }
   int maxRec=m_recoveryTrendHedge?Inp_RecoveryMaxOrdersTrend:Inp_RecoveryMaxOrders;
   if(m_recoveryOrders>=maxRec||TimeCurrent()-m_lastRecoveryTime<Inp_RecoveryIntervalSec||!SpreadOK()) return;
   MqlTick tk; if(!GetTick(tk)) return;
   double atr=m_mkt.atr; if(atr<=0) return;
   
   double minDist=atr*m_dyn.recovDistATR;
   
   // [OPT] Expansión del espaciado de la grilla en saldos bajos
   if(AccountInfoDouble(ACCOUNT_BALANCE) <= 200.0) {
      minDist *= 3.0; 
   }
   
   // [NUEVO] Si hay tormenta de volatilidad detectada, frenamos las recompras expandiendo el requisito mínimo
   if(m_stormActive) {
      minDist *= 1.5;
   }

   if(m_losingPosOpenPrice>0&&m_losingPosType>=0){
      double dist=(m_losingPosType==POSITION_TYPE_SELL)?tk.bid-m_losingPosOpenPrice:m_losingPosOpenPrice-tk.ask;
      if(dist<minDist) return;
   }
   ENUM_ORDER_TYPE recType;
   double adxLevel=m_inSession?Inp_ADXTrendLevel:Inp_ADXTrendLevelOff;
   bool bearT=(m_mkt.emaFast<m_mkt.emaSlow&&m_mkt.adx>adxLevel);
   bool bullT=(m_mkt.emaFast>m_mkt.emaSlow&&m_mkt.adx>adxLevel);
   if(m_port.buyProfit<m_port.sellProfit&&bearT){recType=ORDER_TYPE_SELL;m_recoveryTrendHedge=true;}
   else if(m_port.sellProfit<m_port.buyProfit&&bullT){recType=ORDER_TYPE_BUY;m_recoveryTrendHedge=true;}
   else{
      m_recoveryTrendHedge=false; double cd=atr*0.3;
      if(m_port.buyProfit<m_port.sellProfit){recType=ORDER_TYPE_BUY;if(m_lastCTBuyPrice>0&&MathAbs(tk.ask-m_lastCTBuyPrice)<cd)return;}
      else{recType=ORDER_TYPE_SELL;if(m_lastCTSellPrice>0&&MathAbs(tk.bid-m_lastCTSellPrice)<cd)return;}
   }
   
   double recLot=CalcRecoveryLot();
   if(!AntiSymmetricOK(recType,recLot)){
      double netVol=m_port.buyVolume-m_port.sellVolume;
      int targetDir=(recType==ORDER_TYPE_BUY)?1:-1;
      double minN=(targetDir==1)?Inp_LotBase-netVol:netVol+Inp_LotBase;
      recLot=NormLot(MathMax(recLot,MathAbs(minN)));
   }
   if(!MarginOK(recLot,recType)){recLot=NormLot(recLot*0.5);if(!MarginOK(recLot,recType)){recLot=NormLot(Inp_LotBase);if(!MarginOK(recLot,recType)){ActivateLBC();return;}}}
   string recComm="REC_"+(recType==ORDER_TYPE_BUY?"B":"S")+"_"+IntegerToString(m_recoveryOrders+1);
   m_isProcessing=true;
   ulong ticket=OpenOrder(recType,recLot,recComm,true);
   m_isProcessing=false;
   if(ticket>0){
      int idx=FreeRec();
      if(idx>=0){int pt=(recType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(recType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,recLot,recComm,false,false,true,false);}
      if(recType==ORDER_TYPE_BUY)m_lastCTBuyPrice=tk.ask; else m_lastCTSellPrice=tk.bid;
      m_recoveryOrders++;m_lastRecoveryTime=TimeCurrent();
   }
}

//=================================================================
//  LBC ENGINE
//=================================================================
void ActivateLBC()
{
   if(m_lbc.active) return;
   m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();
   m_lbc.buyCount=m_lbc.sellCount=0;m_lbc.lastBuyPrice=m_lbc.lastSellPrice=0;
   m_lbc.harvestedTotal=0;m_lbc.harvestCount=0;
   double freeMarg=AccountInfoDouble(ACCOUNT_MARGIN_FREE),margPer001=CalcMarginFor001();
   m_lbc.maxOrdersCalc=(int)MathFloor(freeMarg*Inp_LBCMarginPct/(2.0*MathMax(margPer001,0.01)));
   m_lbc.maxOrdersCalc=MathMax(1,MathMin(m_lbc.maxOrdersCalc,Inp_LBCMaxPairs));
}

void DeactivateLBC()
{
   if(!m_lbc.active) return;
   ZeroMemory(m_lbc);
}

void RunLBCEngine()
{
   if(!m_lbc.active) return;
   if(m_port.totalPos==0){DeactivateLBC();return;}
   if(m_isProcessing) return;
   if(m_port.totalProfit>=m_dyn.blockTP) return;
   if(m_port.totalProfit>=m_dyn.recovTrigger*0.5){DeactivateLBC();return;}
   MqlTick tk; if(!GetTick(tk)) return;
   double atr=m_mkt.atr; if(atr<=0) return;
   int nonLBCCount=m_port.totalPos-m_port.lbcCount;
   bool blockHasMainPositions=(nonLBCCount>0);

   if(!blockHasMainPositions){
      double harvestMin=DistToUSD(atr*Inp_LBCHarvestATR,0.01);
      harvestMin=MathMax(harvestMin,0.02);
      for(int i=PositionsTotal()-1;i>=0;i--){
         ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         string comm=PositionGetString(POSITION_COMMENT);
         if(StringFind(comm,"LBC_")<0) continue;
         double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
         if(pf>=harvestMin){
            ClosePos(t,"LBC_Harvest");
            double fm=AccountInfoDouble(ACCOUNT_MARGIN_FREE),mp001=CalcMarginFor001();
            m_lbc.maxOrdersCalc=(int)MathFloor((fm*Inp_LBCMarginPct)/(2.0*MathMax(mp001,0.01)));
            m_lbc.maxOrdersCalc=MathMax(1,MathMin(m_lbc.maxOrdersCalc,Inp_LBCMaxPairs));
         }
      }
   }

   if(m_blockStage>0&&blockHasMainPositions){
      return;
   }

   if(TimeCurrent()-m_lbc.lastOrderTime<Inp_LBCIntervalSec||!SpreadOK()) return;
   int totalLBCPairs=MathMin(m_lbc.buyCount,m_lbc.sellCount);
   if(totalLBCPairs>=m_lbc.maxOrdersCalc) return;
   double gridSpace=atr*Inp_LBCGridATR*(m_inSession?1.2:1.0);
   double lot001=NormLot(Inp_LotBase);
   bool needBuy=false,needSell=false;
   if(m_lbc.buyCount==0&&m_lbc.sellCount==0){needBuy=true;needSell=true;}
   else{
      if(m_lbc.buyCount<=m_lbc.sellCount&&(m_lbc.lastBuyPrice<=0||MathAbs(tk.ask-m_lbc.lastBuyPrice)>=gridSpace)) needBuy=true;
      if(m_lbc.sellCount<=m_lbc.buyCount&&(m_lbc.lastSellPrice<=0||MathAbs(tk.bid-m_lbc.lastSellPrice)>=gridSpace)) needSell=true;
   }
   if(needBuy&&MarginOK(lot001,ORDER_TYPE_BUY)){
      string commB="LBC_B"+IntegerToString(m_lbc.buyCount+1);
      m_isProcessing=true;ulong ticketB=OpenOrder(ORDER_TYPE_BUY,lot001,commB,true);m_isProcessing=false;
      if(ticketB>0){int idx=FreeRec();if(idx>=0)InitRec(idx,ticketB,POSITION_TYPE_BUY,tk.ask,lot001,commB,false,false,false,true);m_lbc.buyCount++;m_lbc.lastBuyPrice=tk.ask;m_lbc.lastOrderTime=TimeCurrent();}
   }
   if(needSell&&MarginOK(lot001,ORDER_TYPE_SELL)){
      string commS="LBC_S"+IntegerToString(m_lbc.sellCount+1);
      m_isProcessing=true;ulong ticketS=OpenOrder(ORDER_TYPE_SELL,lot001,commS,true);m_isProcessing=false;
      if(ticketS>0){int idx=FreeRec();if(idx>=0)InitRec(idx,ticketS,POSITION_TYPE_SELL,tk.bid,lot001,commS,false,false,false,true);m_lbc.sellCount++;m_lbc.lastSellPrice=tk.bid;m_lbc.lastOrderTime=TimeCurrent();}
   }
}

void RunBasketTP()
{
   if(!Inp_UseBasketTP||TimeCurrent()-m_lastBasketCheck<Inp_BasketCheckSec) return;
   m_lastBasketCheck=TimeCurrent(); if(m_port.totalPos<2) return;
   if(m_port.totalProfit<m_dyn.blockTP) return;
   double avgWin=(m_cycleWinsCount>0)?m_cycleWinsSum/m_cycleWinsCount:Inp_BasketTPFactor;
   double target=MathMax(m_dyn.blockTP,avgWin*Inp_BasketTPRatio);
   if(m_port.totalProfit>=target) CloseBlockIfPositive("BasketTP");
}

void CheckCycleMaxLoss()
{
   if(!Inp_UseCycleMaxLoss||m_port.totalPos==0) return;
   if(m_port.totalProfit<=Inp_CycleMaxLossUSD){
      if(!m_recoveryActive&&m_blockStage==0){m_recoveryActive=true;m_recoveryOrders=0;}
   }
}

void RunHarvest()
{
   if(m_port.totalPos>1||!Inp_HarvestContinuous||m_isProcessing) return;
   if(TimeCurrent()-m_lastHarvestTime<Inp_HarvestIntervalSec) return;
   m_lastHarvestTime=TimeCurrent();
   if(m_port.totalProfit>=m_dyn.blockTP) CloseBlockIfPositive("Harvest_Single");
}

//=================================================================
//  HARD CIRCUIT BREAKER Y RESETEO SEGURO
//=================================================================
void ForceCloseAll(string reason)
{
   for(int pass=0; pass<2; pass++){
      for(int i=PositionsTotal()-1; i>=0; i--){
         ulong t=PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         m_trade.PositionClose(t);
         Print("[AQ V8.0.0-FSM] HARD STOP EXECUTION #", t, " [", reason, "]");
      }
   }
}

bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   
   double currentDDPct = m_port.currentDD * 100.0;
   if(currentDDPct >= Inp_MaxDrawdownPct && Inp_MaxDrawdownPct < 100.0) {
      Print("[AQ V8.0.0-FSM] CRITICAL: Max Drawdown alcanzado (", DoubleToString(currentDDPct,2), "%). Ejecutando Hard Stop y Reseteando Motores.");
      ForceCloseAll("HARD_STOP_DD");
      
      m_bestEquity = AccountInfoDouble(ACCOUNT_EQUITY); 
      m_blockStage = 0;
      m_recoveryActive = false;
      m_recoveryOrders = 0;
      m_stageFollowHedge = false;
      DeactivateLBC();
      
      m_emergencyMode = true;
      m_isPaused = true;
      return true;
   }

   if(m_port.totalProfit <= Inp_EmergencyLossUSD && !m_emergencyMode){
      Print("[AQ V8.0.0-FSM] ALERTA EQUITY: $", NormalizeDouble(m_port.totalProfit,2), " -> Pausa primarias.");
      m_emergencyMode = true; m_isPaused = true; return true;
   }
   
   if(m_isPaused && !m_emergencyMode && !m_dailyLimitHit && m_port.currentDD < (Inp_MaxDrawdownPct/100.0)*0.5) 
      m_isPaused = false;
      
   return false;
}

//=================================================================
//  CT ENGINE + PRIMARY ENTRY
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType,double &ctLot,int &ctLevel)
{
   if(m_port.totalPos==0||m_port.totalPos>=Inp_MaxPositionsTotal) return false;
   if(m_port.totalProfit>=0&&m_port.negativeSum==0) return false;
   if(m_recoveryActive||m_lbc.active||m_mkt.atr<=0) return false;
   int buyCount=m_port.buyCount,sellCount=m_port.sellCount;
   bool buyLosing=(m_port.buyProfit<-0.05&&buyCount>0),sellLosing=(m_port.sellProfit<-0.05&&sellCount>0);
   bool openBuy=false,openSell=false;
   if(buyLosing&&!sellLosing){if(sellCount>=Inp_CTMaxSameDir)return false;openSell=true;}
   else if(sellLosing&&!buyLosing){if(buyCount>=Inp_CTMaxSameDir)return false;openBuy=true;}
   else if(buyLosing&&sellLosing){
      if(m_mkt.htfTrend==1&&buyCount<Inp_CTMaxSameDir) openBuy=true;
      else if(m_mkt.htfTrend==-1&&sellCount<Inp_CTMaxSameDir) openSell=true;
      else if(m_port.buyProfit<m_port.sellProfit&&sellCount<Inp_CTMaxSameDir) openSell=true;
      else if(buyCount<Inp_CTMaxSameDir) openBuy=true;
      else return false;
   } else return false;
   ENUM_ORDER_TYPE testType=openBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!ADXAllowsEntry(testType)) return false;
   double ctDist=(Inp_CTMode==CT_ATR_DISTANCE)?m_mkt.atr*Inp_CTDistanceATR:Inp_CTFixedPoints*_Point;
   MqlTick t; if(!GetTick(t)) return false;
   if(ctDist>0){
      if(openBuy&&m_lastCTBuyPrice>0&&MathAbs(t.ask-m_lastCTBuyPrice)<ctDist) return false;
      if(openSell&&m_lastCTSellPrice>0&&MathAbs(t.bid-m_lastCTSellPrice)<ctDist) return false;
   }
   ctLevel=openBuy?buyCount:sellCount; ctLot=CalcLot(ctLevel);
   ctType=openBuy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine()
{
   if(m_isProcessing||m_isPaused||m_emergencyMode||m_cycleInPause) return;
   if(TimeCurrent()-m_lastCTTime<Inp_CTIntervalSec) return;
   m_lastCTTime=TimeCurrent();
   MqlTick ts; if(!GetTick(ts)) return;
   double maxSpr=m_inSession?(double)Inp_MaxSpread:Inp_CTMaxSpreadOff;
   if((ts.ask-ts.bid)/_Point>maxSpr) return;

   if(m_port.totalPos==0){
      if(!m_sensors.allOK){
         static datetime lastSL=0;
         if(TimeCurrent()-lastSL>=60){
            Print("[AQ V8.0.0-FSM] ENTRADA BLOQUEADA: ", m_sensors.blockReason);
            lastSL=TimeCurrent();
         }
         return; 
      }
      if(m_stormActive) return;
      int cooldown=m_inSession?Inp_PrimaryCooldownSec:Inp_PrimaryCooldownOff;
      if(TimeCurrent()-m_lastPrimaryTime<cooldown) return;

      ENUM_ORDER_TYPE initType;
      if(m_mkt.trendConfirmed==1)         initType=ORDER_TYPE_BUY;
      else if(m_mkt.trendConfirmed==-1)   initType=ORDER_TYPE_SELL;
      else if(m_mkt.isBullish)            initType=ORDER_TYPE_BUY;
      else if(m_mkt.isBearish)            initType=ORDER_TYPE_SELL;
      else if(m_mkt.emaFast>m_mkt.emaSlow) initType=ORDER_TYPE_BUY;
      else                                initType=ORDER_TYPE_SELL;

      if(m_lastPrimaryLost&&m_lastPrimaryDir!=0){
         ENUM_ORDER_TYPE alt=(m_lastPrimaryDir==1)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
         if(initType!=alt){initType=alt;m_lastPrimaryLost=false;}
      }
      if(!ADXAllowsEntry(initType)||!TrendFilter200OK(initType)) return;
      if(!m_inSession){bool cs=(m_mkt.isBullish&&initType==ORDER_TYPE_BUY)||(m_mkt.isBearish&&initType==ORDER_TYPE_SELL);if(!cs)return;}

      double lot=NormLot(Inp_LotBase);
      m_isProcessing=true;
      ulong ticket=OpenOrder(initType,lot,"Primary_Entry");
      if(ticket>0){
         int idx=FreeRec();
         if(idx>=0){int pt=(initType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(initType==ORDER_TYPE_BUY)?ts.ask:ts.bid;InitRec(idx,ticket,pt,op,lot,"Primary_Entry",true,false,false,false);}
         m_lastPrimaryDir=(initType==ORDER_TYPE_BUY)?1:-1;
         m_lastPrimaryTime=TimeCurrent();
         m_primaryOpenTime=TimeCurrent();
         if(initType==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask; else m_lastCTSellPrice=ts.bid;
         m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
         m_blockStage=1;m_primaryType=initType;m_stageFollowHedge=false;
         m_stage1TriggerAtOpen=m_dyn.stage1Trigger;
         m_stage3TriggerAtOpen=m_dyn.stage3Trigger;
         m_detangleDetectTime=0;m_detangleActive=false;
         DeactivateLBC();
      }
      m_isProcessing=false;
      return;
   }

   if(m_blockStage>0) return; 

   ENUM_ORDER_TYPE ctType; double ctLot; int ctLevel;
   if(!ShouldOpenCT(ctType,ctLot,ctLevel)||!MarginOK(ctLot,ctType)) return;
   string ctComm="CT_"+(ctType==ORDER_TYPE_BUY?"B":"S")+"_L"+IntegerToString(ctLevel+1);
   m_isProcessing=true; ulong ticket=OpenOrder(ctType,ctLot,ctComm); m_isProcessing=false;
   if(ticket>0){
      int idx=FreeRec();
      if(idx>=0){int pt=(ctType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(ctType==ORDER_TYPE_BUY)?ts.ask:ts.bid;InitRec(idx,ticket,pt,op,ctLot,ctComm,false,true,false,false);}
      if(ctType==ORDER_TYPE_BUY)m_lastCTBuyPrice=ts.ask; else m_lastCTSellPrice=ts.bid;
   }
}

//=================================================================
//  NET EXPOSURE HEDGE
//=================================================================
void RunNetExposureHedge()
{
   if(!Inp_UseNetHedge||m_port.totalPos==0||m_isProcessing) return;
   double netVol=NormalizeDouble(m_port.buyVolume-m_port.sellVolume,2);
   if(MathAbs(netVol)<0.005) return;
   
   double loss=m_port.totalProfit;
   if(loss>m_dyn.netHedgeTrig1) return;
   if(TimeCurrent()-m_lastNetHedgeTime<Inp_NetHedgeIntervalSec||!SpreadOK()) return;
   
   ENUM_ORDER_TYPE hedgeType=(netVol>0)?ORDER_TYPE_SELL:ORDER_TYPE_BUY;
   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if (volStep <= 0) volStep = 0.01;

   if(loss<=m_dyn.netHedgeTrig2&&!m_netHedge2Applied){
      double pct=m_netHedge1Applied?0.50:0.0;
      double hedgeLot=NormLot(MathAbs(netVol)*(1.0-pct));
      
      if(hedgeLot>0) {
         if(!AntiSymmetricOK(hedgeType, hedgeLot)) {
            hedgeLot = NormLot(hedgeLot + volStep);
         }
         
         if(MarginOK_Hedge(hedgeLot,hedgeType)){
            m_isProcessing=true;ulong ticket=OpenOrder(hedgeType,hedgeLot,"NET_HEDGE_L2",true);m_isProcessing=false;
            if(ticket>0){m_netHedge2Applied=m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();
               MqlTick tk;GetTick(tk);int idx=FreeRec();
               if(idx>=0){int pt=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,hedgeLot,"NET_HEDGE_L2",false,false,true,false);}
            }
         }
      }
      return;
   }
   
   if(loss<=m_dyn.netHedgeTrig1&&!m_netHedge1Applied){
      double hedgeLot=NormLot(MathAbs(netVol)*0.50);
      
      if(hedgeLot>0) {
         if(!AntiSymmetricOK(hedgeType, hedgeLot)) {
            hedgeLot = NormLot(hedgeLot + volStep);
         }

         if(MarginOK_Hedge(hedgeLot,hedgeType)){
            m_isProcessing=true;ulong ticket=OpenOrder(hedgeType,hedgeLot,"NET_HEDGE_L1",true);m_isProcessing=false;
            if(ticket>0){m_netHedge1Applied=true;m_lastNetHedgeTime=TimeCurrent();
               MqlTick tk;GetTick(tk);int idx=FreeRec();
               if(idx>=0){int pt=(hedgeType==ORDER_TYPE_BUY)?POSITION_TYPE_BUY:POSITION_TYPE_SELL;double op=(hedgeType==ORDER_TYPE_BUY)?tk.ask:tk.bid;InitRec(idx,ticket,pt,op,hedgeLot,"NET_HEDGE_L1",false,false,true,false);}
            }
         }
      }
   }
}

//=================================================================
//  VOLATILITY STORM FILTER
//=================================================================
double CalcAvgATR(int wb)
{
   if(wb<=0||h_ATR==INVALID_HANDLE) return 0;
   double buf[];ArraySetAsSeries(buf,true);
   if(CopyBuffer(h_ATR,0,1,wb,buf)<wb) return 0;
   double s=0;for(int i=0;i<wb;i++)s+=buf[i];return s/wb;
}
double CalcAvgSpread(int wb)
{
   if(wb<=0) return(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   MqlRates r[];ArraySetAsSeries(r,true);
   if(CopyRates(_Symbol,PERIOD_M1,1,wb,r)<wb) return(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   double s=0;for(int i=0;i<wb;i++)s+=(r[i].high-r[i].low)/_Point;return s/wb;
}
void RunVolatilityStormFilter()
{
   if(!Inp_UseStormFilter){m_stormActive=false;return;}
   double atrNow=m_mkt.atr; if(atrNow<=0) return;
   double atrAvg=CalcAvgATR(Inp_StormATRWindow); bool atrStorm=false;
   if(atrAvg>0){m_stormLastATRRatio=atrNow/atrAvg;atrStorm=(m_stormLastATRRatio>=Inp_StormATRMult);}
   double sprNow=(double)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);
   double sprAvg=CalcAvgSpread(Inp_StormSpreadWindow); bool sprStorm=false;
   if(sprAvg>0){m_stormLastSprRatio=sprNow/sprAvg;sprStorm=(sprNow/(double)MathMax(Inp_MaxSpread,1)>Inp_StormSpreadMult*0.5);}
   bool stormNow=(atrStorm||sprStorm);
   if(stormNow&&!m_stormActive){m_stormActive=true;m_stormDetectedTime=TimeCurrent();}
   if(m_stormActive){if(TimeCurrent()-m_stormDetectedTime>=Inp_StormCooldownSec){if(!stormNow){m_stormActive=false;}else m_stormDetectedTime=TimeCurrent();}}
}

ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   if((bool)MQLInfoInteger(MQL_TESTER)) return ORDER_FILLING_RETURN;
   long filling=SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE);
   if((filling&SYMBOL_FILLING_FOK)!=0) return ORDER_FILLING_FOK;
   if((filling&SYMBOL_FILLING_IOC)!=0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//=================================================================
//  MÉTODOS FSM (NUEVOS)
//=================================================================
void ManageEmergencyState()
{
   static datetime emgTime=0;
   UpdatePortfolio();
   if(m_port.totalPos>0&&m_port.totalProfit>=m_dyn.blockTP){
      CloseBlockIfPositive("Emergency_TP");
      m_emergencyMode=false;
      emgTime=0;
   }
   if(m_port.totalPos==0&&emgTime==0) emgTime=TimeCurrent();
   
   if(emgTime>0&&TimeCurrent()-emgTime>=Inp_EmergencyCooldown){
      m_emergencyMode=false;
      m_isPaused=false;
      emgTime=0;
      Print("[AQ V8.0.0-FSM] SISTEMA REINICIADO TRAS HARD STOP.");
   }
}

void ManageCyclePauseState()
{
   if(TimeCurrent()-m_cycleResetTime>=Inp_CyclePauseSec){
      m_cycleInPause=false;
      m_recoveryActive=false;m_recoveryOrders=0;m_recoveryTrendHedge=false;
      m_blockStage=0;m_stageFollowHedge=false;m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
      m_detangleDetectTime=0;m_detangleActive=false;m_primaryOpenTime=0;
      DeactivateLBC();
   } else {
      UpdatePortfolio();
      if(m_port.totalPos>0&&m_port.totalProfit>=m_dyn.blockTP) CloseBlockIfPositive("CyclePause_TP");
   }
}

void UpdateStateMachine()
{
   if(m_emergencyMode) { 
      m_currentState = STATE_EMERGENCY; 
   } else if(m_cycleInPause) { 
      m_currentState = STATE_CYCLE_PAUSE; 
   } else if(m_port.totalPos == 0) { 
      m_currentState = STATE_IDLE; 
   } else if(m_lbc.active) { 
      m_currentState = STATE_LBC_CONTINGENCY; 
   } else if(m_recoveryActive) { 
      m_currentState = STATE_BSE_RECOVERY; 
   } else { 
      m_currentState = STATE_PRIMARY_TRADING; 
   }
}

//=================================================================
//  OnInit
//=================================================================
int OnInit()
{
   m_trade.SetExpertMagicNumber(Inp_Magic);m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);m_trade.SetTypeFilling(DetectFillingMode());
   h_ATR=iATR(_Symbol,PERIOD_M1,Inp_ATRPeriod);
   h_EMAFast=iMA(_Symbol,PERIOD_M1,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_EMASlow=iMA(_Symbol,PERIOD_M1,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_RSI=iRSI(_Symbol,PERIOD_M1,Inp_RSIPeriod,PRICE_CLOSE);
   h_MACD=iMACD(_Symbol,PERIOD_M1,Inp_MACDFast,Inp_MACDSlow,Inp_MACDSig,PRICE_CLOSE);
   if(h_ATR==INVALID_HANDLE||h_EMAFast==INVALID_HANDLE||h_EMASlow==INVALID_HANDLE||h_RSI==INVALID_HANDLE||h_MACD==INVALID_HANDLE){return INIT_FAILED;}
   h_ADX=iADX(_Symbol,PERIOD_M1,Inp_ADXPeriod);
   h_HTFEMAFast=iMA(_Symbol,Inp_HTFTF,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_HTFEMASlow=iMA(_Symbol,Inp_HTFTF,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_EMA200=iMA(_Symbol,PERIOD_M1,Inp_EMA200Period,0,MODE_EMA,PRICE_CLOSE);
   h_ATRSlow=iATR(_Symbol,PERIOD_M1,Inp_ATRSlowPeriod);
   for(int i=0;i<MAX_RECORDS;i++) ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc);ZeroMemory(m_sensors);ZeroMemory(m_mkt);ZeroMemory(m_dyn);
   m_temaF_init=m_temaS_init=m_kalF_init=m_kalS_init=false;
   m_blockStage=0;m_stageFollowHedge=false;m_primaryOpenTime=0;
   m_stage1TriggerAtOpen=m_stage3TriggerAtOpen=0;
   m_detangleDetectTime=0;m_detangleActive=false;
   m_dyn.stage1Trigger=Inp_Stage1Trigger;m_dyn.stage3Trigger=Inp_Stage3Trigger;
   m_dyn.blockTP=Inp_BlockTPTarget;m_dyn.recovTrigger=Inp_RecoveryTriggerUSD;
   m_dyn.stage2Delay=Inp_Stage2DelayLondon;m_dyn.recovDistATR=Inp_RecovDistNormal;
   m_dyn.netHedgeTrig1=Inp_NetHedgeTrigger1USD;m_dyn.netHedgeTrig2=Inp_NetHedgeTrigger2USD;
   m_dyn.sessionFactor=1.0;m_dyn.session=SESSION_OFF;m_dyn.volRegime=VOL_NORMAL;m_dyn.atr2usd=0;
   m_initialBalance=AccountInfoDouble(ACCOUNT_BALANCE);m_bestEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance=m_initialBalance;m_lastDailyReset=TimeCurrent();
   CalcBrokerTimeWindow();SyncPositions();UpdatePortfolio();
   m_currentState = STATE_INIT;
   if(m_port.lbcCount>0){m_lbc.active=true;m_lbc.activatedTime=TimeCurrent();m_lbc.maxOrdersCalc=Inp_LBCMaxPairs;}
   Print("[AQ V8.0.0-FSM] EA INITIALIZED & READY - CENTRALIZED FSM ENABLED");
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   IndicatorRelease(h_ATR);IndicatorRelease(h_EMAFast);IndicatorRelease(h_EMASlow);
   IndicatorRelease(h_RSI);IndicatorRelease(h_MACD);
   if(h_ADX!=INVALID_HANDLE)IndicatorRelease(h_ADX);
   if(h_HTFEMAFast!=INVALID_HANDLE)IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow!=INVALID_HANDLE)IndicatorRelease(h_HTFEMASlow);
   if(h_EMA200!=INVALID_HANDLE)IndicatorRelease(h_EMA200);
   if(h_ATRSlow!=INVALID_HANDLE)IndicatorRelease(h_ATRSlow);
}

//=================================================================
//  OnTick (REESCRITO CON FSM)
//=================================================================
void OnTick()
{
   m_tickCount++;
   
   // 1. Recolección de Datos Global
   UpdateMarket();
   UpdateKalman();
   UpdatePortfolio();
   CheckEquityGuard(); // La seguridad se evalúa antes de procesar la FSM
   
   m_inSession = IsInMainSession();
   ResetDailyIfNeeded();
   bool dailyPaused = DailyLimitReached();
   
   UpdateSensors();
   RunVolatilityStormFilter();

   // 2. Transición y Determinación de Estado
   UpdateStateMachine();

   // Salida Global Segura (TP) para estados en Trading Activo
   if(m_currentState != STATE_EMERGENCY && m_currentState != STATE_CYCLE_PAUSE) {
       if(m_port.totalPos > 0 && m_port.totalProfit >= m_dyn.blockTP) {
           CloseBlockIfPositive("BlockTP");
           return; // El ciclo termina, el estado volverá a IDLE en el próximo tick
       }
   }
   
   // 3. Ejecución Aislada por Estado (FSM)
   switch(m_currentState)
   {
      case STATE_EMERGENCY:
         ManageEmergencyState();
         break;

      case STATE_CYCLE_PAUSE:
         ManageCyclePauseState();
         break;

      case STATE_IDLE:
         if(TimeCurrent()-m_lastCleanupTime>5){CleanupRecs();SyncPositions();m_lastCleanupTime=TimeCurrent();}
         // Solo busca nuevas entradas de ciclo primario cuando no hay posiciones en curso
         if(!m_isPaused && !dailyPaused) RunCTEngine();
         break;

      case STATE_PRIMARY_TRADING:
         RunBasketTP();
         RunDetangle();
         RunNetExposureHedge(); // La cobertura neta se permite en trading primario
         RunBlockStageEngine(); // BSE puede escalar esto a STATE_BSE_RECOVERY o STATE_LBC
         RunHarvest();
         CheckCycleMaxLoss(); // Transición a RECOVERY si falla el límite normal
         break;

      case STATE_BSE_RECOVERY:
         RunBasketTP();
         RunDetangle();
         // En recuperación agresiva, APAGAMOS el NetHedge para evitar secuestro de margen
         RunRecoveryEngine();
         break;

      case STATE_LBC_CONTINGENCY:
         // Margen crítico. Exclusividad para recolección LBC.
         RunHarvest();
         RunLBCEngine();
         break;
   }
   
   ManagePositions();
}
//+------------------------------------------------------------------+