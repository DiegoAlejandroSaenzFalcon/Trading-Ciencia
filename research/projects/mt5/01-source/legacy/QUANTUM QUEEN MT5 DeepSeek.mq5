//+------------------------------------------------------------------+
//|                                                   QuantumQueenMT5.mq5 |
//|                        Copyright 2024, Bogdan Ion Puscasu Replica |
//|                                     https://github.com/quantumqueen |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Quantum Queen Replica"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Quantum Queen MT5 - Multi-Strategy Scalping EA for XAUUSD"
#property description "Utiliza 6 sub-estrategias integradas con gestión adaptativa de riesgo"
#property strict

//--- Input parameters
input group "=== CONFIGURACIÓN GENERAL ==="
input ulong MagicNumber = 2024001;           // Número Mágico
input string TradeComment = "QuantumQueen";  // Comentario de operaciones
input ENUM_TIMEFRAMES Timeframe = PERIOD_M1; // Timeframe Principal

input group "=== GESTIÓN DE RIESGO ==="
input double RiskPercent = 2.0;               // % de Riesgo por operación
input double FixedLotSize = 0.0;               // Lote fijo (0 = usar % riesgo)
input bool UseAutoLot = true;                   // Usar lote automático
input double MaxSpread = 30.0;                   // Spread máximo permitido (pips)
input int Slippage = 10;                         // Deslizamiento permitido (puntos)

input group "=== SUB-ESTRATEGIA 1: EMA CROSS ==="
input int FastEMA = 8;                           // EMA rápida
input int SlowEMA = 21;                           // EMA lenta
input double EMATrendStrength = 1.5;               // Fuerza tendencia EMA

input group "=== SUB-ESTRATEGIA 2: RSI MOMENTUM ==="
input int RSIPeriod = 14;                         // Período RSI
input int RSIOversold = 30;                        // Nivel sobreventa
input int RSIOverbought = 70;                      // Nivel sobrecompra

input group "=== SUB-ESTRATEGIA 3: MACD DIVERGENCE ==="
input int FastMACD = 12;                           // MACD rápido
input int SlowMACD = 26;                           // MACD lento
input int SignalMACD = 9;                          // Señal MACD

input group "=== SUB-ESTRATEGIA 4: BOLLINGER SQUEEZE ==="
input int BBPeriod = 20;                           // Período Bollinger
input double BBDeviation = 2.0;                    // Desviación Bollinger
input double SqueezeThreshold = 0.5;                // Umbral squeeze

input group "=== SUB-ESTRATEGIA 5: VOLATILITY BREAKOUT ==="
input int ATRPeriod = 14;                           // Período ATR
input double ATRMultiplier = 1.5;                    // Multiplicador ATR

input group "=== SUB-ESTRATEGIA 6: SUPPORT/RESISTANCE ==="
input int SRPeriod = 50;                            // Período S/R
input double SRDistance = 0.0010;                    // Distancia mínima S/R

input group "=== GESTIÓN DE POSICIONES ==="
input double GridStep = 50;                          // Paso de grid (puntos)
input int MaxGridLevels = 3;                          // Niveles máximos grid
input double TrailingStop = 20;                       // Trailing Stop (puntos)
input double TrailingStep = 5;                        // Paso trailing
input bool UseBreakEven = true;                       // Usar Break Even
input double BreakEvenPips = 30;                      // Pips para Break Even

input group "=== FILTROS DE TIEMPO ==="
input bool UseTimeFilter = false;                     // Usar filtro horario
input int StartHour = 8;                               // Hora inicio (hora servidor)
input int StartMinute = 0;                             // Minuto inicio
input int EndHour = 20;                                // Hora fin
input int EndMinute = 0;                               // Minuto fin

input group "=== PROTECCIÓN ==="
input int MaxSpreadProtection = 50;                    // Spread máximo (puntos)
input double MaxDailyLoss = 500;                       // Pérdida máxima diaria ($)
input int MaxDailyTrades = 20;                         // Operaciones máximas diarias

