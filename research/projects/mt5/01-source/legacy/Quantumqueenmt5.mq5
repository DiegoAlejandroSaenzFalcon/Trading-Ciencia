//+------------------------------------------------------------------+
//|                                           QuantumQueenMT5.mq5    |
//|                    Replica fiel de Quantum Queen MT5              |
//|          6 Sub-Estrategias + Grid Controlado + Lotaje Adaptativo  |
//+------------------------------------------------------------------+
#property copyright   "Replica Quantum Queen MT5"
#property link        ""
#property version     "1.00"
#property description "Scalping XAUUSD M1 | 6 Sub-Estrategias | Grid Controlado | Lotaje Adaptativo ATR"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Inputs: Gestión de Riesgo
input group              "=== GESTIÓN DE RIESGO ==="
input double   InpRiskPercent     = 1.0;    // Riesgo % por operación
input double   InpMaxDrawdownPct  = 15.0;   // Drawdown máximo permitido (%)
input int      InpMaxPositions    = 6;      // Posiciones simultáneas máximas

//--- Inputs: Parámetros de Indicadores
input group              "=== INDICADORES ==="
input int      InpEMAFast         = 8;      // EMA Rápida
input int      InpEMASlow         = 21;     // EMA Lenta
input int      InpEMATrend        = 50;     // EMA de Tendencia
input int      InpRSIPeriod       = 14;     // Período RSI
input double   InpRSI_OB          = 70.0;   // RSI Sobrecompra
input double   InpRSI_OS          = 30.0;   // RSI Sobreventa
input int      InpATRPeriod       = 14;     // Período ATR
input int      InpBBPeriod        = 20;     // Período Bandas Bollinger
input double   InpBBDeviation     = 2.0;    // Desviación Bollinger

//--- Inputs: Stop Loss / Take Profit
input group              "=== SL / TP ==="
input double   InpStopLossPips    = 20.0;   // Stop Loss (pips)
input double   InpTakeProfitPips  = 35.0;   // Take Profit (pips)
input double   InpTrailStartPips  = 10.0;   // Activar Trailing (pips)
input double   InpTrailStepPips   = 5.0;    // Paso del Trailing (pips)

//--- Inputs: Grid
input group              "=== GRID CONTROLADO ==="
input bool     InpUseGrid         = true;   // Usar Grid
input int      InpGridLevels      = 3;      // Niveles del Grid
input double   InpGridStepPips    = 8.0;    // Paso del Grid (pips)
input double   InpGridLotMulti    = 0.8;    // Multiplicador de Lote del Grid

//--- Inputs: Filtros
input group              "=== FILTROS ==="
input int      InpMinStrategies   = 3;      // Estrategias mínimas en acuerdo
input bool     InpFilterBySession = true;   // Filtrar por sesión activa
input int      InpLondonOpen      = 8;      // Apertura Londres (hora GMT)
input int      InpNYOpen          = 13;     // Apertura Nueva York (hora GMT)
input int      InpSessionClose    = 21;     // Cierre sesión (hora GMT)

//--- Inputs: Configuración
input group              "=== CONFIGURACIÓN ==="
input ulong    InpMagicNumber     = 20240601; // Magic Number
input int      InpSlippage        = 10;     // Slippage (puntos)

//--- Variables globales
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     orderInfo;

int  handleATR, handleEMAFast, handleEMASlow, handleEMATrend;
int  handleRSI, handleBBUpper, handleBBMid, handleBBLower;
int  handleBB;

double pipSize;
datetime lastBarTime = 0;
double   peakBalance = 0.0;

