//+------------------------------------------------------------------+
//|                                                  UltimateSMC.mq5 |
//|                    Replica fiel de Ultimate SMC EA                |
//|    Smart Money Concepts | BOS/CHoCH | FVG | OB | Killzones       |
//+------------------------------------------------------------------+
#property copyright   "Replica Ultimate SMC EA"
#property link        ""
#property version     "1.00"
#property description "SMC Multi-TF | BOS/CHoCH | Fair Value Gap | Order Blocks | Killzones Londres/NY"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs: Activos y Temporalidades
input group              "=== ACTIVOS Y TEMPORALIDADES ==="
input ENUM_TIMEFRAMES InpHTF          = PERIOD_H4;   // Temporalidad Alta (estructura)
input ENUM_TIMEFRAMES InpMTF          = PERIOD_H1;   // Temporalidad Media (tendencia)
input ENUM_TIMEFRAMES InpLTF          = PERIOD_M15;  // Temporalidad Entrada (ejecución)
input int             InpStructBars   = 20;          // Velas para detectar estructura

//--- Inputs: Gestión de Riesgo
input group              "=== GESTIÓN DE RIESGO ==="
input double   InpRiskPercent         = 1.0;   // Riesgo % por operación
input int      InpMaxTrades           = 2;     // Máximo operaciones simultáneas
input double   InpRRRatio             = 2.0;   // Ratio Riesgo/Recompensa mínimo
input double   InpMaxDDPct            = 10.0;  // Drawdown máximo (%)

//--- Inputs: Order Blocks
input group              "=== ORDER BLOCKS ==="
input int      InpOBLookback          = 50;    // Velas atrás para buscar OB
input double   InpOBMinSizeMulti      = 0.5;   // Tamaño mínimo OB (x ATR)
input double   InpOBEntryZone         = 0.5;   // Zona entrada en OB (0=base, 1=tope)

//--- Inputs: Fair Value Gaps
input group              "=== FAIR VALUE GAPS ==="
input bool     InpUseFVG              = true;  // Usar FVG como confirmación
input double   InpFVGMinSizePips      = 2.0;   // Tamaño mínimo FVG (pips)
input int      InpFVGMaxBarsAgo       = 30;    // Máx velas atrás para FVG válido

//--- Inputs: Killzones (Sesiones)
input group              "=== KILLZONES ==="
input bool     InpUseLondonKZ         = true;  // Usar Killzone Londres
input int      InpLondonStart         = 8;     // Londres inicio (GMT)
input int      InpLondonEnd           = 11;    // Londres fin (GMT)
input bool     InpUseNYKZ             = true;  // Usar Killzone Nueva York
input int      InpNYStart             = 13;    // Nueva York inicio (GMT)
input int      InpNYEnd               = 16;    // Nueva York fin (GMT)
input bool     InpUseAsiaKZ           = false; // Usar Killzone Asia
input int      InpAsiaStart           = 0;     // Asia inicio (GMT)
input int      InpAsiaEnd             = 4;     // Asia fin (GMT)

//--- Inputs: Stop Loss / Take Profit
input group              "=== SL / TP ==="
input bool     InpUseOBForSL          = true;   // SL basado en OB
input double   InpSLBufferPips        = 3.0;    // Buffer sobre/bajo OB para SL
input bool     InpUseTrailing         = true;   // Usar Trailing Stop
input double   InpTrailPips           = 8.0;    // Distancia Trailing (pips)

//--- Inputs: Configuración
input group              "=== CONFIGURACIÓN ==="
input ulong    InpMagic               = 20240703; // Magic Number
input int      InpSlippage            = 10;       // Slippage (puntos)
input bool     InpPrintLogs           = true;     // Mostrar logs detallados

//--- Estructuras de datos SMC
struct SOrderBlock
{
   double   high;
   double   low;
   double   mid;
   datetime time;
   int      direction;  // 1=alcista (demanda), -1=bajista (oferta)
   bool     mitigated;
   int      strength;   // 1-3 (importancia)
};

struct SFairValueGap
{
   double   upper;
   double   lower;
   datetime time;
   int      direction;
   bool     filled;
};