//--- Global variables
int handleFastEMA, handleSlowEMA;
int handleRSI;
int handleMACD;
int handleBB, handleATR;
double emaFast[], emaSlow[], rsi[], macd[], macdSignal[], bbUpper[], bbLower[], bbMiddle[], atr[];
double closePrices[], highPrices[], lowPrices[], openPrices[];
datetime lastTradeTime = 0;
double dailyLoss = 0;
int dailyTrades = 0;
double accountStartBalance;
datetime lastDayReset;

//--- Grid management
struct GridLevel {
   double price;
   double lotSize;
   ulong ticket;
   bool active;
};
GridLevel buyGrid[];
GridLevel sellGrid[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   //--- Verificar símbolo
   if(_Symbol != "XAUUSD" && _Symbol != "GOLD") {
      Print("Este EA está optimizado para XAUUSD. Símbolo actual: ", _Symbol);
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   //--- Crear handles de indicadores
   handleFastEMA = iMA(_Symbol, Timeframe, FastEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleSlowEMA = iMA(_Symbol, Timeframe, SlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI = iRSI(_Symbol, Timeframe, RSIPeriod, PRICE_CLOSE);
   handleMACD = iMACD(_Symbol, Timeframe, FastMACD, SlowMACD, SignalMACD, PRICE_CLOSE);
   handleBB = iBands(_Symbol, Timeframe, BBPeriod, 0, BBDeviation, PRICE_CLOSE);
   handleATR = iATR(_Symbol, Timeframe, ATRPeriod);
   
   if(handleFastEMA == INVALID_HANDLE || handleSlowEMA == INVALID_HANDLE || 
      handleRSI == INVALID_HANDLE || handleMACD == INVALID_HANDLE ||
      handleBB == INVALID_HANDLE || handleATR == INVALID_HANDLE) {
      Print("Error creando handles de indicadores");
      return(INIT_FAILED);
   }
   
   //--- Inicializar buffers
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(macd, true);
   ArraySetAsSeries(macdSignal, true);
   ArraySetAsSeries(bbUpper, true);
   ArraySetAsSeries(bbLower, true);
   ArraySetAsSeries(bbMiddle, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(closePrices, true);
   ArraySetAsSeries(highPrices, true);
   ArraySetAsSeries(lowPrices, true);
   ArraySetAsSeries(openPrices, true);
   
   //--- Inicializar gestión de grid
   ArrayResize(buyGrid, MaxGridLevels);
   ArrayResize(sellGrid, MaxGridLevels);
   for(int i = 0; i < MaxGridLevels; i++) {
      buyGrid[i].active = false;
      sellGrid[i].active = false;
      buyGrid[i].ticket = 0;
      sellGrid[i].ticket = 0;
   }
   
   accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastDayReset = TimeCurrent();
   
   Print("Quantum Queen MT5 inicializado correctamente en ", _Symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   //--- Liberar handles
   IndicatorRelease(handleFastEMA);
   IndicatorRelease(handleSlowEMA);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleMACD);
   IndicatorRelease(handleBB);
   IndicatorRelease(handleATR);
   
   Print("Quantum Queen MT5 desinicializado. Razón: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   //--- Actualizar contadores diarios
   ResetDailyCounters();
   
   //--- Verificar condiciones de trading
   if(!CanTrade()) return;
   
   //--- Actualizar datos de indicadores y precios
   if(!UpdateIndicators()) return;
   if(!UpdatePriceData()) return;
   
   //--- Gestionar posiciones abiertas
   ManagePositions();
   
   //--- Evaluar señales de las 6 sub-estrategias
   int signal = EvaluateStrategies();
   
   //--- Ejecutar trading según señal
   if(signal != 0) {
      ExecuteTrade(signal);
   }
   
   //--- Gestionar grid si es necesario
   ManageGrid();
}

//+------------------------------------------------------------------+
//| Reset daily counters                                            |
//+------------------------------------------------------------------+
void ResetDailyCounters() {
   datetime currentTime = TimeCurrent();
   MqlDateTime today, lastDay;
   TimeToStruct(currentTime, today);
   TimeToStruct(lastDayReset, lastDay);
   
   if(today.day != lastDay.day) {
      dailyLoss = 0;
      dailyTrades = 0;
      accountStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      lastDayReset = currentTime;
      
      // Resetear grid al inicio del día
      for(int i = 0; i < MaxGridLevels; i++) {
         buyGrid[i].active = false;
         sellGrid[i].active = false;
      }
   }
}

//+------------------------------------------------------------------+
//| Update price data                                                |
//+------------------------------------------------------------------+
bool UpdatePriceData() {
   if(CopyClose(_Symbol, Timeframe, 0, 5, closePrices) < 3) return false;
   if(CopyHigh(_Symbol, Timeframe, 0, 5, highPrices) < 3) return false;
   if(CopyLow(_Symbol, Timeframe, 0, 5, lowPrices) < 3) return false;
   if(CopyOpen(_Symbol, Timeframe, 0, 5, openPrices) < 3) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Check if we can trade                                           |
//+------------------------------------------------------------------+
bool CanTrade() {
   //--- Verificar spread
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > MaxSpreadProtection) {
      return false;
   }
   
   //--- Verificar límite diario de pérdidas
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double currentLoss = accountStartBalance - currentEquity;
   if(currentLoss > MaxDailyLoss) {
      return false;
   }
   
   //--- Verificar número máximo de operaciones diarias
   if(dailyTrades >= MaxDailyTrades) {
      return false;
   }
   
   //--- Verificar filtro de tiempo
   if(UseTimeFilter) {
      datetime currentTime = TimeCurrent();
      MqlDateTime timeStruct;
      TimeToStruct(currentTime, timeStruct);
      
      int currentMinutes = timeStruct.hour * 60 + timeStruct.min;
      int startMinutes = StartHour * 60 + StartMinute;
      int endMinutes = EndHour * 60 + EndMinute;
      
      if(currentMinutes < startMinutes || currentMinutes > endMinutes) {
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Update indicator values                                         |
//+------------------------------------------------------------------+
bool UpdateIndicators() {
   //--- Copiar valores de indicadores
   if(CopyBuffer(handleFastEMA, 0, 0, 5, emaFast) < 3) return false;
   if(CopyBuffer(handleSlowEMA, 0, 0, 5, emaSlow) < 3) return false;
   if(CopyBuffer(handleRSI, 0, 0, 5, rsi) < 3) return false;
   if(CopyBuffer(handleMACD, 0, 0, 5, macd) < 3) return false;
   if(CopyBuffer(handleMACD, 1, 0, 5, macdSignal) < 3) return false;
   if(CopyBuffer(handleBB, 0, 0, 5, bbMiddle) < 3) return false;
   if(CopyBuffer(handleBB, 1, 0, 5, bbUpper) < 3) return false;
   if(CopyBuffer(handleBB, 2, 0, 5, bbLower) < 3) return false;
   if(CopyBuffer(handleATR, 0, 0, 5, atr) < 3) return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| Evaluate all 6 strategies                                       |
//+------------------------------------------------------------------+
int EvaluateStrategies() {
   int buySignals = 0;
   int sellSignals = 0;
   double weightBuy = 0;
   double weightSell = 0;
   
   //--- Asegurar que tenemos suficientes datos
   if(ArraySize(emaFast) < 3 || ArraySize(emaSlow) < 3 || ArraySize(rsi) < 3 ||
      ArraySize(macd) < 3 || ArraySize(bbUpper) < 3 || ArraySize(atr) < 3 ||
      ArraySize(closePrices) < 3) {
      return 0;
   }
   
   //--- Estrategia 1: EMA Cross
   if(emaFast[0] > emaSlow[0] && emaFast[1] <= emaSlow[1]) {
      buySignals++;
      weightBuy += EMATrendStrength;
   }
   else if(emaFast[0] < emaSlow[0] && emaFast[1] >= emaSlow[1]) {
      sellSignals++;
      weightSell += EMATrendStrength;
   }
   
   //--- Estrategia 2: RSI Momentum
   if(rsi[0] < RSIOversold && rsi[1] >= RSIOversold) {
      buySignals++;
      weightBuy += 1.0;
   }
   else if(rsi[0] > RSIOverbought && rsi[1] <= RSIOverbought) {
      sellSignals++;
      weightSell += 1.0;
   }
   
   //--- Estrategia 3: MACD Divergence
   if(macd[0] > macdSignal[0] && macd[1] <= macdSignal[1]) {
      buySignals++;
      weightBuy += 1.2;
   }
   else if(macd[0] < macdSignal[0] && macd[1] >= macdSignal[1]) {
      sellSignals++;
      weightSell += 1.2;
   }
   
   //--- Estrategia 4: Bollinger Squeeze
   double bbWidth = (bbUpper[0] - bbLower[0]) / bbMiddle[0];
   double avgWidth = (bbUpper[1] - bbLower[1]) / bbMiddle[1];
   
   if(bbWidth < avgWidth * SqueezeThreshold && bbWidth < avgWidth) {
      // Señal de breakout
      if(closePrices[0] > bbUpper[1]) {
         buySignals++;
         weightBuy += 1.3;
      }
      else if(closePrices[0] < bbLower[1]) {
         sellSignals++;
         weightSell += 1.3;
      }
   }
   
   //--- Estrategia 5: Volatility Breakout
   double currentATR = atr[0];
   double rangeHigh = highPrices[1];
   double rangeLow = lowPrices[1];
   double breakLevel = rangeHigh + (currentATR * ATRMultiplier);
   
   if(closePrices[0] > breakLevel) {
      buySignals++;
      weightBuy += 1.4;
   }
   else if(closePrices[0] < rangeLow - (currentATR * ATRMultiplier)) {
      sellSignals++;
      weightSell += 1.4;
   }
   
   //--- Estrategia 6: Support/Resistance
   int highestIdx = iHighest(_Symbol, Timeframe, MODE_HIGH, SRPeriod, 1);
   int lowestIdx = iLowest(_Symbol, Timeframe, MODE_LOW, SRPeriod, 1);
   
   if(highestIdx >= 0 && lowestIdx >= 0) {
      double highSR = iHigh(_Symbol, Timeframe, highestIdx);
      double lowSR = iLow(_Symbol, Timeframe, lowestIdx);
      
      if(MathAbs(closePrices[0] - highSR) < SRDistance) {
         sellSignals++;
         weightSell += 1.1;
      }
      else if(MathAbs(closePrices[0] - lowSR) < SRDistance) {
         buySignals++;
         weightBuy += 1.1;
      }
   }
   
   //--- Decisión final basada en peso de señales
   if(buySignals >= 3 && weightBuy > weightSell) {
      return 1; // Señal de compra
   }
   else if(sellSignals >= 3 && weightSell > weightBuy) {
      return -1; // Señal de venta
   }
   
   return 0; // Sin señal clara
}

//+------------------------------------------------------------------+
//| Execute trade based on signal                                   |
//+------------------------------------------------------------------+
void ExecuteTrade(int signal) {
   //--- Calcular tamaño de lote
   double lotSize = CalculateLotSize();
   
   //--- Verificar si ya tenemos posición en dirección opuesta
   bool hasOppositePosition = false;
   ulong oppositeTicket = 0;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            
            if((signal > 0 && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL) ||
               (signal < 0 && PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)) {
               hasOppositePosition = true;
               oppositeTicket = ticket;
               break;
            }
         }
      }
   }
   
   //--- Si hay posición opuesta, cerrar primero
   if(hasOppositePosition) {
      ClosePosition(oppositeTicket);
   }
   
   //--- Abrir nueva posición
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.deviation = Slippage;
   request.magic = (uint)MagicNumber;
   request.comment = TradeComment;
   
   double gridStepPoints = GridStep * _Point;
   
   if(signal > 0) {
      request.type = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.sl = request.price - gridStepPoints * 2;
      request.tp = request.price + gridStepPoints * 4;
   } else {
      request.type = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      request.sl = request.price + gridStepPoints * 2;
      request.tp = request.price - gridStepPoints * 4;
   }
   
   if(OrderSend(request, result)) {
      if(result.retcode == TRADE_RETCODE_DONE) {
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         
         //--- Configurar grid inicial
         SetupGrid(signal, request.price);
         
         Print("Operación ejecutada. Ticket: ", result.order, " Señal: ", signal > 0 ? "BUY" : "SELL");
      } else {
         Print("Error ejecutando orden. Código: ", result.retcode);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk management                     |
//+------------------------------------------------------------------+
double CalculateLotSize() {
   if(FixedLotSize > 0) return FixedLotSize;
   if(!UseAutoLot) return 0.01;
   
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = accountBalance * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double stopLossPoints = GridStep * _Point * 2;
   
   double lotSize = riskAmount / (stopLossPoints / _Point * tickValue);
   
   //--- Ajustar a tamaño de lote permitido
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathMin(MathMax(lotSize, minLot), maxLot);
   lotSize = MathRound(lotSize / lotStep) * lotStep;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Setup grid levels for position management                       |
//+------------------------------------------------------------------+
void SetupGrid(int signal, double entryPrice) {
   double lotSize = CalculateLotSize();
   double step = GridStep * _Point;
   
   if(signal > 0) {
      // Configurar grid de compras
      for(int i = 0; i < MaxGridLevels; i++) {
         buyGrid[i].price = entryPrice - (i + 1) * step;
         buyGrid[i].lotSize = lotSize * (i + 1);
         buyGrid[i].active = true;
         buyGrid[i].ticket = 0;
      }
   } else {
      // Configurar grid de ventas
      for(int i = 0; i < MaxGridLevels; i++) {
         sellGrid[i].price = entryPrice + (i + 1) * step;
         sellGrid[i].lotSize = lotSize * (i + 1);
         sellGrid[i].active = true;
         sellGrid[i].ticket = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| Manage grid positions                                           |
//+------------------------------------------------------------------+
void ManageGrid() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   //--- Verificar activación de grid de compra
   for(int i = 0; i < MaxGridLevels; i++) {
      if(buyGrid[i].active && ask <= buyGrid[i].price) {
         // Activar nivel de grid
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_DEAL;
         request.symbol = _Symbol;
         request.volume = buyGrid[i].lotSize;
         request.type = ORDER_TYPE_BUY;
         request.price = ask;
         request.sl = ask - GridStep * _Point * 2;
         request.tp = ask + GridStep * _Point * 4;
         request.deviation = Slippage;
         request.magic = (uint)MagicNumber;
         request.comment = TradeComment + " Grid";
         
         if(OrderSend(request, result)) {
            if(result.retcode == TRADE_RETCODE_DONE) {
               buyGrid[i].ticket = result.order;
               buyGrid[i].active = false;
               Print("Grid BUY nivel ", i+1, " activado. Ticket: ", result.order);
            }
         }
      }
   }
   
   //--- Verificar activación de grid de venta
   for(int i = 0; i < MaxGridLevels; i++) {
      if(sellGrid[i].active && bid >= sellGrid[i].price) {
         // Activar nivel de grid
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_DEAL;
         request.symbol = _Symbol;
         request.volume = sellGrid[i].lotSize;
         request.type = ORDER_TYPE_SELL;
         request.price = bid;
         request.sl = bid + GridStep * _Point * 2;
         request.tp = bid - GridStep * _Point * 4;
         request.deviation = Slippage;
         request.magic = (uint)MagicNumber;
         request.comment = TradeComment + " Grid";
         
         if(OrderSend(request, result)) {
            if(result.retcode == TRADE_RETCODE_DONE) {
               sellGrid[i].ticket = result.order;
               sellGrid[i].active = false;
               Print("Grid SELL nivel ", i+1, " activado. Ticket: ", result.order);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage open positions                                           |
//+------------------------------------------------------------------+
void ManagePositions() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || 
            PositionGetInteger(POSITION_MAGIC) != MagicNumber) {
            continue;
         }
         
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 
                               SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                               SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         //--- Trailing Stop
         if(TrailingStop > 0) {
            double newSL = CalculateTrailingStop((int)PositionGetInteger(POSITION_TYPE), 
                                                openPrice, currentPrice);
            if(newSL != 0 && newSL != currentSL) {
               ModifyPositionSL(ticket, newSL);
            }
         }
         
         //--- Break Even
         if(UseBreakEven) {
            double profitInPips = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                                  (currentPrice - openPrice) / _Point :
                                  (openPrice - currentPrice) / _Point;
            
            if(profitInPips >= BreakEvenPips) {
               if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && currentSL < openPrice) ||
                  (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && currentSL > openPrice)) {
                  ModifyPositionSL(ticket, openPrice);
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate trailing stop level                                   |
//+------------------------------------------------------------------+
double CalculateTrailingStop(int positionType, double openPrice, double currentPrice) {
   double newSL = 0;
   double trailDistance = TrailingStop * _Point;
   double trailStep = TrailingStep * _Point;
   
   if(positionType == POSITION_TYPE_BUY) {
      if(currentPrice - openPrice >= trailDistance) {
         newSL = currentPrice - trailDistance;
         // Obtener SL actual
         double currentSL = PositionGetDouble(POSITION_SL);
         if(newSL > currentSL + trailStep) {
            return newSL;
         }
      }
   } else {
      if(openPrice - currentPrice >= trailDistance) {
         newSL = currentPrice + trailDistance;
         double currentSL = PositionGetDouble(POSITION_SL);
         if(newSL < currentSL - trailStep) {
            return newSL;
         }
      }
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Modify position stop loss                                       |
//+------------------------------------------------------------------+
void ModifyPositionSL(ulong ticket, double newSL) {
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_SLTP;
   request.symbol = _Symbol;
   request.sl = newSL;
   request.tp = PositionGetDouble(POSITION_TP);
   request.position = ticket;
   request.magic = (uint)MagicNumber;
   
   if(OrderSend(request, result)) {
      if(result.retcode == TRADE_RETCODE_DONE) {
         // Print("SL modificado para ticket ", ticket, " nuevo SL: ", newSL);
      }
   }
}

//+------------------------------------------------------------------+
//| Close a specific position                                       |
//+------------------------------------------------------------------+
void ClosePosition(ulong ticket) {
   if(PositionSelectByTicket(ticket)) {
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.symbol = _Symbol;
      request.volume = PositionGetDouble(POSITION_VOLUME);
      request.deviation = Slippage;
      request.magic = (uint)MagicNumber;
      request.position = ticket;
      
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
         request.type = ORDER_TYPE_SELL;
         request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      } else {
         request.type = ORDER_TYPE_BUY;
         request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
      
      if(OrderSend(request, result)) {
         if(result.retcode == TRADE_RETCODE_DONE) {
            Print("Posición cerrada. Ticket: ", result.order);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Get current spread in points                                     |
//+------------------------------------------------------------------+
double GetSpreadInPoints() {
   return (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
}
//+------------------------------------------------------------------+