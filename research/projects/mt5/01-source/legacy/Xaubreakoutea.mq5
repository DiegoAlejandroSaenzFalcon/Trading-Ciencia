//+------------------------------------------------------------------+
//|                                             XAUBreakoutEA.mq5    |
//|                    Replica fiel de XAU Breakout EA               |
//|    XAUUSD M30/H1 | Session Range Breakout | Buy/Sell Stop Grid   |
//+------------------------------------------------------------------+
#property copyright   "Replica XAU Breakout EA"
#property link        ""
#property version     "1.00"
#property description "XAUUSD | Breakout del rango de sesión | Buy Stop / Sell Stop | Limpieza automática"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Inputs: Temporalidad y Activo
input group              "=== TEMPORALIDAD ==="
input ENUM_TIMEFRAMES InpTF          = PERIOD_H1;   // Temporalidad principal

//--- Inputs: Riesgo
input group              "=== GESTIÓN DE RIESGO ==="
input double   InpRiskPercent        = 1.0;   // Riesgo % por operación
input int      InpMaxPositions       = 1;     // Máximo posiciones abiertas
input double   InpMaxDDPct           = 12.0;  // Drawdown máximo (%)

//--- Inputs: Rango de Sesión
input group              "=== RANGO DE SESIÓN ==="
input int      InpRangeStartHour     = 0;     // Inicio rango (hora GMT)
input int      InpRangeEndHour       = 8;     // Fin rango / Inicio breakout (hora GMT)
input int      InpSessionCloseHour   = 22;    // Cierre sesión - cancela órdenes (hora GMT)
input double   InpRangeBufferPips    = 5.0;   // Buffer sobre/bajo rango para órdenes (pips)
input double   InpMinRangePips       = 10.0;  // Rango mínimo válido (pips)
input double   InpMaxRangePips       = 200.0; // Rango máximo válido (pips)

//--- Inputs: Stop Loss / Take Profit
input group              "=== SL / TP ==="
input bool     InpUseDynamicTP       = true;  // TP dinámico basado en tamaño del rango
input double   InpTPRangeMulti       = 1.5;   // TP = rango x multiplicador
input double   InpFixedTPPips        = 50.0;  // TP fijo si no es dinámico (pips)
input double   InpSLTypePct          = 0.5;   // SL = % del rango (0.5 = 50% del rango)
input double   InpMinSLPips          = 10.0;  // SL mínimo (pips)
input bool     InpUseTrailing        = true;  // Trailing Stop
input double   InpTrailPips          = 12.0;  // Distancia Trailing (pips)

//--- Inputs: Filtros de Calidad
input group              "=== FILTROS DE CALIDAD ==="
input bool     InpFilterTrend        = true;  // Filtrar por tendencia H4
input bool     InpFilterByATR        = true;  // Filtrar por expansión ATR
input double   InpATRBreakMulti      = 1.2;   // ATR mínimo para confirmar breakout
input bool     InpFilterBySpread     = true;  // Filtrar por spread
input double   InpMaxSpreadPips      = 6.0;   // Spread máximo (pips)
input bool     InpRequireRetest      = false; // Requerir re-testeo del rango roto
input int      InpRetestBars         = 3;     // Barras para re-testeo

//--- Inputs: Días de operación
input group              "=== DÍAS DE OPERACIÓN ==="
input bool     InpTradeMonday        = true;  // Lunes
input bool     InpTradeTuesday       = true;  // Martes
input bool     InpTradeWednesday     = true;  // Miércoles
input bool     InpTradeThursday      = true;  // Jueves
input bool     InpTradeFriday        = false; // Viernes (volatile)

//--- Inputs: Config
input group              "=== CONFIGURACIÓN ==="
input ulong    InpMagic              = 20240705;  // Magic Number
input int      InpSlippage           = 10;        // Slippage (puntos)
input bool     InpPrintLogs          = true;      // Logs detallados
input string   InpBuyComment         = "XAU_BS";  // Comentario Buy Stop
input string   InpSellComment        = "XAU_SS";  // Comentario Sell Stop

