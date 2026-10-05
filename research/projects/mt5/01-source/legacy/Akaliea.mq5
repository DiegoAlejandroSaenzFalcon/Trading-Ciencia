//+------------------------------------------------------------------+
//|                                                      AkaliEA.mq5 |
//|                    Replica fiel de Akali EA                       |
//|    Scalping Puro XAUUSD M1/M5 | Trailing Stop Ultra Ajustado    |
//+------------------------------------------------------------------+
#property copyright   "Replica Akali EA"
#property link        ""
#property version     "1.00"
#property description "Scalping puro XAUUSD | Alta precisión | Trailing Stop de precisión extrema"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs: Riesgo
input group              "=== GESTIÓN DE RIESGO ==="
input double   InpRiskPercent       = 0.8;    // Riesgo % por operación
input double   InpMaxRiskTotal      = 5.0;    // Riesgo total máximo abierto (%)
input int      InpMaxTrades         = 3;      // Máximo de operaciones simultáneas

//--- Inputs: Indicadores Entrada
input group              "=== INDICADORES DE ENTRADA ==="
input int      InpEMA1              = 5;      // EMA Ultra Rápida
input int      InpEMA2              = 13;     // EMA Rápida
input int      InpEMA3              = 34;     // EMA Media
input int      InpEMA4              = 89;     // EMA Lenta (Filtro de tendencia)
input int      InpRSIPeriod         = 7;      // Período RSI
input double   InpRSIBuyLevel       = 45.0;   // RSI nivel mínimo compra
input double   InpRSISellLevel      = 55.0;   // RSI nivel máximo venta
input int      InpStochK            = 5;      // Stochastic %K
input int      InpStochD            = 3;      // Stochastic %D
input int      InpStochSlowing      = 3;      // Stochastic Slowing
input double   InpStochOB           = 80.0;   // Stochastic Sobrecompra
input double   InpStochOS           = 20.0;   // Stochastic Sobreventa
input int      InpATRPeriod         = 7;      // Período ATR (volatilidad)

//--- Inputs: Stop Loss / Take Profit
input group              "=== SL / TP ==="
input double   InpSLPips            = 12.0;   // Stop Loss fijo (pips)
input double   InpTPPips            = 18.0;   // Take Profit fijo (pips)
input bool     InpUseDynamicSLTP    = true;   // Usar SL/TP dinámico con ATR
input double   InpATRSLMulti        = 1.2;    // Multiplicador ATR para SL
input double   InpATRTPMulti        = 1.8;    // Multiplicador ATR para TP

//--- Inputs: Trailing Stop Ultra Ajustado
input group              "=== TRAILING STOP DE PRECISIÓN ==="
input bool     InpUseTrailing       = true;   // Activar Trailing Stop
input double   InpTrailActivePips   = 3.0;    // Pips profit para activar trailing
input double   InpTrailDistPips     = 2.0;    // Distancia del trailing (pips)
input double   InpTrailStepPips     = 0.5;    // Paso mínimo de ajuste (pips)
input bool     InpUseBEAfterEntry   = true;   // Mover SL a BE al primer target
input double   InpBETargetPips      = 6.0;    // Pips para activar BE

//--- Inputs: Filtros de Calidad
input group              "=== FILTROS DE CALIDAD ==="
input bool     InpFilterBySpread    = true;   // Filtrar por spread
input double   InpMaxSpreadPips     = 4.0;    // Spread máximo permitido (pips)
input bool     InpFilterByVolat     = true;   // Filtrar por volatilidad
input double   InpMinATRPips        = 0.5;    // ATR mínimo requerido (pips)
input double   InpMaxATRPips        = 25.0;   // ATR máximo permitido (pips)
input bool     InpFilterSession     = true;   // Filtrar por sesión
input int      InpSessionStart      = 8;      // Inicio sesión (hora GMT)
input int      InpSessionEnd        = 20;     // Fin sesión (hora GMT)

//--- Inputs: Temporalidad
input group              "=== TEMPORALIDAD ==="
input ENUM_TIMEFRAMES InpTimeframe  = PERIOD_M1;  // Temporalidad de operación

//--- Inputs: Config
input group              "=== CONFIGURACIÓN ==="
input ulong    InpMagic             = 20240702;   // Magic Number
input int      InpSlippage          = 5;          // Slippage (puntos)
input bool     InpPrintLogs         = true;       // Mostrar logs

//--- Variables globales
CTrade        trade;
CPositionInfo posInfo;

int    handleEMA1, handleEMA2, handleEMA3, handleEMA4;
int    handleRSI, handleStoch, handleATR;

double pipSize;
datetime lastBarTime = 0;
bool   beMovedTickets[];
ulong  openTickets[];

