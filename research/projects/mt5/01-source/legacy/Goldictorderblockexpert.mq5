//+------------------------------------------------------------------+
//|                                      GoldICTOrderBlockExpert.mq5 |
//|              Replica fiel de Gold ICT OrderBlock Expert           |
//|   XAUUSD M6 | Liquidity Sweep | Market Structure Shift | OB      |
//+------------------------------------------------------------------+
#property copyright   "Replica Gold ICT OrderBlock Expert"
#property link        ""
#property version     "1.00"
#property description "XAUUSD M6 | Liquidity Sweep + MSS + Order Block Retest | Metodología ICT pura"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs: Temporalidades ICT
input group              "=== TEMPORALIDADES ICT ==="
input ENUM_TIMEFRAMES InpEntryTF     = PERIOD_M5;  // TF entrada (M5 - ICT ejecución)
input ENUM_TIMEFRAMES InpContextTF   = PERIOD_H1;  // TF contexto superior
input ENUM_TIMEFRAMES InpBiasTF      = PERIOD_H4;  // TF sesgo diario

//--- Inputs: Gestión de Riesgo
input group              "=== GESTIÓN DE RIESGO ==="
input double   InpRiskPercent        = 1.0;   // Riesgo % por operación
input int      InpMaxTrades          = 1;     // Máximo de operaciones (disciplina ICT)
input double   InpRRMin              = 2.0;   // R:R mínimo para entrar
input double   InpMaxDDPct           = 10.0;  // Drawdown máximo (%)

//--- Inputs: Liquidity Sweep (Barrido de Liquidez)
input group              "=== LIQUIDITY SWEEP ==="
input int      InpSweepLookback      = 20;    // Velas atrás para nivel de liquidez
input double   InpSweepMinPips       = 3.0;   // Barrido mínimo más allá del nivel (pips)
input int      InpSweepConfirmBars   = 2;     // Velas para confirmar el rechazo tras barrido
input bool     InpRequirePDArray     = true;  // Requerir nivel PDH/PDL/PWH/PWL barrido

//--- Inputs: Market Structure Shift (MSS)
input group              "=== MARKET STRUCTURE SHIFT ==="
input int      InpMSSSwingBars       = 8;     // Barras para identificar swing MSS
input double   InpMSSMinBodyPips     = 2.0;   // Cuerpo mínimo vela MSS (pips)
input bool     InpMSSRequireFVG      = true;  // MSS debe dejar FVG (Fair Value Gap)

//--- Inputs: Order Block ICT
input group              "=== ORDER BLOCK ICT ==="
input int      InpOBSearchBars       = 30;    // Barras atrás para buscar OB
input double   InpOBMinSize          = 1.5;   // Tamaño mínimo OB (pips)
input double   InpOBEntryPct         = 0.25;  // Entrada en % del OB (0=base, 1=tope)
input double   InpOBInvalidBuffer    = 0.5;   // Buffer invalidación OB (pips)
input bool     InpUseBreaker         = true;  // Convertir OB fallido en Breaker Block
input bool     InpUseMitigation      = true;  // Validar mitigación del OB
input double   InpOBMitigationPct    = 0.5;   // % del OB que debe ser mitigado (0.5 = 50%)

//--- Inputs: ATR y SL/TP
input group              "=== SL / TP ==="
input int      InpATRPeriod          = 14;    // Período ATR
input double   InpATRSLMulti         = 1.0;   // Multiplicador ATR para SL (adicional al OB)
input double   InpATRTPMulti         = 3.0;   // Multiplicador ATR para TP
input bool     InpUseTrailing        = true;  // Trailing Stop
input double   InpTrailATRMulti      = 1.2;   // Multiplicador ATR Trailing