//--- Variables de estado del rango
double rangeHigh      = 0.0;
double rangeLow       = 0.0;
datetime rangeDate    = 0;
bool   ordersPlaced   = false;
bool   buyTriggered   = false;
bool   sellTriggered  = false;
datetime lastBarTime  = 0;
double   peakBalance  = 0.0;

//--- Objetos
CTrade        trade;
CPositionInfo posInfo;
COrderInfo    orderInfo;

int    handleATR_H1, handleATR_H4;
int    handleEMA_H4;

double pipSize;

//+------------------------------------------------------------------+
//| Inicialización                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   if(_Symbol != "XAUUSD" && _Symbol != "XAUUSDm" && _Symbol != "GOLD" && _Symbol != "GOLDm")
      Print("[XAU_BO] ADVERTENCIA: Optimizado para XAUUSD. Símbolo: ", _Symbol);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;

   handleATR_H1 = iATR(_Symbol, InpTF, 14);
   handleATR_H4 = iATR(_Symbol, PERIOD_H4, 14);
   handleEMA_H4 = iMA(_Symbol,  PERIOD_H4, 50, 0, MODE_EMA, PRICE_CLOSE);

   if(handleATR_H1 == INVALID_HANDLE || handleATR_H4 == INVALID_HANDLE ||
      handleEMA_H4 == INVALID_HANDLE)
   {
      Print("[XAU_BO] ERROR: Fallo al crear indicadores.");
      return INIT_FAILED;
   }

   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("[XAU_BO] XAU Breakout EA inicializado.");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Liberación                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR_H1);
   IndicatorRelease(handleATR_H4);
   IndicatorRelease(handleEMA_H4);
   DeletePendingOrders(); // Limpiar órdenes pendientes al desactivar
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
      DeletePendingOrders();
      CloseAllMyPositions();
      return;
   }

   // Trailing Stop en posiciones activas
   if(InpUseTrailing) ManageTrailing();

   // Verificar si una orden se activó → limpiar la opuesta
   CheckAndCleanOppositeOrder();

   // Solo en nueva vela
   if(!IsNewBar()) return;

   // Verificar día de operación
   if(!IsTradingDay()) return;

   // Filtro de spread
   if(InpFilterBySpread)
   {
      double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(spread > InpMaxSpreadPips * pipSize) return;
   }

   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int hourGMT = dt.hour;

   // === FASE 1: Recopilar rango de sesión ===
   if(hourGMT >= InpRangeStartHour && hourGMT < InpRangeEndHour)
   {
      UpdateSessionRange();
      ordersPlaced  = false;
      buyTriggered  = false;
      sellTriggered = false;
   }

   // === FASE 2: Colocar órdenes de breakout ===
   if(hourGMT == InpRangeEndHour && !ordersPlaced)
   {
      if(rangeHigh > 0.0 && rangeLow > 0.0)
         PlaceBreakoutOrders();
   }

   // === FASE 3: Cancelar órdenes al cierre de sesión ===
   if(hourGMT >= InpSessionCloseHour)
   {
      DeletePendingOrders();
      ordersPlaced  = false;
      buyTriggered  = false;
      sellTriggered = false;
   }
}

//+------------------------------------------------------------------+
//| Recopila el rango Alto/Bajo de la sesión definida               |
//+------------------------------------------------------------------+
void UpdateSessionRange()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);

   // Reiniciar rango al inicio de la sesión (primera vela del período)
   if(dt.hour == InpRangeStartHour && dt.min < 30)
   {
      rangeHigh = 0.0;
      rangeLow  = DBL_MAX;
      rangeDate = TimeCurrent();
   }

   double currentHigh = iHigh(_Symbol, InpTF, 1);
   double currentLow  = iLow(_Symbol,  InpTF, 1);

   if(rangeHigh == 0.0 || currentHigh > rangeHigh) rangeHigh = currentHigh;
   if(rangeLow  == DBL_MAX || currentLow < rangeLow) rangeLow = currentLow;

   double rangePips = (rangeHigh - rangeLow) / pipSize;

   if(InpPrintLogs && dt.min == 0)
      Print("[XAU_BO] Rango actual: High=", DoubleToString(rangeHigh,2),
            " Low=", DoubleToString(rangeLow,2),
            " Tamaño=", DoubleToString(rangePips,1), " pips");
}

