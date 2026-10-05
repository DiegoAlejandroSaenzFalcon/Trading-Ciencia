//+------------------------------------------------------------------+
//|                                                        Multi.mq5 |
//|                                      Apex-X Quantum Architecture |
//|                             Diseñado para Pepperstone Razor ECN  |
//+------------------------------------------------------------------+
#include <Core_Structs.mqh>
#include <Core_Sensor.mqh>
#include <Quantum_Engine.mqh>
#include <Risk_Protocol.mqh>
#include <Execution_Module.mqh>

//===================================================================
// PARÁMETROS DE USUARIO (PANEL DE CONTROL)
//===================================================================
input group "=== 1. MOTOR DE SENSORES (Zero-Lag) ==="
input int    Inp_TemaPeriod  = 9;       // Periodo TEMA
input double Inp_KalmanQ     = 0.05;    // Ruido de Proceso (Velocidad)
input double Inp_KalmanR     = 0.50;    // Ruido de Medición (Suavizado)

input group "=== 2. CEREBRO CUÁNTICO (Decisión) ==="
input double Inp_SlopeThresh = 0.00015; // Inclinación Mínima (Fuerza)
input double Inp_VolRatio    = 1.5;     // Ratio de Volatilidad (Ruptura ATR)
input double Inp_DxyThresh   = 0.0;     // Divergencia USD (0 = desactivado por ahora)

input group "=== 3. PROTOCOLO DE RIESGO (Razor) ==="
input double Inp_RiskPercent = 1.0;     // Riesgo por operación (%)
input double Inp_SlMultiplier= 1.5;     // Multiplicador de SL en ATR
input ulong  Inp_MagicNumber = 777999;  // ID Único del Robot

//===================================================================
// PUNTEROS A LOS MÓDULOS (La Orquesta)
//===================================================================
CSensorEngine    *Sensor   = NULL;
CQuantumEngine   *Cerebro  = NULL;
CRiskManager     *Riesgo   = NULL;
CExecutionModule *Gatillo  = NULL;

// Manejadores de indicadores (Handles)
int h_atr_fast = INVALID_HANDLE;
int h_atr_slow = INVALID_HANDLE;

//===================================================================
// INICIALIZACIÓN (Encendido de Turbinas)
//===================================================================
int OnInit()
  {
   Print(">>> INICIANDO APEX-X QUANTUM ENGINE <<<");
   
   // 1. Inicializar Handles de Volatilidad
   h_atr_fast = iATR(_Symbol, PERIOD_CURRENT, 7);
   h_atr_slow = iATR(_Symbol, PERIOD_CURRENT, 21);
   
   if(h_atr_fast == INVALID_HANDLE || h_atr_slow == INVALID_HANDLE)
     {
      Print("Error crítico: No se pudieron cargar los sensores ATR.");
      return(INIT_FAILED);
     }

   // 2. Instanciar los Módulos OOP
   Sensor  = new CSensorEngine(Inp_TemaPeriod, Inp_KalmanQ, Inp_KalmanR);
   Cerebro = new CQuantumEngine(Inp_SlopeThresh, Inp_VolRatio, Inp_DxyThresh);
   Riesgo  = new CRiskManager(Inp_RiskPercent, Inp_SlMultiplier);
   Gatillo = new CExecutionModule(Inp_MagicNumber, _Symbol);

   Print("Sistemas Ensamblados: Sensores [OK] Cerebro [OK] Riesgo [OK] Ejecución [OK]");
   return(INIT_SUCCEEDED);
  }

//===================================================================
// DESCONEXIÓN (Apagado Seguro)
//===================================================================
void OnDeinit(const int reason)
  {
   Print(">>> APAGANDO APEX-X QUANTUM <<<");
   
   // Liberar memoria para evitar Memory Leaks
   if(Sensor != NULL)  delete Sensor;
   if(Cerebro != NULL) delete Cerebro;
   if(Riesgo != NULL)  delete Riesgo;
   if(Gatillo != NULL) delete Gatillo;
   
   IndicatorRelease(h_atr_fast);
   IndicatorRelease(h_atr_slow);
  }

//===================================================================
// MOTOR PRINCIPAL (El Latido Quántico Tick-a-Tick)
//===================================================================
void OnTick()
  {
   // 1. Evitar operar si ya hay posiciones abiertas de este EA (Modo Mono-Posición Estricto)
   if(PositionsTotal() > 0)
     {
      // Aquí irá posteriormente el módulo de Trailing Stop y Cierre
      return; 
     }

   // 2. Captura de Datos de Mercado (Crear el "Snapshot")
   MarketSnap snap;
   ZeroMemory(snap);
   
   snap.ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   snap.bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   snap.spread_points = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   snap.tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   // Leer Volatilidad
   double atr_f[1], atr_s[1];
   if(CopyBuffer(h_atr_fast, 0, 0, 1, atr_f) > 0) snap.atr_fast = atr_f[0];
   if(CopyBuffer(h_atr_slow, 0, 0, 1, atr_s) > 0) snap.atr_slow = atr_s[0];
   
   snap.dxy_divergence_score = 0.0; // Se conectará externamente después

   // 3. FLUJO DE DATOS CUÁNTICO
   
   // A. Alimentar el Sensor con el Tick actual
   Sensor.ProcessTick(snap);
   
   // B. Consultar al Cerebro
   ENUM_QUANTUM_SIGNAL signal = Cerebro.Evaluate(snap, Sensor);
   
   // C. Si hay Señal, gestionar Riesgo y Ejecutar
   if(signal != Q_WAIT)
     {
      // Evaluar si podemos pagar el costo del spread + SL
      RiskProfile profile = Riesgo.CalculateRisk(snap);
      
      if(profile.dynamic_lot > 0)
        {
         // Apretar el Gatillo
         Gatillo.ExecuteQuantumSignal(signal, profile);
        }
     }
  }
//+------------------------------------------------------------------+