//+------------------------------------------------------------------+
//| Inicialización                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Symbol != "XAUUSD" && _Symbol != "XAUUSDm" && _Symbol != "GOLD" && _Symbol != "GOLDm")
      Print("[QQ] ADVERTENCIA: Este EA está optimizado para XAUUSD. Símbolo actual: ", _Symbol);

   if(_Period != PERIOD_M1)
      Print("[QQ] ADVERTENCIA: Temporalidad recomendada M1. Actual: ", EnumToString(_Period));

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;

   handleATR      = iATR(_Symbol, PERIOD_M1, InpATRPeriod);
   handleEMAFast  = iMA(_Symbol, PERIOD_M1, InpEMAFast,  0, MODE_EMA, PRICE_CLOSE);
   handleEMASlow  = iMA(_Symbol, PERIOD_M1, InpEMASlow,  0, MODE_EMA, PRICE_CLOSE);
   handleEMATrend = iMA(_Symbol, PERIOD_M1, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI      = iRSI(_Symbol, PERIOD_M1, InpRSIPeriod, PRICE_CLOSE);
   handleBB       = iBands(_Symbol, PERIOD_M1, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);

   if(handleATR      == INVALID_HANDLE || handleEMAFast  == INVALID_HANDLE ||
      handleEMASlow  == INVALID_HANDLE || handleEMATrend == INVALID_HANDLE ||
      handleRSI      == INVALID_HANDLE || handleBB       == INVALID_HANDLE)
   {
      Print("[QQ] ERROR: No se pudieron crear los indicadores.");
      return INIT_FAILED;
   }

   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("[QQ] Quantum Queen MT5 inicializado correctamente.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Liberación de recursos                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR);
   IndicatorRelease(handleEMAFast);
   IndicatorRelease(handleEMASlow);
   IndicatorRelease(handleEMATrend);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleBB);
}

//+------------------------------------------------------------------+
//| Tick principal                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // Protección de Drawdown
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance > peakBalance) peakBalance = currentBalance;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (peakBalance - equity) / peakBalance * 100.0;
   if(ddPct >= InpMaxDrawdownPct)
   {
      Print("[QQ] Drawdown máximo alcanzado (", DoubleToString(ddPct, 2), "%). EA detenido.");
      CloseAllPositions();
      return;
   }

   // Trailing Stop en posiciones abiertas
   ManageTrailingStop();

   // Solo operar en nueva vela
   if(!IsNewBar()) return;

   // Filtro de sesión
   if(InpFilterBySession && !IsSessionActive()) return;

   // Recopilar señales de las 6 sub-estrategias
   int signal = 0;
   int votes  = 0;
   int result = 0;

   result = Strategy1_EMACrossoverRSI();   if(result != 0){ signal += result; votes++; }
   result = Strategy2_TrendMomentum();      if(result != 0){ signal += result; votes++; }
   result = Strategy3_RSIExtremes();        if(result != 0){ signal += result; votes++; }
   result = Strategy4_ATRBreakout();        if(result != 0){ signal += result; votes++; }
   result = Strategy5_PinBar();             if(result != 0){ signal += result; votes++; }
   result = Strategy6_BBSqueeze();          if(result != 0){ signal += result; votes++; }

   // Requiere consenso mínimo
   if(votes < InpMinStrategies || MathAbs(signal) < InpMinStrategies) return;

   // No superar máximo de posiciones
   if(CountPositions() >= InpMaxPositions) return;

   // Calcular lotaje adaptativo usando ATR
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR, 0, 0, 3, atrBuf) < 3) return;

   double atrValue  = atrBuf[1];
   double slPoints  = InpStopLossPips * pipSize;
   double baseLot   = CalcAdaptiveLot(slPoints, atrValue);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(signal > 0) // Señal de Compra
   {
      double sl = ask - slPoints;
      double tp = ask + (InpTakeProfitPips * pipSize);
      sl = NormalizeDouble(sl, _Digits);
      tp = NormalizeDouble(tp, _Digits);

      trade.Buy(baseLot, _Symbol, ask, sl, tp, "QQ_BUY_S" + IntegerToString(MathAbs(signal)));
      if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         Print("[QQ] BUY abierto | Lot:", baseLot, " | Señales:", signal, "/", votes);
         if(InpUseGrid) PlaceGridOrders(1, ask, baseLot);
      }
   }
   else if(signal < 0) // Señal de Venta
   {
      double sl = bid + slPoints;
      double tp = bid - (InpTakeProfitPips * pipSize);
      sl = NormalizeDouble(sl, _Digits);
      tp = NormalizeDouble(tp, _Digits);

      trade.Sell(baseLot, _Symbol, bid, sl, tp, "QQ_SELL_S" + IntegerToString(MathAbs(signal)));
      if(trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         Print("[QQ] SELL abierto | Lot:", baseLot, " | Señales:", signal, "/", votes);
         if(InpUseGrid) PlaceGridOrders(-1, bid, baseLot);
      }
   }
}