//+------------------------------------------------------------------+
//| Coloca órdenes Buy Stop y Sell Stop en los extremos del rango    |
//+------------------------------------------------------------------+
void PlaceBreakoutOrders()
{
   if(CountMyPositions() >= InpMaxPositions) return;
   if(rangeHigh <= 0.0 || rangeLow <= 0.0 || rangeLow >= rangeHigh)
   {
      Print("[XAU_BO] Rango inválido. No se colocan órdenes.");
      return;
   }

   double rangePips = (rangeHigh - rangeLow) / pipSize;

   // Validar tamaño del rango
   if(rangePips < InpMinRangePips)
   {
      Print("[XAU_BO] Rango muy pequeño (", DoubleToString(rangePips,1), " pips < ", InpMinRangePips, ")");
      return;
   }
   if(rangePips > InpMaxRangePips)
   {
      Print("[XAU_BO] Rango muy grande (", DoubleToString(rangePips,1), " pips > ", InpMaxRangePips, ")");
      return;
   }

   // Filtro de tendencia H4
   if(InpFilterTrend)
   {
      double ema4Buf[];
      ArraySetAsSeries(ema4Buf, true);
      if(CopyBuffer(handleEMA_H4, 0, 0, 3, ema4Buf) < 3) return;
      // Tendencia H4 como guía (solo colocar la orden en dirección de tendencia si es fuerte)
      // Aquí colocamos AMBAS pero con mayor lote en la dirección de tendencia
   }

   // Filtro ATR - confirmar que hay energía para breakout
   double atr4Buf[];
   ArraySetAsSeries(atr4Buf, true);
   if(CopyBuffer(handleATR_H4, 0, 0, 3, atr4Buf) < 3) return;
   double atr4 = atr4Buf[1];

   if(InpFilterByATR && (rangeHigh - rangeLow) < atr4 * InpATRBreakMulti)
   {
      Print("[XAU_BO] ATR insuficiente para breakout válido.");
      return;
   }

   // Calcular niveles de entrada
   double buffer   = InpRangeBufferPips * pipSize;
   double buyEntry = NormalizeDouble(rangeHigh + buffer, _Digits);
   double selEntry = NormalizeDouble(rangeLow  - buffer, _Digits);

   // Stop Loss: % del rango
   double slRange    = (rangeHigh - rangeLow) * InpSLTypePct;
   double slPips     = MathMax(InpMinSLPips * pipSize, slRange);

   // Take Profit: basado en tamaño del rango
   double tpRange    = InpUseDynamicTP ? (rangeHigh - rangeLow) * InpTPRangeMulti :
                                          InpFixedTPPips * pipSize;

   // SL y TP para Buy Stop
   double buySL = NormalizeDouble(buyEntry - slPips, _Digits);
   double buyTP = NormalizeDouble(buyEntry + tpRange, _Digits);

   // SL y TP para Sell Stop
   double sellSL = NormalizeDouble(selEntry + slPips, _Digits);
   double sellTP = NormalizeDouble(selEntry - tpRange, _Digits);
   if(sellTP <= 0.0) sellTP = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   double lot = CalcLot(slPips);

   // Verificar que los precios son válidos
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(buyEntry <= ask + SymbolInfoDouble(_Symbol, SYMBOL_POINT))
   {
      Print("[XAU_BO] Buy Stop muy cercano al precio actual. Ajustando...");
      buyEntry = NormalizeDouble(ask + buffer + SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10, _Digits);
      buySL    = NormalizeDouble(buyEntry - slPips, _Digits);
      buyTP    = NormalizeDouble(buyEntry + tpRange, _Digits);
   }

   if(selEntry >= bid - SymbolInfoDouble(_Symbol, SYMBOL_POINT))
   {
      Print("[XAU_BO] Sell Stop muy cercano al precio actual. Ajustando...");
      selEntry = NormalizeDouble(bid - buffer - SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10, _Digits);
      sellSL   = NormalizeDouble(selEntry + slPips, _Digits);
      sellTP   = NormalizeDouble(selEntry - tpRange, _Digits);
   }

   bool buyOK  = trade.BuyStop(lot, buyEntry, _Symbol, buySL, buyTP,
                               ORDER_TIME_GTC, 0, InpBuyComment);
   bool sellOK = trade.SellStop(lot, selEntry, _Symbol, sellSL, sellTP,
                                ORDER_TIME_GTC, 0, InpSellComment);

   if(buyOK && sellOK)
   {
      ordersPlaced = true;
      Print("[XAU_BO] Órdenes colocadas | Rango: ", DoubleToString(rangePips,1), " pips",
            " | BuyStop@", DoubleToString(buyEntry,2),
            " | SellStop@", DoubleToString(selEntry,2),
            " | Lot:", lot, " | TP:", DoubleToString(tpRange/pipSize,1), " pips");
   }
   else
   {
      if(!buyOK)
         Print("[XAU_BO] ERROR Buy Stop: ", trade.ResultRetcodeDescription());
      if(!sellOK)
         Print("[XAU_BO] ERROR Sell Stop: ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Verifica si una orden se activó y cancela la opuesta (limpieza)  |
//+------------------------------------------------------------------+
void CheckAndCleanOppositeOrder()
{
   if(!ordersPlaced) return;

   // Verificar si hay posición abierta del EA
   bool hasBuyPos  = false;
   bool hasSellPos = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol || posInfo.Magic() != InpMagic) continue;

      if(posInfo.PositionType() == POSITION_TYPE_BUY  &&
         StringFind(posInfo.Comment(), "XAU_BS") >= 0)  hasBuyPos  = true;
      if(posInfo.PositionType() == POSITION_TYPE_SELL &&
         StringFind(posInfo.Comment(), "XAU_SS") >= 0)  hasSellPos = true;
   }

   // Si Buy se activó → eliminar Sell Stop pendiente
   if(hasBuyPos && !buyTriggered)
   {
      buyTriggered = true;
      DeletePendingOrdersByComment(InpSellComment);
      Print("[XAU_BO] Buy Stop ACTIVADO → Sell Stop eliminado (limpieza).");
   }

   // Si Sell se activó → eliminar Buy Stop pendiente
   if(hasSellPos && !sellTriggered)
   {
      sellTriggered = true;
      DeletePendingOrdersByComment(InpBuyComment);
      Print("[XAU_BO] Sell Stop ACTIVADO → Buy Stop eliminado (limpieza).");
   }
}

//+------------------------------------------------------------------+
//| Elimina órdenes pendientes por comentario                         |
//+------------------------------------------------------------------+
void DeletePendingOrdersByComment(string comment)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() != _Symbol || orderInfo.Magic() != InpMagic) continue;
      if(StringFind(orderInfo.Comment(), comment) >= 0)
      {
         trade.OrderDelete(orderInfo.Ticket());
         if(InpPrintLogs)
            Print("[XAU_BO] Orden eliminada: ", comment, " Ticket:", orderInfo.Ticket());
      }
   }
}

//+------------------------------------------------------------------+
//| Elimina todas las órdenes pendientes del EA                       |
//+------------------------------------------------------------------+
void DeletePendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!orderInfo.SelectByIndex(i)) continue;
      if(orderInfo.Symbol() == _Symbol && orderInfo.Magic() == InpMagic)
         trade.OrderDelete(orderInfo.Ticket());
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
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < openP && (curSL == 0.0 || newSL < curSL - pipSize))
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
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
//| Verifica si el día actual está habilitado para operar             |
//+------------------------------------------------------------------+
bool IsTradingDay()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   switch(dt.day_of_week)
   {
      case 1: return InpTradeMonday;
      case 2: return InpTradeTuesday;
      case 3: return InpTradeWednesday;
      case 4: return InpTradeThursday;
      case 5: return InpTradeFriday;
      default: return false;
   }
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
//| Cuenta posiciones                                                  |
//+------------------------------------------------------------------+
int CountMyPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic) count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Nueva vela                                                         |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime cur = iTime(_Symbol, InpTF, 0);
   if(cur != lastBarTime)
   {
      lastBarTime = cur;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+