struct SMarketStructure
{
   double   lastSwingHigh;
   double   lastSwingLow;
   datetime swingHighTime;
   datetime swingLowTime;
   int      trend;          // 1=alcista, -1=bajista, 0=indefinido
   bool     bosBullish;
   bool     bosBearish;
   bool     chochBullish;
   bool     chochBearish;
};

//--- Variables globales
CTrade        trade;
CPositionInfo posInfo;

int    handleATR_HTF, handleATR_LTF;
int    handleEMA_HTF, handleEMA_MTF;

double pipSize;
datetime lastBarLTF = 0;
double   peakBalance = 0.0;

SOrderBlock    currentBullOB, currentBearOB;
SFairValueGap  currentBullFVG, currentBearFVG;
SMarketStructure htfStructure, mtfStructure;

//+------------------------------------------------------------------+
//| Inicialización                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;

   handleATR_HTF = iATR(_Symbol, InpHTF, 14);
   handleATR_LTF = iATR(_Symbol, InpLTF, 14);
   handleEMA_HTF = iMA(_Symbol, InpHTF, 200, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA_MTF = iMA(_Symbol, InpMTF, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(handleATR_HTF == INVALID_HANDLE || handleATR_LTF == INVALID_HANDLE ||
      handleEMA_HTF == INVALID_HANDLE || handleEMA_MTF == INVALID_HANDLE)
   {
      Print("[SMC] ERROR: Fallo al crear indicadores.");
      return INIT_FAILED;
   }

   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   // Inicializar estructuras
   ZeroMemory(currentBullOB);
   ZeroMemory(currentBearOB);
   ZeroMemory(currentBullFVG);
   ZeroMemory(currentBearFVG);
   ZeroMemory(htfStructure);
   ZeroMemory(mtfStructure);

   Print("[SMC] Ultimate SMC EA inicializado. HTF:", EnumToString(InpHTF),
         " MTF:", EnumToString(InpMTF), " LTF:", EnumToString(InpLTF));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Liberación                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR_HTF);
   IndicatorRelease(handleATR_LTF);
   IndicatorRelease(handleEMA_HTF);
   IndicatorRelease(handleEMA_MTF);
}

//+------------------------------------------------------------------+
//| Tick Principal                                                     |
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

   // Trailing stop
   if(InpUseTrailing) ManageTrailing();

   // Solo en nueva vela LTF
   if(!IsNewBar(InpLTF)) return;

   // Filtro Killzone
   if(!IsInKillzone()) return;

   // Límite de posiciones
   if(CountMyPositions() >= InpMaxTrades) return;

   // Analizar estructura en HTF y MTF
   AnalyzeMarketStructure(InpHTF, htfStructure);
   AnalyzeMarketStructure(InpMTF, mtfStructure);

   // Detectar Order Blocks en LTF
   FindOrderBlocks();

   // Detectar FVGs en LTF
   if(InpUseFVG) FindFairValueGaps();

   // Evaluar confluencias y entrar
   EvaluateEntry();
}