//+------------------------------------------------------------------+
//| Inicialización                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Symbol != "XAUUSD" && _Symbol != "XAUUSDm" && _Symbol != "GOLD" && _Symbol != "GOLDm")
      Print("[AKALI] ADVERTENCIA: Optimizado para XAUUSD. Símbolo actual: ", _Symbol);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;

   handleEMA1  = iMA(_Symbol, InpTimeframe, InpEMA1, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA2  = iMA(_Symbol, InpTimeframe, InpEMA2, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA3  = iMA(_Symbol, InpTimeframe, InpEMA3, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA4  = iMA(_Symbol, InpTimeframe, InpEMA4, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI   = iRSI(_Symbol, InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   handleStoch = iStochastic(_Symbol, InpTimeframe, InpStochK, InpStochD, InpStochSlowing,
                              MODE_SMA, STO_LOWHIGH);
   handleATR   = iATR(_Symbol, InpTimeframe, InpATRPeriod);

   if(handleEMA1 == INVALID_HANDLE || handleEMA2  == INVALID_HANDLE ||
      handleEMA3 == INVALID_HANDLE || handleEMA4  == INVALID_HANDLE ||
      handleRSI  == INVALID_HANDLE || handleStoch == INVALID_HANDLE ||
      handleATR  == INVALID_HANDLE)
   {
      Print("[AKALI] ERROR: Fallo al crear indicadores.");
      return INIT_FAILED;
   }

   Print("[AKALI] Akali EA inicializado. TF: ", EnumToString(InpTimeframe));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Liberación de recursos                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleEMA1);
   IndicatorRelease(handleEMA2);
   IndicatorRelease(handleEMA3);
   IndicatorRelease(handleEMA4);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleStoch);
   IndicatorRelease(handleATR);
}

//+------------------------------------------------------------------+
//| Tick principal                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // Gestión continua del Trailing Stop (cada tick)
   if(InpUseTrailing) ManagePrecisionTrailing();
   if(InpUseBEAfterEntry) ManageBreakEven();

   // Solo nuevas velas para señales de entrada
   if(!IsNewBar()) return;

   // Filtro de spread
   if(InpFilterBySpread)
   {
      double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(spread > InpMaxSpreadPips * pipSize)
      {
         if(InpPrintLogs) Print("[AKALI] Spread alto (", DoubleToString(spread / pipSize, 1), " pips). No operar.");
         return;
      }
   }

   // Filtro de sesión
   if(InpFilterSession && !IsSessionActive()) return;

   // Máximo de operaciones
   if(CountMyPositions() >= InpMaxTrades) return;

   // Obtener valores de indicadores
   double ema1[], ema2[], ema3[], ema4[], rsi[], stochK[], stochD[], atr[];
   ArraySetAsSeries(ema1,   true);
   ArraySetAsSeries(ema2,   true);
   ArraySetAsSeries(ema3,   true);
   ArraySetAsSeries(ema4,   true);
   ArraySetAsSeries(rsi,    true);
   ArraySetAsSeries(stochK, true);
   ArraySetAsSeries(stochD, true);
   ArraySetAsSeries(atr,    true);

   int needed = 5;
   if(CopyBuffer(handleEMA1,  0,          0, needed, ema1)   < needed) return;
   if(CopyBuffer(handleEMA2,  0,          0, needed, ema2)   < needed) return;
   if(CopyBuffer(handleEMA3,  0,          0, needed, ema3)   < needed) return;
   if(CopyBuffer(handleEMA4,  0,          0, needed, ema4)   < needed) return;
   if(CopyBuffer(handleRSI,   0,          0, needed, rsi)    < needed) return;
   if(CopyBuffer(handleStoch, MAIN_LINE,  0, needed, stochK) < needed) return;
   if(CopyBuffer(handleStoch, SIGNAL_LINE,0, needed, stochD) < needed) return;
   if(CopyBuffer(handleATR,   0,          0, needed, atr)    < needed) return;

   // Filtro de volatilidad ATR
   double atrPips = atr[1] / pipSize;
   if(InpFilterByVolat)
   {
      if(atrPips < InpMinATRPips || atrPips > InpMaxATRPips)
      {
         if(InpPrintLogs) Print("[AKALI] ATR fuera de rango (", DoubleToString(atrPips, 2), " pips).");
         return;
      }
   }

   // Calcular SL y TP
   double slPips = InpUseDynamicSLTP ? atrPips * InpATRSLMulti : InpSLPips;
   double tpPips = InpUseDynamicSLTP ? atrPips * InpATRTPMulti : InpTPPips;
   double slVal  = slPips * pipSize;
   double tpVal  = tpPips * pipSize;

   // Señales de entrada
   int signal = GetEntrySignal(ema1, ema2, ema3, ema4, rsi, stochK, stochD);
   if(signal == 0) return;

   double lot = CalcLot(slVal);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(signal == 1) // COMPRA
   {
      double sl = NormalizeDouble(ask - slVal, _Digits);
      double tp = NormalizeDouble(ask + tpVal, _Digits);
      if(trade.Buy(lot, _Symbol, ask, sl, tp, "AKALI_BUY"))
      {
         if(InpPrintLogs)
            Print("[AKALI] BUY | Lot:", lot, " SL:", DoubleToString(slPips,1), "p TP:", DoubleToString(tpPips,1), "p");
      }
   }
   else if(signal == -1) // VENTA
   {
      double sl = NormalizeDouble(bid + slVal, _Digits);
      double tp = NormalizeDouble(bid - tpVal, _Digits);
      if(trade.Sell(lot, _Symbol, bid, sl, tp, "AKALI_SELL"))
      {
         if(InpPrintLogs)
            Print("[AKALI] SELL | Lot:", lot, " SL:", DoubleToString(slPips,1), "p TP:", DoubleToString(tpPips,1), "p");
      }
   }
}

//+------------------------------------------------------------------+
//| Lógica de señal de entrada (scalping de alta precisión)          |
//+------------------------------------------------------------------+
int GetEntrySignal(const double &ema1[], const double &ema2[],
                   const double &ema3[], const double &ema4[],
                   const double &rsi[],  const double &stochK[],
                   const double &stochD[])
{
   // Condición de Tendencia (EMA lenta)
   double close1 = iClose(_Symbol, InpTimeframe, 1);
   bool trendUp   = (close1 > ema4[1]) && (ema1[1] > ema2[1]) && (ema2[1] > ema3[1]);
   bool trendDown = (close1 < ema4[1]) && (ema1[1] < ema2[1]) && (ema2[1] < ema3[1]);

   // Cruce de EMA rápidas (EMA1 cruza EMA2)
   bool emaCrossUp   = (ema1[2] <= ema2[2]) && (ema1[1] > ema2[1]);
   bool emaCrossDown = (ema1[2] >= ema2[2]) && (ema1[1] < ema2[1]);

   // Confirmación RSI
   bool rsiBuy  = (rsi[1] > InpRSIBuyLevel)  && (rsi[1] < 75.0);
   bool rsiSell = (rsi[1] < InpRSISellLevel) && (rsi[1] > 25.0);

   // Stochastic saliendo de zona (anti-sobrecompra/venta para scalping)
   bool stochBuy  = (stochK[2] < InpStochOS) && (stochK[1] > InpStochOS) &&
                    (stochK[1] > stochD[1]);
   bool stochNoBuy = (stochK[1] > InpStochOB); // Evitar comprar sobrecomprado

   bool stochSell  = (stochK[2] > InpStochOB) && (stochK[1] < InpStochOB) &&
                     (stochK[1] < stochD[1]);
   bool stochNoSell = (stochK[1] < InpStochOS); // Evitar vender sobrevendido

   // Señal de Compra: tendencia alcista + cruce EMA + RSI ok + Stoch saliendo de OS
   bool buySignal = trendUp && emaCrossUp && rsiBuy && !stochNoBuy;

   // Señal de Venta: tendencia bajista + cruce EMA + RSI ok + Stoch saliendo de OB
   bool sellSignal = trendDown && emaCrossDown && rsiSell && !stochNoSell;

   // Calidad extra: confirmación con la siguiente EMA más lenta
   if(buySignal  && ema2[1] > ema3[1]) return 1;
   if(sellSignal && ema2[1] < ema3[1]) return -1;

   return 0;
}

//+------------------------------------------------------------------+
//| Trailing Stop de Precisión Extrema (cada tick)                   |
//+------------------------------------------------------------------+
void ManagePrecisionTrailing()
{
   double trailActive = InpTrailActivePips * pipSize;
   double trailDist   = InpTrailDistPips   * pipSize;
   double trailStep   = InpTrailStepPips   * pipSize;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagic) continue;

      ulong  ticket  = posInfo.Ticket();
      double openPr  = posInfo.PriceOpen();
      double curSL   = posInfo.StopLoss();
      double curTP   = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double profit = bid - openPr;
         if(profit < trailActive) continue;

         double newSL = NormalizeDouble(bid - trailDist, _Digits);
         if(newSL > curSL + trailStep)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profit = openPr - ask;
         if(profit < trailActive) continue;

         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(curSL == 0.0 || newSL < curSL - trailStep)
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Break Even: mueve SL a precio de apertura al alcanzar target      |
//+------------------------------------------------------------------+
void ManageBreakEven()
{
   double beTarget = InpBETargetPips * pipSize;
   double minDist  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) *
                     SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagic) continue;

      ulong  ticket  = posInfo.Ticket();
      double openPr  = posInfo.PriceOpen();
      double curSL   = posInfo.StopLoss();
      double curTP   = posInfo.TakeProfit();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if((bid - openPr) >= beTarget && curSL < openPr - minDist)
         {
            double newSL = NormalizeDouble(openPr + minDist, _Digits);
            if(newSL > curSL)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if((openPr - ask) >= beTarget && (curSL == 0.0 || curSL > openPr + minDist))
         {
            double newSL = NormalizeDouble(openPr - minDist, _Digits);
            if(curSL == 0.0 || newSL < curSL)
               trade.PositionModify(ticket, newSL, curTP);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calcula el lote según riesgo fijo                                 |
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
//| Verifica sesión activa                                             |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= InpSessionStart && dt.hour < InpSessionEnd);
}

//+------------------------------------------------------------------+
//| Nueva vela                                                         |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime curBar = iTime(_Symbol, InpTimeframe, 0);
   if(curBar != lastBarTime)
   {
      lastBarTime = curBar;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+