//--- Inputs: Sesiones ICT (Killzones)
input group              "=== SESIONES ICT ==="
input bool     InpUseKillzones       = true;  // Solo operar en Killzones
input int      InpLondonKZStart      = 8;     // Londres KZ inicio (GMT)
input int      InpLondonKZEnd        = 11;    // Londres KZ fin (GMT)
input int      InpNYKZStart          = 13;    // NY KZ inicio (GMT)
input int      InpNYKZEnd            = 16;    // NY KZ fin (GMT)
input int      InpLondonOpenKZ       = 2;     // London Open KZ (GMT+0) - Mercado Asia
input int      InpLondonOpenKZEnd    = 5;     // London Open KZ fin (GMT)

//--- Inputs: Niveles PD Array (Previous Day/Week)
input group              "=== PD ARRAYS ==="
input bool     InpUsePDLevels        = true;  // Usar niveles PD Array
input bool     InpUsePDH             = true;  // Previous Day High
input bool     InpUsePDL             = true;  // Previous Day Low
input bool     InpUsePWH             = true;  // Previous Week High
input bool     InpUsePWL             = true;  // Previous Week Low
input bool     InpUsePMH             = false; // Previous Month High
input bool     InpUsePML             = false; // Previous Month Low

//--- Inputs: Config
input group              "=== CONFIGURACIÓN ==="
input ulong    InpMagic              = 20240706;  // Magic Number
input int      InpSlippage           = 10;        // Slippage (puntos)
input bool     InpPrintLogs          = true;      // Logs detallados ICT

//--- Estructuras ICT
struct SICTOrderBlock
{
   double   high;
   double   low;
   double   mid;
   datetime time;
   int      direction;        // 1=demanda, -1=oferta
   bool     mitigated;
   bool     isBreakerBlock;   // OB fallido convertido en Breaker
   double   fvgUpper;         // FVG asociado (si existe)
   double   fvgLower;
   bool     hasFVG;
};

struct SLiquiditySweep
{
   bool     detected;
   double   level;            // Nivel barrido
   int      direction;        // 1=barrido alcista (stop hunt bajista), -1=barrido bajista
   datetime time;
   double   sweepExtension;   // Cuánto barrió el precio
   bool     rejected;         // ¿El precio regresó?
   int      pdArrayType;      // 0=swing, 1=PDH, 2=PDL, 3=PWH, 4=PWL
};

struct SMSSEvent
{
   bool     detected;
   int      direction;        // 1=alcista, -1=bajista
   datetime time;
   double   breakLevel;
   bool     hasFVG;
   double   fvgUpper;
   double   fvgLower;
};

struct SPDArray
{
   double pdh, pdl;   // Previous Day H/L
   double pwh, pwl;   // Previous Week H/L
   double pmh, pml;   // Previous Month H/L
};

//--- Variables globales
CTrade        trade;
CPositionInfo posInfo;

int    handleATR_Entry, handleATR_Context;
int    handleEMA_H4;

double pipSize;
datetime lastBarEntry = 0;
double   peakBalance  = 0.0;

SICTOrderBlock  bullOB, bearOB;
SLiquiditySweep liquidSweep;
SMSSEvent       mssEvent;
SPDArray        pdLevels;

//+------------------------------------------------------------------+
//| Inicialización                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Symbol != "XAUUSD" && _Symbol != "XAUUSDm" && _Symbol != "GOLD" && _Symbol != "GOLDm")
      Print("[ICT_OB] ADVERTENCIA: Diseñado para XAUUSD. Actual: ", _Symbol);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;

   handleATR_Entry   = iATR(_Symbol, InpEntryTF,   InpATRPeriod);
   handleATR_Context = iATR(_Symbol, InpContextTF,  InpATRPeriod);
   handleEMA_H4      = iMA(_Symbol,  InpBiasTF, 20, 0, MODE_EMA, PRICE_CLOSE);

   if(handleATR_Entry == INVALID_HANDLE || handleATR_Context == INVALID_HANDLE ||
      handleEMA_H4    == INVALID_HANDLE)
   {
      Print("[ICT_OB] ERROR: Fallo al crear indicadores.");
      return INIT_FAILED;
   }

   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   ZeroMemory(bullOB);
   ZeroMemory(bearOB);
   ZeroMemory(liquidSweep);
   ZeroMemory(mssEvent);
   ZeroMemory(pdLevels);

   Print("[ICT_OB] Gold ICT OrderBlock Expert inicializado. TF:", EnumToString(InpEntryTF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Liberación                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR_Entry);
   IndicatorRelease(handleATR_Context);
   IndicatorRelease(handleEMA_H4);
}