//+------------------------------------------------------------------+
//| SUB-ESTRATEGIA 1: Cruce de EMA + Confirmación RSI                |
//+------------------------------------------------------------------+
int Strategy1_EMACrossoverRSI()
{
   double emaF[], emaS[], rsi[];
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);
   ArraySetAsSeries(rsi,  true);

   if(CopyBuffer(handleEMAFast, 0, 0, 4, emaF) < 4) return 0;
   if(CopyBuffer(handleEMASlow, 0, 0, 4, emaS) < 4) return 0;
   if(CopyBuffer(handleRSI,     0, 0, 4, rsi)  < 4) return 0;

   bool buy  = (emaF[2] <= emaS[2]) && (emaF[1] > emaS[1]) &&
               (rsi[1] > 50.0)      && (rsi[1] < InpRSI_OB);
   bool sell = (emaF[2] >= emaS[2]) && (emaF[1] < emaS[1]) &&
               (rsi[1] < 50.0)      && (rsi[1] > InpRSI_OS);

   if(buy)  return 1;
   if(sell) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| SUB-ESTRATEGIA 2: Impulso con EMA de Tendencia                   |
//+------------------------------------------------------------------+
int Strategy2_TrendMomentum()
{
   double emaF[], emaT[], rsi[];
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaT, true);
   ArraySetAsSeries(rsi,  true);

   if(CopyBuffer(handleEMAFast,  0, 0, 3, emaF) < 3) return 0;
   if(CopyBuffer(handleEMATrend, 0, 0, 3, emaT) < 3) return 0;
   if(CopyBuffer(handleRSI,      0, 0, 3, rsi)  < 3) return 0;

   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double close2 = iClose(_Symbol, PERIOD_M1, 2);

   bool buy  = (close1 > emaT[1]) && (emaF[1] > emaT[1]) &&
               (close1 > close2)   && (rsi[1] > 50.0) && (rsi[1] < 68.0);
   bool sell = (close1 < emaT[1]) && (emaF[1] < emaT[1]) &&
               (close1 < close2)   && (rsi[1] < 50.0) && (rsi[1] > 32.0);

   if(buy)  return 1;
   if(sell) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| SUB-ESTRATEGIA 3: Reversión en Extremos RSI                      |