//+------------------------------------------------------------------+
//| Analiza estructura de mercado (BOS / CHoCH)                      |
//+------------------------------------------------------------------+
void AnalyzeMarketStructure(ENUM_TIMEFRAMES tf, SMarketStructure &ms)
{
   int bars = InpStructBars;
   double highs[], lows[];
   datetime times[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);
   ArraySetAsSeries(times, true);

   if(CopyHigh(_Symbol, tf, 1, bars + 5, highs) < bars + 5) return;
   if(CopyLow(_Symbol,  tf, 1, bars + 5, lows)  < bars + 5) return;
   if(CopyTime(_Symbol, tf, 1, bars + 5, times) < bars + 5) return;

   // Encontrar último swing high y swing low
   double prevSwingHigh = ms.lastSwingHigh;
   double prevSwingLow  = ms.lastSwingLow;

   double newSwingHigh = 0.0, newSwingLow = DBL_MAX;
   datetime swHTime = 0, swLTime = 0;
   int swHBar = 0, swLBar = 0;

   for(int i = 2; i < bars - 2; i++)
   {
      // Swing High: vela más alta que las 2 anteriores y 2 siguientes
      if(highs[i] > highs[i-1] && highs[i] > highs[i-2] &&
         highs[i] > highs[i+1] && highs[i] > highs[i+2])
      {
         if(highs[i] > newSwingHigh)
         {
            newSwingHigh = highs[i];
            swHTime = times[i];
            swHBar  = i;
         }
      }
      // Swing Low: vela más baja que las 2 anteriores y 2 siguientes
      if(lows[i] < lows[i-1] && lows[i] < lows[i-2] &&
         lows[i] < lows[i+1] && lows[i] < lows[i+2])
      {
         if(lows[i] < newSwingLow)
         {
            newSwingLow = lows[i];
            swLTime = times[i];
            swLBar  = i;
         }
      }
   }

   ms.lastSwingHigh = newSwingHigh;
   ms.lastSwingLow  = (newSwingLow == DBL_MAX) ? 0.0 : newSwingLow;
   ms.swingHighTime = swHTime;
   ms.swingLowTime  = swLTime;

   double close = iClose(_Symbol, tf, 1);

   // BOS Alcista: precio cierra SOBRE swing high previo → continuación alcista
   ms.bosBullish = (prevSwingHigh > 0.0) && (close > prevSwingHigh);
   // BOS Bajista: precio cierra BAJO swing low previo → continuación bajista
   ms.bosBearish = (prevSwingLow > 0.0)  && (close < prevSwingLow);

   // CHoCH Alcista: precio cierra sobre swing high en tendencia bajista (cambio)
   ms.chochBullish = ms.bosBullish && (ms.trend == -1);
   // CHoCH Bajista: precio cierra bajo swing low en tendencia alcista (cambio)
   ms.chochBearish = ms.bosBearish && (ms.trend == 1);

   // Actualizar tendencia
   if(ms.bosBullish && !ms.chochBullish) ms.trend = 1;
   if(ms.bosBearish && !ms.chochBearish) ms.trend = -1;

   if(InpPrintLogs && (ms.bosBullish || ms.bosBearish || ms.chochBullish || ms.chochBearish))
      Print("[SMC] ", EnumToString(tf),
            " BOS Bull:", ms.bosBullish, " BOS Bear:", ms.bosBearish,
            " CHoCH Bull:", ms.chochBullish, " CHoCH Bear:", ms.chochBearish,
            " Trend:", ms.trend);
}