//+------------------------------------------------------------------+
//| Tick principal                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // Control drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > peakBalance) peakBalance = bal;
   if(peakBalance > 0.0 && (peakBalance - equity) / peakBalance * 100.0 >= InpMaxDDPct)
   {
      CloseAllMyPositions();
      return;
   }

   // Trailing ATR
   if(InpUseTrailing) ManageTrailingATR();

   // Solo nueva vela del TF de entrada
   if(!IsNewBar()) return;

   // Filtro Killzone ICT
   if(InpUseKillzones && !IsInICTKillzone()) return;

   // Máximo de operaciones
   if(CountMyPositions() >= InpMaxTrades) return;

   // Actualizar PD Arrays
   if(InpUsePDLevels) UpdatePDArrays();

   // PASO 1: Detectar Liquidity Sweep
   DetectLiquiditySweep();

   // PASO 2: Detectar Market Structure Shift (requiere barrido previo)
   if(liquidSweep.detected && liquidSweep.rejected)
      DetectMSS();

   // PASO 3: Detectar Order Block ICT (en el contexto del MSS)
   if(mssEvent.detected)
      FindICTOrderBlock();

   // PASO 4: Evaluar entrada en re-testeo del OB
   EvaluateICTEntry();
}

//+------------------------------------------------------------------+
//| Actualiza niveles PD Array                                        |
//+------------------------------------------------------------------+
void UpdatePDArrays()
{
   // Previous Day High/Low
   double dayHigh = iHigh(_Symbol, PERIOD_D1, 1);
   double dayLow  = iLow(_Symbol,  PERIOD_D1, 1);
   if(InpUsePDH) pdLevels.pdh = dayHigh;
   if(InpUsePDL) pdLevels.pdl = dayLow;

   // Previous Week High/Low
   double wkHigh = iHigh(_Symbol, PERIOD_W1, 1);
   double wkLow  = iLow(_Symbol,  PERIOD_W1, 1);
   if(InpUsePWH) pdLevels.pwh = wkHigh;
   if(InpUsePWL) pdLevels.pwl = wkLow;

   // Previous Month High/Low
   if(InpUsePMH || InpUsePML)
   {
      double mnHigh = iHigh(_Symbol, PERIOD_MN1, 1);
      double mnLow  = iLow(_Symbol,  PERIOD_MN1, 1);
      if(InpUsePMH) pdLevels.pmh = mnHigh;
      if(InpUsePML) pdLevels.pml = mnLow;
   }
}