//+------------------------------------------------------------------+
int Strategy3_RSIExtremes()
{
   double rsi[], emaT[];
   ArraySetAsSeries(rsi,  true);
   ArraySetAsSeries(emaT, true);

   if(CopyBuffer(handleRSI,      0, 0, 4, rsi)  < 4) return 0;
   if(CopyBuffer(handleEMATrend, 0, 0, 3, emaT) < 3) return 0;

   double close1 = iClose(_Symbol, PERIOD_M1, 1);

   bool buy  = (rsi[3] < InpRSI_OS) && (rsi[2] < InpRSI_OS) &&
               (rsi[1] > InpRSI_OS) && (close1 > emaT[1]);
   bool sell = (rsi[3] > InpRSI_OB) && (rsi[2] > InpRSI_OB) &&
               (rsi[1] < InpRSI_OB) && (close1 < emaT[1]);

   if(buy)  return 1;
   if(sell) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| SUB-ESTRATEGIA 4: Ruptura de Volatilidad con ATR                 |
//+------------------------------------------------------------------+
int Strategy4_ATRBreakout()
{
   double atr[], emaF[];
   ArraySetAsSeries(atr,  true);
   ArraySetAsSeries(emaF, true);

   if(CopyBuffer(handleATR,     0, 0, 4, atr)  < 4) return 0;
   if(CopyBuffer(handleEMAFast, 0, 0, 3, emaF) < 3) return 0;

   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double open1  = iOpen(_Symbol,  PERIOD_M1, 1);
   double close2 = iClose(_Symbol, PERIOD_M1, 2);
   double open2  = iOpen(_Symbol,  PERIOD_M1, 2);

   double body1     = close1 - open1;
   double body2     = close2 - open2;
   double atrThresh = atr[1] * 0.6;

   bool buy  = (body1 > atrThresh)  && (body2 > 0) &&
               (close1 > emaF[1])   && (atr[1] > atr[2]);
   bool sell = (-body1 > atrThresh) && (body2 < 0) &&
               (close1 < emaF[1])   && (atr[1] > atr[2]);

   if(buy)  return 1;
   if(sell) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| SUB-ESTRATEGIA 5: Pin Bar / Rechazo de Precio                    |
//+------------------------------------------------------------------+
int Strategy5_PinBar()
{
   double emaT[];
   ArraySetAsSeries(emaT, true);
   if(CopyBuffer(handleEMATrend, 0, 0, 3, emaT) < 3) return 0;

   double open1  = iOpen(_Symbol,  PERIOD_M1, 1);
   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double high1  = iHigh(_Symbol,  PERIOD_M1, 1);
   double low1   = iLow(_Symbol,   PERIOD_M1, 1);

   double body      = MathAbs(close1 - open1);
   double range     = high1 - low1;
   if(range == 0.0) return 0;
   double upperWick = high1 - MathMax(open1, close1);
   double lowerWick = MathMin(open1, close1) - low1;

   // Pin bar alcista: mecha inferior larga, precio sobre EMA tendencia
   bool buyPin  = (lowerWick >= 2.0 * body) && (upperWick <= 0.5 * body) &&
                  (lowerWick / range >= 0.55) && (close1 > emaT[1]);
   // Pin bar bajista: mecha superior larga, precio bajo EMA tendencia
   bool sellPin = (upperWick >= 2.0 * body) && (lowerWick <= 0.5 * body) &&
                  (upperWick / range >= 0.55) && (close1 < emaT[1]);

   if(buyPin)  return 1;
   if(sellPin) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| SUB-ESTRATEGIA 6: Compresión de BB (Squeeze) + Ruptura           |
//+------------------------------------------------------------------+
int Strategy6_BBSqueeze()
{
   double bbUp[], bbMid[], bbLow[], emaF[];
   ArraySetAsSeries(bbUp,  true);
   ArraySetAsSeries(bbMid, true);
   ArraySetAsSeries(bbLow, true);
   ArraySetAsSeries(emaF,  true);

   if(CopyBuffer(handleBB,      UPPER_BAND, 0, 5, bbUp)  < 5) return 0;
   if(CopyBuffer(handleBB,      BASE_LINE,  0, 5, bbMid) < 5) return 0;
   if(CopyBuffer(handleBB,      LOWER_BAND, 0, 5, bbLow) < 5) return 0;
   if(CopyBuffer(handleEMAFast, 0,          0, 3, emaF)  < 3) return 0;

   double bw1 = bbUp[1] - bbLow[1]; // Ancho actual
   double bw3 = bbUp[3] - bbLow[3]; // Ancho hace 2 velas
   double bw4 = bbUp[4] - bbLow[4]; // Ancho hace 3 velas

   // Squeeze: bandas comprimiéndose
   bool squeeze = (bw1 < bw3) && (bw1 < bw4);
   if(!squeeze) return 0;

   double close1 = iClose(_Symbol, PERIOD_M1, 1);
   double close2 = iClose(_Symbol, PERIOD_M1, 2);

   bool buy  = (close1 > bbMid[1]) && (close2 <= bbMid[2]) && (close1 > emaF[1]);
   bool sell = (close1 < bbMid[1]) && (close2 >= bbMid[2]) && (close1 < emaF[1]);

   if(buy)  return 1;
   if(sell) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| Calcula lote adaptativo (riesgo fijo + ajuste por ATR)           |
//+------------------------------------------------------------------+
double CalcAdaptiveLot(double slPrice, double atrValue)
{
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt   = balance * InpRiskPercent / 100.0;
   double tickVal   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickVal <= 0.0 || tickSz <= 0.0 || slPrice <= 0.0) return minLot;

   double lot = riskAmt / (slPrice * tickVal / tickSz);

   // Ajuste adaptativo: si ATR es alto, reducir lote para compensar volatilidad
   double avgSlPrice = InpStopLossPips * pipSize;
   if(avgSlPrice > 0.0)
   {
      double atrRatio = atrValue / (avgSlPrice * 2.0);
      if(atrRatio > 1.0) lot /= atrRatio; // Reducir en alta volatilidad
   }

   lot = MathFloor(lot / lotStep) * lotStep;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   return lot;
}

//+------------------------------------------------------------------+
//| Coloca órdenes de Grid en dirección indicada                      |
//+------------------------------------------------------------------+
void PlaceGridOrders(int direction, double basePrice, double baseLot)
{
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotSt  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double step   = InpGridStepPips * pipSize;
   double sl     = InpStopLossPips * pipSize;
   double tp     = InpTakeProfitPips * pipSize;

   for(int i = 1; i <= InpGridLevels; i++)
   {
      double gridLot = MathFloor((baseLot * MathPow(InpGridLotMulti, i)) / lotSt) * lotSt;
      gridLot = MathMax(minLot, gridLot);

      if(direction == 1)
      {
         double price = NormalizeDouble(basePrice - i * step, _Digits);
         double gsl   = NormalizeDouble(price - sl, _Digits);
         double gtp   = NormalizeDouble(price + tp, _Digits);
         if(price > 0 && gsl > 0)
            trade.BuyLimit(gridLot, price, _Symbol, gsl, gtp,
                           ORDER_TIME_GTC, 0, "QQ_GRID_BUY_" + IntegerToString(i));
      }
      else
      {
         double price = NormalizeDouble(basePrice + i * step, _Digits);
         double gsl   = NormalizeDouble(price + sl, _Digits);
         double gtp   = NormalizeDouble(price - tp, _Digits);
         if(gtp > 0)
            trade.SellLimit(gridLot, price, _Symbol, gsl, gtp,
                            ORDER_TIME_GTC, 0, "QQ_GRID_SELL_" + IntegerToString(i));
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing Stop adaptativo                                          |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   double trailStart = InpTrailStartPips * pipSize;
   double trailStep  = InpTrailStepPips  * pipSize;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagicNumber) continue;

      double sl       = posInfo.StopLoss();
      double openPr   = posInfo.PriceOpen();
      double curPr    = posInfo.PriceCurrent();
      ulong  ticket   = posInfo.Ticket();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         double profit = curPr - openPr;
         if(profit >= trailStart)
         {
            double newSL = NormalizeDouble(curPr - trailStep, _Digits);
            if(newSL > sl + trailStep)
               trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
         }
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double profit = openPr - curPr;
         if(profit >= trailStart)
         {
            double newSL = NormalizeDouble(curPr + trailStep, _Digits);
            if(sl == 0.0 || newSL < sl - trailStep)
               trade.PositionModify(ticket, newSL, posInfo.TakeProfit());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Cierra todas las posiciones                                        |
//+------------------------------------------------------------------+
void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         trade.PositionClose(posInfo.Ticket());
   }
}

//+------------------------------------------------------------------+
//| Cuenta posiciones abiertas del EA                                 |
//+------------------------------------------------------------------+
int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagicNumber)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Verifica si estamos en sesión activa (Londres o Nueva York)       |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int hourGMT = dt.hour;

   bool londonOpen = (hourGMT >= InpLondonOpen) && (hourGMT < InpNYOpen);
   bool nyOpen     = (hourGMT >= InpNYOpen)     && (hourGMT < InpSessionClose);
   return (londonOpen || nyOpen);
}

//+------------------------------------------------------------------+
//| Detecta nueva vela M1                                             |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime curBar = iTime(_Symbol, PERIOD_M1, 0);
   if(curBar != lastBarTime)
   {
      lastBarTime = curBar;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+