//+------------------------------------------------------------------+
//| Encuentra Order Blocks en LTF                                     |
//+------------------------------------------------------------------+
void FindOrderBlocks()
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_LTF, 0, 0, InpOBLookback + 5, atrBuf) < InpOBLookback + 5) return;

   double atrAvg = 0.0;
   for(int k = 1; k <= 10; k++) atrAvg += atrBuf[k];
   atrAvg /= 10.0;

   ZeroMemory(currentBullOB);
   ZeroMemory(currentBearOB);

   for(int i = 2; i < InpOBLookback; i++)
   {
      double open_i  = iOpen(_Symbol,  InpLTF, i);
      double close_i = iClose(_Symbol, InpLTF, i);
      double high_i  = iHigh(_Symbol,  InpLTF, i);
      double low_i   = iLow(_Symbol,   InpLTF, i);
      datetime time_i = iTime(_Symbol, InpLTF, i);

      double body = MathAbs(close_i - open_i);
      if(body < atrAvg * InpOBMinSizeMulti) continue;

      // Vela siguiente (i-1) para confirmar impulso
      double open_n  = iOpen(_Symbol,  InpLTF, i - 1);
      double close_n = iClose(_Symbol, InpLTF, i - 1);

      // OB Alcista (Demanda): vela bajista seguida de vela alcista fuerte
      if(close_i < open_i && close_n > open_n && (close_n - open_n) > body)
      {
         if(currentBullOB.time == 0 || time_i > currentBullOB.time)
         {
            // Verificar que el precio haya subido desde este OB
            double currentPrice = iClose(_Symbol, InpLTF, 1);
            if(currentPrice > high_i && !currentBullOB.mitigated)
            {
               currentBullOB.high      = high_i;
               currentBullOB.low       = low_i;
               currentBullOB.mid       = (high_i + low_i) / 2.0;
               currentBullOB.time      = time_i;
               currentBullOB.direction = 1;
               currentBullOB.mitigated = false;
               currentBullOB.strength  = (body > atrAvg * 1.5) ? 3 : (body > atrAvg) ? 2 : 1;
            }
         }
      }

      // OB Bajista (Oferta): vela alcista seguida de vela bajista fuerte
      if(close_i > open_i && close_n < open_n && (open_n - close_n) > body)
      {
         if(currentBearOB.time == 0 || time_i > currentBearOB.time)
         {
            double currentPrice = iClose(_Symbol, InpLTF, 1);
            if(currentPrice < low_i && !currentBearOB.mitigated)
            {
               currentBearOB.high      = high_i;
               currentBearOB.low       = low_i;
               currentBearOB.mid       = (high_i + low_i) / 2.0;
               currentBearOB.time      = time_i;
               currentBearOB.direction = -1;
               currentBearOB.mitigated = false;
               currentBearOB.strength  = (body > atrAvg * 1.5) ? 3 : (body > atrAvg) ? 2 : 1;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Encuentra Fair Value Gaps en LTF                                  |
//+------------------------------------------------------------------+
void FindFairValueGaps()
{
   ZeroMemory(currentBullFVG);
   ZeroMemory(currentBearFVG);

   double minFVG = InpFVGMinSizePips * pipSize;

   for(int i = 2; i < InpFVGMaxBarsAgo; i++)
   {
      double high_prev = iHigh(_Symbol,  InpLTF, i + 1); // Vela antes
      double low_prev  = iLow(_Symbol,   InpLTF, i + 1);
      double high_curr = iHigh(_Symbol,  InpLTF, i);     // Vela en cuestión
      double low_curr  = iLow(_Symbol,   InpLTF, i);
      double high_next = iHigh(_Symbol,  InpLTF, i - 1); // Vela después
      double low_next  = iLow(_Symbol,   InpLTF, i - 1);
      datetime t = iTime(_Symbol, InpLTF, i);

      // FVG Alcista: Low de vela posterior > High de vela anterior (brecha alcista)
      double fvgGapUp = low_next - high_prev;
      if(fvgGapUp >= minFVG && currentBullFVG.time == 0)
      {
         currentBullFVG.upper    = low_next;
         currentBullFVG.lower    = high_prev;
         currentBullFVG.time     = t;
         currentBullFVG.direction = 1;
         currentBullFVG.filled   = false;
      }

      // FVG Bajista: High de vela posterior < Low de vela anterior (brecha bajista)
      double fvgGapDown = low_prev - high_next;
      if(fvgGapDown >= minFVG && currentBearFVG.time == 0)
      {
         currentBearFVG.upper    = low_prev;
         currentBearFVG.lower    = high_next;
         currentBearFVG.time     = t;
         currentBearFVG.direction = -1;
         currentBearFVG.filled   = false;
      }

      if(currentBullFVG.time > 0 && currentBearFVG.time > 0) break;
   }
}

//+------------------------------------------------------------------+
//| Evalúa confluencias y determina entrada                           |
//+------------------------------------------------------------------+
void EvaluateEntry()
{
   double price  = iClose(_Symbol, InpLTF, 1);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Contexto macro HTF
   bool htfBullish = (htfStructure.trend == 1) || htfStructure.bosBullish;
   bool htfBearish = (htfStructure.trend == -1) || htfStructure.bosBearish;

   // Contexto MTF
   bool mtfBullish = (mtfStructure.trend == 1) || mtfStructure.bosBullish;
   bool mtfBearish = (mtfStructure.trend == -1) || mtfStructure.bosBearish;

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_LTF, 0, 0, 3, atrBuf) < 3) return;
   double atr = atrBuf[1];

   // ===== ENTRADA LONG (COMPRA) =====
   // HTF y MTF alcistas + precio re-testea OB alcista + FVG alcista como confluencia
   if(htfBullish && mtfBullish && currentBullOB.time > 0)
   {
      double obEntryZone = currentBullOB.low + (currentBullOB.high - currentBullOB.low) * InpOBEntryZone;

      bool priceInOB = (ask >= currentBullOB.low - atr * 0.1) &&
                       (ask <= currentBullOB.high + atr * 0.1);
      bool fvgConf   = !InpUseFVG || (currentBullFVG.time > 0 &&
                        ask >= currentBullFVG.lower && ask <= currentBullFVG.upper);

      if(priceInOB)
      {
         double slPrice, tpPrice;
         if(InpUseOBForSL)
            slPrice = currentBullOB.low - InpSLBufferPips * pipSize;
         else
            slPrice = ask - atr * 1.5;

         double riskPts = ask - slPrice;
         if(riskPts <= 0.0) return;
         tpPrice = ask + riskPts * InpRRRatio;

         slPrice = NormalizeDouble(slPrice, _Digits);
         tpPrice = NormalizeDouble(tpPrice, _Digits);

         double lot = CalcLot(riskPts);
         if(lot <= 0.0) return;

         int confluences = (fvgConf ? 1 : 0) + (currentBullOB.strength >= 2 ? 1 : 0) +
                           (htfStructure.bosBullish ? 1 : 0) + (mtfStructure.bosBullish ? 1 : 0);
         if(confluences < 2) return;

         if(trade.Buy(lot, _Symbol, ask, slPrice, tpPrice, "SMC_BUY"))
            Print("[SMC] BUY | OB zona:", DoubleToString(currentBullOB.low,2),"-",
                  DoubleToString(currentBullOB.high,2), " Lot:", lot,
                  " Confluencias:", confluences);
      }
   }

   // ===== ENTRADA SHORT (VENTA) =====
   // HTF y MTF bajistas + precio re-testea OB bajista + FVG bajista
   if(htfBearish && mtfBearish && currentBearOB.time > 0)
   {
      bool priceInOB = (bid <= currentBearOB.high + atr * 0.1) &&
                       (bid >= currentBearOB.low  - atr * 0.1);
      bool fvgConf   = !InpUseFVG || (currentBearFVG.time > 0 &&
                        bid >= currentBearFVG.lower && bid <= currentBearFVG.upper);

      if(priceInOB)
      {
         double slPrice, tpPrice;
         if(InpUseOBForSL)
            slPrice = currentBearOB.high + InpSLBufferPips * pipSize;
         else
            slPrice = bid + atr * 1.5;

         double riskPts = slPrice - bid;
         if(riskPts <= 0.0) return;
         tpPrice = bid - riskPts * InpRRRatio;
         if(tpPrice <= 0.0) return;

         slPrice = NormalizeDouble(slPrice, _Digits);
         tpPrice = NormalizeDouble(tpPrice, _Digits);

         double lot = CalcLot(riskPts);
         if(lot <= 0.0) return;

         int confluences = (fvgConf ? 1 : 0) + (currentBearOB.strength >= 2 ? 1 : 0) +
                           (htfStructure.bosBearish ? 1 : 0) + (mtfStructure.bosBearish ? 1 : 0);
         if(confluences < 2) return;

         if(trade.Sell(lot, _Symbol, bid, slPrice, tpPrice, "SMC_SELL"))
            Print("[SMC] SELL | OB zona:", DoubleToString(currentBearOB.low,2),"-",
                  DoubleToString(currentBearOB.high,2), " Lot:", lot,
                  " Confluencias:", confluences);
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing Stop                                                      |
//+------------------------------------------------------------------+
void ManageTrailing()
{
   double trailDist = InpTrailPips * pipSize;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagic) continue;

      ulong  ticket = posInfo.Ticket();
      double openP  = posInfo.PriceOpen();
      double curSL  = posInfo.StopLoss();
      double curTP  = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         if(newSL > openP && newSL > curSL + pipSize)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else
      {
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < openP && (curSL == 0.0 || newSL < curSL - pipSize))
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Calcula lote por riesgo                                           |
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
//| Comprueba si estamos en una Killzone activa                       |
//+------------------------------------------------------------------+
bool IsInKillzone()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   if(InpUseLondonKZ && h >= InpLondonStart && h < InpLondonEnd) return true;
   if(InpUseNYKZ     && h >= InpNYStart     && h < InpNYEnd)     return true;
   if(InpUseAsiaKZ   && h >= InpAsiaStart   && h < InpAsiaEnd)   return true;
   return false;
}

//+------------------------------------------------------------------+
//| Cierra todas las posiciones                                        |
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

//+------------------------------------------------------------------+
//| Cuenta posiciones del EA                                          |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Nueva vela                                                         |
//+------------------------------------------------------------------+
bool IsNewBar(ENUM_TIMEFRAMES tf)
{
   datetime cur = iTime(_Symbol, tf, 0);
   if(cur != lastBarLTF)
   {
      lastBarLTF = cur;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+