//+------------------------------------------------------------------+
//| Detecta Barrido de Liquidez (Liquidity Sweep / Stop Hunt)         |
//+------------------------------------------------------------------+
void DetectLiquiditySweep()
{
   ZeroMemory(liquidSweep);

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_Entry, 0, 0, InpSweepLookback + 5, atrBuf) < InpSweepLookback + 5) return;

   double minSweep = InpSweepMinPips * pipSize;
   double atrAvg   = 0.0;
   for(int k = 2; k <= 10; k++) atrAvg += atrBuf[k];
   atrAvg /= 9.0;

   // Buscar swing high/low en el lookback para luego verificar si fue barrido
   double swH = 0.0, swL = DBL_MAX;
   datetime swHTime = 0, swLTime = 0;
   int swHBar = 0, swLBar = 0;

   for(int i = InpMSSSwingBars + 2; i < InpSweepLookback; i++)
   {
      double h = iHigh(_Symbol, InpEntryTF, i);
      double l = iLow(_Symbol,  InpEntryTF, i);

      bool isSwH = true, isSwL = true;
      for(int j = 1; j <= InpMSSSwingBars / 2; j++)
      {
         if(i - j < 0 || i + j >= Bars(_Symbol, InpEntryTF)) { isSwH = false; isSwL = false; break; }
         if(iHigh(_Symbol, InpEntryTF, i - j) >= h || iHigh(_Symbol, InpEntryTF, i + j) >= h) isSwH = false;
         if(iLow(_Symbol,  InpEntryTF, i - j) <= l || iLow(_Symbol,  InpEntryTF, i + j) <= l) isSwL = false;
      }

      if(isSwH && h > swH) { swH = h; swHTime = iTime(_Symbol, InpEntryTF, i); swHBar = i; }
      if(isSwL && l < swL) { swL = l; swLTime = iTime(_Symbol, InpEntryTF, i); swLBar = i; }
   }
   if(swL == DBL_MAX) swL = 0.0;

   // Comprobar PD Arrays como niveles de liquidez
   double sweepLevel = 0.0;
   int    pdType     = 0;

   // Verificar si algún swing fue barrido recientemente (últimas 3 velas)
   double high1 = iHigh(_Symbol, InpEntryTF, 1);
   double low1  = iLow(_Symbol,  InpEntryTF, 1);
   double high2 = iHigh(_Symbol, InpEntryTF, 2);
   double low2  = iLow(_Symbol,  InpEntryTF, 2);
   double close1 = iClose(_Symbol, InpEntryTF, 1);
   double close2 = iClose(_Symbol, InpEntryTF, 2);

   // Barrido bajista: precio barrió swing high pero cerró abajo (stop hunt alcistas)
   if(swH > 0.0 && high2 > swH && close2 < swH - minSweep * 0.3 && swHBar > 2)
   {
      liquidSweep.detected      = true;
      liquidSweep.level         = swH;
      liquidSweep.direction     = -1;  // Señal bajista tras barrer stops alcistas
      liquidSweep.time          = iTime(_Symbol, InpEntryTF, 2);
      liquidSweep.sweepExtension = high2 - swH;
      liquidSweep.rejected      = (close1 < swH); // Confirmación: precio cerró bajo el nivel
      liquidSweep.pdArrayType   = 0;

      // Verificar si barrió un nivel PD Array
      if(InpUsePDLevels && pdLevels.pdh > 0.0 && MathAbs(swH - pdLevels.pdh) < atrAvg * 0.5)
      { liquidSweep.pdArrayType = 1; liquidSweep.level = pdLevels.pdh; }
      if(InpUsePDLevels && pdLevels.pwh > 0.0 && MathAbs(swH - pdLevels.pwh) < atrAvg * 0.5)
      { liquidSweep.pdArrayType = 3; liquidSweep.level = pdLevels.pwh; }

      if(InpPrintLogs)
         Print("[ICT_OB] Liquidity Sweep BAJISTA detectado @ ", DoubleToString(swH,2),
               " | Extension: ", DoubleToString(liquidSweep.sweepExtension/pipSize,1), " pips",
               " | Rechazado: ", liquidSweep.rejected,
               " | PD Type: ", liquidSweep.pdArrayType);
   }

   // Barrido alcista: precio barrió swing low pero cerró arriba (stop hunt bajistas)
   if(swL > 0.0 && low2 < swL && close2 > swL + minSweep * 0.3 && swLBar > 2)
   {
      liquidSweep.detected      = true;
      liquidSweep.level         = swL;
      liquidSweep.direction     = 1;   // Señal alcista tras barrer stops bajistas
      liquidSweep.time          = iTime(_Symbol, InpEntryTF, 2);
      liquidSweep.sweepExtension = swL - low2;
      liquidSweep.rejected      = (close1 > swL);
      liquidSweep.pdArrayType   = 0;

      if(InpUsePDLevels && pdLevels.pdl > 0.0 && MathAbs(swL - pdLevels.pdl) < atrAvg * 0.5)
      { liquidSweep.pdArrayType = 2; liquidSweep.level = pdLevels.pdl; }
      if(InpUsePDLevels && pdLevels.pwl > 0.0 && MathAbs(swL - pdLevels.pwl) < atrAvg * 0.5)
      { liquidSweep.pdArrayType = 4; liquidSweep.level = pdLevels.pwl; }

      if(InpPrintLogs)
         Print("[ICT_OB] Liquidity Sweep ALCISTA detectado @ ", DoubleToString(swL,2),
               " | Extension: ", DoubleToString(liquidSweep.sweepExtension/pipSize,1), " pips",
               " | Rechazado: ", liquidSweep.rejected,
               " | PD Type: ", liquidSweep.pdArrayType);
   }

   // Filtro PD Array si está requerido
   if(InpRequirePDArray && liquidSweep.detected && liquidSweep.pdArrayType == 0)
      liquidSweep.detected = false;
}

