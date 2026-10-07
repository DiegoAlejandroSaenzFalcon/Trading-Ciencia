//+------------------------------------------------------------------+
//|                                                     NeurAlgo.mq5 |
//|                                      Apex-X Quantum Architecture |
//|                                 Professional Grade Implementation |
//+------------------------------------------------------------------+
#property copyright "NeurAlgo Institutional - Diego Alejandro Saenz Falcon"
#property version   "1.00"
#property strict

//--- Inclusión de módulos core (Sintaxis MQL5 nativa)
#include <Core_Structs.mqh>
#include <Core_Sensor.mqh>
#include <Execution_Module.mqh>
#include <Risk_Protocol.mqh>

//--- Parámetros de Entrada (Basados en investigación de volatilidad XAUUSD)
input group "=== TEMA + KALMAN CONFIG ==="
input int    Inp_TEMAPeriod    = 9;      // Triple EMA para reducción de lag 
input double Inp_KalmanQ       = 0.05;   // Ruido de proceso (Reactividad) 
input double Inp_KalmanR       = 0.5;    // Ruido de medición (Suavizado) 
input double Inp_SlopeThresh   = 0.0001; // Umbral de inclinación para confirmación 

input group "=== RISK & EXECUTION (Pepperstone Razor) ==="
input double Inp_RiskPct       = 1.0;    // Riesgo dinámico (%) 
input double Inp_SL_ATR_Mult   = 1.2;    // Multiplicador ATR para Stop Loss virtual 
input ulong  Inp_Magic         = 112233; // Identificador único NeurAlgo
input int    Inp_MaxSpread     = 25;     // Max spread en puntos (Razor normal: 3-15) 

//--- Instancias Globales
CSensorEngine    *g_sensor = NULL;
CExecutionModule *g_exec   = NULL;
CRiskManager     *g_risk   = NULL;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // Asignación dinámica de memoria (MQL5 OOP)
   g_sensor = new CSensorEngine(Inp_TEMAPeriod, Inp_KalmanQ, Inp_KalmanR);
   g_exec   = new CExecutionModule(Inp_Magic, _Symbol);
   g_risk   = new CRiskManager(Inp_RiskPct, Inp_SL_ATR_Mult);

   if(CheckPointer(g_sensor) == POINTER_INVALID || 
      CheckPointer(g_exec) == POINTER_INVALID || 
      CheckPointer(g_risk) == POINTER_INVALID)
     {
      Print("[NEURALGO ERROR] Fallo crítico de memoria.");
      return(INIT_FAILED);
     }

   Print("[NEURALGO] Sistema iniciado para XAUUSD en Pepperstone.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(CheckPointer(g_sensor) != POINTER_INVALID) delete g_sensor;
   if(CheckPointer(g_exec)   != POINTER_INVALID) delete g_exec;
   if(CheckPointer(g_risk)   != POINTER_INVALID) delete g_risk;
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // 1. Snapshot de mercado (Filtro de Spread Crítico V7.7.1)
   int curSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD); // 
   if(curSpread > Inp_MaxSpread) return;

   MarketSnap snap;
   snap.ask           = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   snap.bid           = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   snap.spread_points = curSpread;
   snap.tick_value    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   // Obtener ATR para el cálculo de volatilidad (Copiando buffers de indicadores)
   // Se asume la existencia de handles configurados o acceso directo
   snap.atr_fast = GetATR(14); // Basado en Inp_ATRPeriod 
   snap.atr_slow = GetATR(100);

   // 2. Procesamiento Analítico (CSensorEngine)
   // En MQL5 los punteros acceden a métodos con PUNTO 
   g_sensor.ProcessTick(snap);
   double currentSlope = g_sensor.GetSlope();

   // 3. Gestión de Riesgo (CRiskManager)
   RiskProfile risk = g_risk.CalculateRisk(snap);
   
   // Validación de margen para cuentas pequeñas ($100 compatible) 
   double marginReq = 0;
   if(OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, risk.dynamic_lot, snap.ask, marginReq))
     {
      if(marginReq > AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.95) return; // FIX 1 
     }

   // 4. Ejecución (CExecutionModule)
   if(PositionsTotal() == 0) // Lógica simplificada para entrada primaria
     {
      if(currentSlope > Inp_SlopeThresh)
         g_exec.ExecuteQuantumSignal(Q_BUY_XAU, risk);
      else if(currentSlope < -Inp_SlopeThresh)
         g_exec.ExecuteQuantumSignal(Q_SELL_XAU, risk);
     }
  }

//+------------------------------------------------------------------+
//| Helper: Obtener valor ATR de buffers                             |
//+------------------------------------------------------------------+
double GetATR(int period)
  {
   int handle = iATR(_Symbol, PERIOD_CURRENT, period);
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, 0, 1, buffer) > 0) return buffer[0];
   return 0.0;
  }