//+------------------------------------------------------------------+
//| Detecta Market Structure Shift (MSS) tras el barrido             |
//+------------------------------------------------------------------+
void DetectMSS()
{
   ZeroMemory(mssEvent);

   double minBody  = InpMSSMinBodyPips * pipSize;

   // MSS Alcista: tras barrido alcista, buscar quiebre de estructura al alza
   if(liquidSweep.direction == 1)
   {
      // Buscar quiebre del swing high más reciente (después del barrido)
      double recentSwH = 0.0;
      for(int i = 1; i < InpMSSSwingBars; i++)
      {
         double h = iHigh(_Symbol, InpEntryTF, i);
         if(h > recentSwH) recentSwH = h;
      }

      double close1  = iClose(_Symbol, InpEntryTF, 1);
      double open1   = iOpen(_Symbol,  InpEntryTF, 1);
      double body1   = close1 - open1;

      if(close1 > recentSwH && body1 >= minBody)
      {
         mssEvent.detected    = true;
         mssEvent.direction   = 1;
         mssEvent.time        = iTime(_Symbol, InpEntryTF, 1);
         mssEvent.breakLevel  = recentSwH;

         // Verificar FVG en la vela del MSS
         double high0  = iHigh(_Symbol, InpEntryTF, 0);
         double low1_v = iLow(_Symbol,  InpEntryTF, 1);
         double high2  = iHigh(_Symbol, InpEntryTF, 2);
         double fvgGap = low1_v - high2;

         if(InpMSSRequireFVG && fvgGap >= InpOBMinSize * pipSize)
         {
            mssEvent.hasFVG    = true;
            mssEvent.fvgUpper  = low1_v;
            mssEvent.fvgLower  = high2;
         }

         if(InpPrintLogs)
            Print("[ICT_OB] MSS ALCISTA | Break @ ", DoubleToString(recentSwH,2),
                  " | FVG: ", mssEvent.hasFVG);
      }
   }

   // MSS Bajista: tras barrido bajista, buscar quiebre de estructura a la baja
   if(liquidSweep.direction == -1)
   {
      double recentSwL = DBL_MAX;
      for(int i = 1; i < InpMSSSwingBars; i++)
      {
         double l = iLow(_Symbol, InpEntryTF, i);
         if(l < recentSwL) recentSwL = l;
      }
      if(recentSwL == DBL_MAX) return;

      double close1 = iClose(_Symbol, InpEntryTF, 1);
      double open1  = iOpen(_Symbol,  InpEntryTF, 1);
      double body1  = open1 - close1;

      if(close1 < recentSwL && body1 >= minBody)
      {
         mssEvent.detected    = true;
         mssEvent.direction   = -1;
         mssEvent.time        = iTime(_Symbol, InpEntryTF, 1);
         mssEvent.breakLevel  = recentSwL;

         double low2   = iLow(_Symbol,  InpEntryTF, 2);
         double high1_ = iHigh(_Symbol, InpEntryTF, 1);
         double fvgGap = low2 - high1_;

         if(InpMSSRequireFVG && fvgGap >= InpOBMinSize * pipSize)
         {
            mssEvent.hasFVG   = true;
            mssEvent.fvgUpper = low2;
            mssEvent.fvgLower = high1_;
         }

         if(InpPrintLogs)
            Print("[ICT_OB] MSS BAJISTA | Break @ ", DoubleToString(recentSwL,2),
                  " | FVG: ", mssEvent.hasFVG);
      }
   }

   // Si MSS requiere FVG pero no lo tiene, invalidar
   if(InpMSSRequireFVG && !mssEvent.hasFVG)
      mssEvent.detected = false;
}

//+------------------------------------------------------------------+
//| Encuentra el Order Block ICT más reciente en dirección del MSS   |
//+------------------------------------------------------------------+
void FindICTOrderBlock()
{
   ZeroMemory(bullOB);
   ZeroMemory(bearOB);

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_Entry, 0, 0, InpOBSearchBars + 5, atrBuf) < InpOBSearchBars + 5) return;

   double atrNow = atrBuf[1];
   double minOB  = InpOBMinSize * pipSize;

   if(mssEvent.direction == 1) // Buscar OB alcista (Demanda)
   {
      for(int i = 2; i < InpOBSearchBars; i++)
      {
         datetime t_i   = iTime(_Symbol,  InpEntryTF, i);
         if(mssEvent.time > 0 && t_i >= mssEvent.time) continue; // OB debe ser ANTES del MSS

         double open_i  = iOpen(_Symbol,  InpEntryTF, i);
         double close_i = iClose(_Symbol, InpEntryTF, i);
         double high_i  = iHigh(_Symbol,  InpEntryTF, i);
         double low_i   = iLow(_Symbol,   InpEntryTF, i);

         // OB Alcista: última vela bajista antes del impulso alcista (MSS)
         if(close_i >= open_i) continue; // Debe ser vela bajista
         double body = open_i - close_i;
         if(body < minOB) continue;

         // Verificar impulso alcista inmediatamente después
         double close_next = iClose(_Symbol, InpEntryTF, i - 1);
         double open_next  = iOpen(_Symbol,  InpEntryTF, i - 1);
         if(close_next <= open_next) continue; // Vela posterior debe ser alcista

         // Verificar que el precio esté actualmente por encima del OB (válido para re-testeo)
         double curPrice = iClose(_Symbol, InpEntryTF, 1);
         if(curPrice <= high_i) continue;

         // Verificar mitigación (precio no ha entrado más del X% en el OB)
         bool mitigated = false;
         if(InpUseMitigation)
         {
            double mitLevel = low_i + (high_i - low_i) * InpOBMitigationPct;
            for(int m = i - 1; m >= 1; m--)
            {
               if(iLow(_Symbol, InpEntryTF, m) < mitLevel)
               { mitigated = true; break; }
            }
         }
         if(mitigated) continue;

         // OB válido encontrado
         bullOB.high      = high_i;
         bullOB.low       = low_i;
         bullOB.mid       = (high_i + low_i) / 2.0;
         bullOB.time      = t_i;
         bullOB.direction = 1;
         bullOB.mitigated = false;

         // Verificar FVG dentro del OB
         double high_prev = iHigh(_Symbol, InpEntryTF, i + 1);
         double low_next2 = iLow(_Symbol,  InpEntryTF, i - 1);
         if(low_next2 > high_prev + minOB * 0.5)
         {
            bullOB.hasFVG   = true;
            bullOB.fvgUpper = low_next2;
            bullOB.fvgLower = high_prev;
         }

         if(InpPrintLogs)
            Print("[ICT_OB] OB Demanda encontrado @ [", DoubleToString(bullOB.low,2),
                  "-", DoubleToString(bullOB.high,2), "] FVG:", bullOB.hasFVG);
         break;
      }
   }

   if(mssEvent.direction == -1) // Buscar OB bajista (Oferta)
   {
      for(int i = 2; i < InpOBSearchBars; i++)
      {
         datetime t_i   = iTime(_Symbol,  InpEntryTF, i);
         if(mssEvent.time > 0 && t_i >= mssEvent.time) continue;

         double open_i  = iOpen(_Symbol,  InpEntryTF, i);
         double close_i = iClose(_Symbol, InpEntryTF, i);
         double high_i  = iHigh(_Symbol,  InpEntryTF, i);
         double low_i   = iLow(_Symbol,   InpEntryTF, i);

         if(close_i <= open_i) continue; // Debe ser vela alcista
         double body = close_i - open_i;
         if(body < minOB) continue;

         double close_next = iClose(_Symbol, InpEntryTF, i - 1);
         double open_next  = iOpen(_Symbol,  InpEntryTF, i - 1);
         if(close_next >= open_next) continue; // Posterior debe ser bajista

         double curPrice = iClose(_Symbol, InpEntryTF, 1);
         if(curPrice >= low_i) continue;

         bool mitigated = false;
         if(InpUseMitigation)
         {
            double mitLevel = high_i - (high_i - low_i) * InpOBMitigationPct;
            for(int m = i - 1; m >= 1; m--)
            {
               if(iHigh(_Symbol, InpEntryTF, m) > mitLevel)
               { mitigated = true; break; }
            }
         }
         if(mitigated) continue;

         bearOB.high      = high_i;
         bearOB.low       = low_i;
         bearOB.mid       = (high_i + low_i) / 2.0;
         bearOB.time      = t_i;
         bearOB.direction = -1;
         bearOB.mitigated = false;

         double low_prev  = iLow(_Symbol,  InpEntryTF, i + 1);
         double high_next = iHigh(_Symbol, InpEntryTF, i - 1);
         if(low_prev > high_next + minOB * 0.5)
         {
            bearOB.hasFVG   = true;
            bearOB.fvgUpper = low_prev;
            bearOB.fvgLower = high_next;
         }

         if(InpPrintLogs)
            Print("[ICT_OB] OB Oferta encontrado @ [", DoubleToString(bearOB.low,2),
                  "-", DoubleToString(bearOB.high,2), "] FVG:", bearOB.hasFVG);
         break;
      }
   }
}

//+------------------------------------------------------------------+
//| Evalúa entrada en el re-testeo del OB ICT                        |
//+------------------------------------------------------------------+
void EvaluateICTEntry()
{
   if(!liquidSweep.detected || !liquidSweep.rejected) return;
   if(!mssEvent.detected) return;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_Entry, 0, 0, 3, atrBuf) < 3) return;
   double atr = atrBuf[1];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // ===== LONG: Sweep alcista + MSS alcista + precio retestea OB demanda =====
   if(mssEvent.direction == 1 && bullOB.time > 0 && !bullOB.mitigated)
   {
      // Zona de entrada en el OB (parte inferior para mejor R:R)
      double obEntryZone = bullOB.low + (bullOB.high - bullOB.low) * InpOBEntryPct;
      bool priceInOB     = (ask >= bullOB.low - atr * 0.1) &&
                           (ask <= obEntryZone + atr * 0.3);

      if(priceInOB)
      {
         // SL: bajo el OB + buffer ATR
         double slPrice = NormalizeDouble(bullOB.low - InpOBInvalidBuffer * pipSize - atr * InpATRSLMulti, _Digits);
         double risk    = ask - slPrice;
         if(risk <= 0.0) return;

         // TP: multiplicador ATR desde la entrada
         double tpPrice = NormalizeDouble(ask + atr * InpATRTPMulti, _Digits);

         // Verificar R:R mínimo
         double rr = (tpPrice - ask) / risk;
         if(rr < InpRRMin)
         {
            if(InpPrintLogs) Print("[ICT_OB] R:R insuficiente (", DoubleToString(rr,2),
                                   " < ", InpRRMin, "). No entrar.");
            return;
         }

         double lot = CalcLot(risk);
         if(lot <= 0.0) return;

         if(trade.Buy(lot, _Symbol, ask, slPrice, tpPrice, "ICT_OB_LONG"))
         {
            bullOB.mitigated = true; // Marcar OB como utilizado
            Print("[ICT_OB] LONG | OB[", DoubleToString(bullOB.low,2),"-",
                  DoubleToString(bullOB.high,2), "] R:R:", DoubleToString(rr,2),
                  " SL:", DoubleToString(slPrice,2), " TP:", DoubleToString(tpPrice,2),
                  " Lot:", lot, " Sweep@", DoubleToString(liquidSweep.level,2));
         }
      }
   }

   // ===== SHORT: Sweep bajista + MSS bajista + precio retestea OB oferta =====
   if(mssEvent.direction == -1 && bearOB.time > 0 && !bearOB.mitigated)
   {
      double obEntryZone = bearOB.high - (bearOB.high - bearOB.low) * InpOBEntryPct;
      bool priceInOB     = (bid <= bearOB.high + atr * 0.1) &&
                           (bid >= obEntryZone - atr * 0.3);

      if(priceInOB)
      {
         double slPrice = NormalizeDouble(bearOB.high + InpOBInvalidBuffer * pipSize + atr * InpATRSLMulti, _Digits);
         double risk    = slPrice - bid;
         if(risk <= 0.0) return;

         double tpPrice = NormalizeDouble(bid - atr * InpATRTPMulti, _Digits);
         if(tpPrice <= 0.0) return;

         double rr = (bid - tpPrice) / risk;
         if(rr < InpRRMin)
         {
            if(InpPrintLogs) Print("[ICT_OB] R:R insuficiente (", DoubleToString(rr,2),
                                   " < ", InpRRMin, "). No entrar.");
            return;
         }

         double lot = CalcLot(risk);
         if(lot <= 0.0) return;

         if(trade.Sell(lot, _Symbol, bid, slPrice, tpPrice, "ICT_OB_SHORT"))
         {
            bearOB.mitigated = true;
            Print("[ICT_OB] SHORT | OB[", DoubleToString(bearOB.low,2),"-",
                  DoubleToString(bearOB.high,2), "] R:R:", DoubleToString(rr,2),
                  " SL:", DoubleToString(slPrice,2), " TP:", DoubleToString(tpPrice,2),
                  " Lot:", lot, " Sweep@", DoubleToString(liquidSweep.level,2));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing Stop ATR                                                  |
//+------------------------------------------------------------------+
void ManageTrailingATR()
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_Entry, 0, 0, 3, atrBuf) < 3) return;
   double trailDist = atrBuf[1] * InpTrailATRMulti;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagic) continue;

      ulong  ticket = posInfo.Ticket();
      double openP  = posInfo.PriceOpen();
      double curSL  = posInfo.StopLoss();
      double curTP  = posInfo.TakeProfit();
      double minPt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         if(newSL > openP && newSL > curSL + minPt)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < openP && (curSL == 0.0 || newSL < curSL - minPt))
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Verifica si estamos en una Killzone ICT                           |
//+------------------------------------------------------------------+
bool IsInICTKillzone()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   bool londonOpen = (h >= InpLondonOpenKZ && h < InpLondonOpenKZEnd); // "Silver Bullet" / Asia Open
   bool london     = (h >= InpLondonKZStart && h < InpLondonKZEnd);    // London KZ
   bool ny         = (h >= InpNYKZStart     && h < InpNYKZEnd);        // NY AM KZ

   return (londonOpen || london || ny);
}

//+------------------------------------------------------------------+
//| Calcula lote                                                       |
//+------------------------------------------------------------------+
double CalcLot(double slPrice)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * InpRiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickVal <= 0.0 || tickSz <= 0.0 || slPrice <= 0.0) return minLot;

   double lot = riskAmt / (slPrice * tickVal / tickSz);
   lot = MathFloor(lot / lotStep) * lotStep;
   return MathMax(minLot, MathMin(maxLot, lot));
}

//+------------------------------------------------------------------+
//| Utilidades                                                         |
//+------------------------------------------------------------------+
void CloseAllMyPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
         trade.PositionClose(posInfo.Ticket());
   }
}

int CountMyPositions()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic) c++;
   }
   return c;
}

bool IsNewBar()
{
   datetime cur = iTime(_Symbol, InpEntryTF, 0);
   if(cur != lastBarEntry)
   {
      lastBarEntry = cur;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+