//+------------------------------------------------------------------+
//|                                                        AkaliEA.mq5 |
//|                      Copyright 2024, Yahia Mohamed Hassan Replica |
//|                                     https://github.com/akaliea |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Akali EA Replica"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Akali EA - High Precision Scalping for XAUUSD"
#property description "Algoritmo de Trailing Stop extremadamente ajustado"

//--- Input parameters
input group "=== CONFIGURACIÓN PRINCIPAL ==="
input ulong MagicNumber = 2024002;           // Número Mágico
input string TradeComment = "AkaliEA";        // Comentario
input ENUM_TIMEFRAMES Timeframe = PERIOD_M1;  // Timeframe principal

input group "=== GESTIÓN DE RIESGO ==="
input double RiskPercent = 1.5;                // % Riesgo por operación
input double MaxSpread = 20.0;                  // Spread máximo (puntos)
input int Slippage = 5;                         // Deslizamiento permitido

input group "=== ESTRATEGIA DE SCALPING ==="
input int TickFilter = 5;                        // Número de ticks para confirmación
input double MomentumThreshold = 0.5;             // Umbral de momentum (pips)
input int VolumeSpike = 150;                      // Spike de volumen (%)
input int RSIScalpPeriod = 7;                     // Período RSI para scalping
input int RSIEntryLevel = 25;                      // Nivel RSI para entrada

input group "=== TRAILING STOP ULTRA AJUSTADO ==="
input int InitialStopPips = 3;                    // Stop loss inicial (pips)
input int TrailingStartPips = 2;                   // Pips para iniciar trailing
input int TrailingStepPips = 1;                    // Paso del trailing (pips)
input int MinTrailingDistance = 1;                  // Distancia mínima trailing

input group "=== TOMA DE GANANCIAS ==="
input bool UseFixedTP = false;                     // Usar TP fijo
input int FixedTPPips = 5;                         // TP fijo en pips
input bool UseDynamicTP = true;                     // Usar TP dinámico
input double RiskRewardRatio = 1.5;                 // Ratio Riesgo/Recompensa

input group "=== FILTROS ADICIONALES ==="
input bool UseNewsFilter = true;                    // Filtrar noticias
input int MinutesBeforeNews = 5;                    // Minutos antes de noticias
input int MinutesAfterNews = 5;                     // Minutos después de noticias
input double MaxVolatility = 50.0;                   // Volatilidad máxima (pips)

input group "=== LÍMITES ==="
input int MaxPositions = 3;                          // Máximo posiciones simultáneas
input int MaxTradesPerMinute = 2;                    // Máx operaciones por minuto

//--- Global variables
int handleRSI;
int handleATR;
double rsiBuffer[], atrBuffer[];
double closePrices[], openPrices[], highPrices[], lowPrices[];
datetime lastTradeTimes[10];
int lastTradeIndex = 0;
int currentPositions = 0;
double entryPrices[];

//--- Estructura para trailing dinámico
struct TrailingInfo {
   double highestPrice;
   double lowestPrice;
   double trailingLevel;
   bool trailingActive;
};
TrailingInfo trailingData[];

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   //--- Verificar símbolo
   if(_Symbol != "XAUUSD" && _Symbol != "GOLD") {
      Print("Akali EA optimizado para XAUUSD. Símbolo actual: ", _Symbol);
      return(INIT_PARAMETERS_INCORRECT);
   }
   
   //--- Crear handles
   handleRSI = iRSI(_Symbol, Timeframe, RSIScalpPeriod, PRICE_CLOSE);
   handleATR = iATR(_Symbol, Timeframe, 14);
   
   if(handleRSI == INVALID_HANDLE || handleATR == INVALID_HANDLE) {
      Print("Error creando handles de indicadores");
      return(INIT_FAILED);
   }
   
   //--- Inicializar arrays
   ArraySetAsSeries(rsiBuffer, true);
   ArraySetAsSeries(atrBuffer, true);
   ArraySetAsSeries(closePrices, true);
   ArraySetAsSeries(openPrices, true);
   ArraySetAsSeries(highPrices, true);
   ArraySetAsSeries(lowPrices, true);
   ArrayResize(trailingData, MaxPositions);
   ArrayResize(entryPrices, MaxPositions);
   
   for(int i = 0; i < MaxPositions; i++) {
      trailingData[i].trailingActive = false;
      entryPrices[i] = 0;
      trailingData[i].highestPrice = 0;
      trailingData[i].lowestPrice = 0;
      trailingData[i].trailingLevel = 0;
   }
   
   //--- Inicializar array de tiempos
   for(int i = 0; i < 10; i++) {
      lastTradeTimes[i] = 0;
   }
   
   Print("Akali EA inicializado correctamente");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleATR);
   Print("Akali EA desinicializado");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   //--- Actualizar datos de precios
   if(!UpdatePriceData()) return;
   
   //--- Actualizar contador de posiciones
   UpdatePositionCount();
   
   //--- Verificar condiciones de trading
   if(!CanScalp()) return;
   
   //--- Actualizar indicadores
   if(!UpdateIndicators()) return;
   
   //--- Gestionar trailing de posiciones abiertas
   ManageUltraTrailing();
   
   //--- Buscar oportunidades de scalping
   if(currentPositions < MaxPositions) {
      FindScalpOpportunities();
   }
}

//+------------------------------------------------------------------+
//| Update price data                                                |
//+------------------------------------------------------------------+
bool UpdatePriceData() {
   if(CopyClose(_Symbol, Timeframe, 0, 5, closePrices) < 3) return false;
   if(CopyOpen(_Symbol, Timeframe, 0, 5, openPrices) < 3) return false;
   if(CopyHigh(_Symbol, Timeframe, 0, 5, highPrices) < 3) return false;
   if(CopyLow(_Symbol, Timeframe, 0, 5, lowPrices) < 3) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Update position count                                           |
//+------------------------------------------------------------------+
void UpdatePositionCount() {
   currentPositions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            
            if(currentPositions < MaxPositions) {
               entryPrices[currentPositions] = PositionGetDouble(POSITION_PRICE_OPEN);
            }
            currentPositions++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check if we can scalp                                           |
//+------------------------------------------------------------------+
bool CanScalp() {
   //--- Verificar spread
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - 
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / _Point;
   if(spread > MaxSpread) {
      return false;
   }
   
   //--- Verificar volatilidad
   if(ArraySize(atrBuffer) > 0) {
      double atr = atrBuffer[0] / _Point;
      if(atr > MaxVolatility) {
         return false;
      }
   }
   
   //--- Verificar límite de operaciones por minuto
   datetime currentTime = TimeCurrent();
   int tradesInLastMinute = 0;
   
   for(int i = 0; i < 10; i++) {
      if(lastTradeTimes[i] > 0 && currentTime - lastTradeTimes[i] < 60) {
         tradesInLastMinute++;
      }
   }
   
   if(tradesInLastMinute >= MaxTradesPerMinute) {
      return false;
   }
   
   //--- Verificar filtro de noticias (simulado)
   if(UseNewsFilter) {
      if(IsNewsTime()) {
         return false;
      }
   }
   
   return true;
}

//+------------------------------------------------------------------+
//| Update indicator values                                         |
//+------------------------------------------------------------------+
bool UpdateIndicators() {
   if(CopyBuffer(handleRSI, 0, 0, 5, rsiBuffer) < 3) return false;
   if(CopyBuffer(handleATR, 0, 0, 5, atrBuffer) < 3) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Find scalp opportunities                                        |
//+------------------------------------------------------------------+
void FindScalpOpportunities() {
   //--- Verificar que tenemos suficientes datos
   if(ArraySize(closePrices) < 3 || ArraySize(openPrices) < 3 || 
      ArraySize(highPrices) < 3 || ArraySize(lowPrices) < 3) return;
   
   //--- Análisis de volumen en tiempo real
   long tickVolume = 0;
   for(int i = 0; i < TickFilter; i++) {
      tickVolume += iVolume(_Symbol, Timeframe, i);
   }
   long avgVolume = iVolume(_Symbol, Timeframe, TickFilter) * TickFilter;
   double volumeRatio = (avgVolume > 0) ? (double)tickVolume / avgVolume * 100 : 0;
   
   //--- Momentum del precio
   double priceChange = (closePrices[0] - openPrices[0]) / _Point;
   double momentum = MathAbs(priceChange);
   
   //--- Condiciones para entrada LONG
   if(CanEnterLong(volumeRatio, momentum)) {
      EnterLong();
   }
   //--- Condiciones para entrada SHORT
   else if(CanEnterShort(volumeRatio, momentum)) {
      EnterShort();
   }
}

//+------------------------------------------------------------------+
//| Check if can enter long                                         |
//+------------------------------------------------------------------+
bool CanEnterLong(double volumeRatio, double momentum) {
   if(ArraySize(rsiBuffer) < 2) return false;
   
   //--- Condiciones de scalping LONG
   bool volumeCondition = volumeRatio > VolumeSpike;
   bool momentumCondition = momentum >= MomentumThreshold;
   bool rsiCondition = rsiBuffer[0] < RSIEntryLevel;
   bool priceAction = closePrices[0] > openPrices[0] && closePrices[0] > highPrices[1];
   
   return volumeCondition && momentumCondition && rsiCondition && priceAction;
}

//+------------------------------------------------------------------+
//| Check if can enter short                                        |
//+------------------------------------------------------------------+
bool CanEnterShort(double volumeRatio, double momentum) {
   if(ArraySize(rsiBuffer) < 2) return false;
   
   //--- Condiciones de scalping SHORT
   bool volumeCondition = volumeRatio > VolumeSpike;
   bool momentumCondition = momentum >= MomentumThreshold;
   bool rsiCondition = rsiBuffer[0] > (100 - RSIEntryLevel);
   bool priceAction = closePrices[0] < openPrices[0] && closePrices[0] < lowPrices[1];
   
   return volumeCondition && momentumCondition && rsiCondition && priceAction;
}

//+------------------------------------------------------------------+
//| Enter long position                                             |
//+------------------------------------------------------------------+
void EnterLong() {
   //--- Calcular tamaño de lote
   double lotSize = CalculateLotSize();
   
   //--- Calcular stop loss inicial (muy ajustado)
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double stopLoss = entryPrice - InitialStopPips * _Point;
   double takeProfit = entryPrice + CalculateTakeProfit(entryPrice, stopLoss);
   
   //--- Verificar distancia mínima SL
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(entryPrice - stopLoss < stopsLevel * _Point) {
      Print("SL demasiado cercano, ajustando...");
      stopLoss = entryPrice - (stopsLevel + 5) * _Point;
   }
   
   //--- Enviar orden
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_BUY;
   request.price = entryPrice;
   request.sl = stopLoss;
   request.tp = takeProfit;
   request.deviation = Slippage;
   request.magic = (uint)MagicNumber;
   request.comment = TradeComment;
   
   if(OrderSend(request, result)) {
      if(result.retcode == TRADE_RETCODE_DONE) {
         //--- Registrar tiempo de trade
         lastTradeTimes[lastTradeIndex] = TimeCurrent();
         lastTradeIndex = (lastTradeIndex + 1) % 10;
         
         //--- Inicializar trailing para esta posición
         for(int i = 0; i < MaxPositions; i++) {
            if(!trailingData[i].trailingActive) {
               trailingData[i].highestPrice = entryPrice;
               trailingData[i].trailingActive = true;
               trailingData[i].trailingLevel = stopLoss;
               break;
            }
         }
         
         Print("Scalp LONG ejecutado. Ticket: ", result.order, 
               " Lote: ", lotSize, " SL: ", stopLoss, " TP: ", takeProfit);
      } else {
         Print("Error en entrada LONG. Código: ", result.retcode);
      }
   }
}

//+------------------------------------------------------------------+
//| Enter short position                                            |
//+------------------------------------------------------------------+
void EnterShort() {
   //--- Calcular tamaño de lote
   double lotSize = CalculateLotSize();
   
   //--- Calcular stop loss inicial (muy ajustado)
   double entryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double stopLoss = entryPrice + InitialStopPips * _Point;
   double takeProfit = entryPrice - CalculateTakeProfit(entryPrice, stopLoss);
   
   //--- Verificar distancia mínima SL
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopLoss - entryPrice < stopsLevel * _Point) {
      Print("SL demasiado cercano, ajustando...");
      stopLoss = entryPrice + (stopsLevel + 5) * _Point;
   }
   
   //--- Enviar orden
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = lotSize;
   request.type = ORDER_TYPE_SELL;
   request.price = entryPrice;
   request.sl = stopLoss;
   request.tp = takeProfit;
   request.deviation = Slippage;
   request.magic = (uint)MagicNumber;
   request.comment = TradeComment;
   
   if(OrderSend(request, result)) {
      if(result.retcode == TRADE_RETCODE_DONE) {
         //--- Registrar tiempo de trade
         lastTradeTimes[lastTradeIndex] = TimeCurrent();
         lastTradeIndex = (lastTradeIndex + 1) % 10;
         
         //--- Inicializar trailing para esta posición
         for(int i = 0; i < MaxPositions; i++) {
            if(!trailingData[i].trailingActive) {
               trailingData[i].lowestPrice = entryPrice;
               trailingData[i].trailingActive = true;
               trailingData[i].trailingLevel = stopLoss;
               break;
            }
         }
         
         Print("Scalp SHORT ejecutado. Ticket: ", result.order, 
               " Lote: ", lotSize, " SL: ", stopLoss, " TP: ", takeProfit);
      } else {
         Print("Error en entrada SHORT. Código: ", result.retcode);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                |
//+------------------------------------------------------------------+
double CalculateLotSize() {
   double accountBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = accountBalance * RiskPercent / 100.0;
   double stopLossPoints = InitialStopPips * _Point;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   
   double lotSize = riskAmount / (stopLossPoints / _Point * tickValue);
   
   //--- Ajustar tamaño
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathMin(MathMax(lotSize, minLot), maxLot);
   lotSize = MathRound(lotSize / lotStep) * lotStep;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Calculate take profit                                           |
//+------------------------------------------------------------------+
double CalculateTakeProfit(double entryPrice, double stopLoss) {
   double risk = MathAbs(entryPrice - stopLoss);
   
   if(UseFixedTP) {
      return FixedTPPips * _Point;
   } else if(UseDynamicTP) {
      return risk * RiskRewardRatio;
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//| Manage ultra trailing stop                                      |
//+------------------------------------------------------------------+
void ManageUltraTrailing() {
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   int positionIndex = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
            
            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentSL = PositionGetDouble(POSITION_SL);
            int positionType = (int)PositionGetInteger(POSITION_TYPE);
            
            if(positionType == POSITION_TYPE_BUY) {
               if(positionIndex < MaxPositions) {
                  ManageBuyTrailing(positionIndex, openPrice, currentSL, ask, bid, ticket);
               }
            } else {
               if(positionIndex < MaxPositions) {
                  ManageSellTrailing(positionIndex, openPrice, currentSL, ask, bid, ticket);
               }
            }
            
            positionIndex++;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage buy trailing                                             |
//+------------------------------------------------------------------+
void ManageBuyTrailing(int idx, double openPrice, double currentSL, double ask, double bid, ulong ticket) {
   double profitInPips = (bid - openPrice) / _Point;
   
   //--- Actualizar precio más alto
   if(bid > trailingData[idx].highestPrice) {
      trailingData[idx].highestPrice = bid;
   }
   
   //--- Activar trailing después de alcanzar beneficio mínimo
   if(profitInPips >= TrailingStartPips) {
      double newSL = trailingData[idx].highestPrice - MinTrailingDistance * _Point;
      
      //--- Solo mover SL si mejora
      if(newSL > currentSL) {
         //--- Asegurar que el movimiento sea al menos del paso mínimo
         if(newSL - currentSL >= TrailingStepPips * _Point) {
            ModifyStopLoss(ticket, newSL);
            trailingData[idx].trailingLevel = newSL;
            
            Print("Trailing BUY actualizado. Nuevo SL: ", newSL, 
                  " Beneficio actual: ", profitInPips, " pips");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Manage sell trailing                                            |
//+------------------------------------------------------------------+
void ManageSellTrailing(int idx, double openPrice, double currentSL, double ask, double bid, ulong ticket) {
   double profitInPips = (openPrice - ask) / _Point;
   
   //--- Actualizar precio más bajo
   if(ask < trailingData[idx].lowestPrice) {
      trailingData[idx].lowestPrice = ask;
   }
   
   //--- Activar trailing después de alcanzar beneficio mínimo
   if(profitInPips >= TrailingStartPips) {
      double newSL = trailingData[idx].lowestPrice + MinTrailingDistance * _Point;
      
      //--- Solo mover SL si mejora
      if(newSL < currentSL) {
         //--- Asegurar que el movimiento sea al menos del paso mínimo
         if(currentSL - newSL >= TrailingStepPips * _Point) {
            ModifyStopLoss(ticket, newSL);
            trailingData[idx].trailingLevel = newSL;
            
            Print("Trailing SELL actualizado. Nuevo SL: ", newSL, 
                  " Beneficio actual: ", profitInPips, " pips");
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Modify stop loss                                                |
//+------------------------------------------------------------------+
void ModifyStopLoss(ulong ticket, double newSL) {
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_SLTP;
   request.symbol = _Symbol;
   request.sl = newSL;
   request.tp = PositionGetDouble(POSITION_TP);
   request.position = ticket;
   request.magic = (uint)MagicNumber;
   
   OrderSend(request, result);
}

//+------------------------------------------------------------------+
//| Check if it's news time (simulated)                             |
//+------------------------------------------------------------------+
bool IsNewsTime() {
   //--- Esta función se puede implementar con un calendario real
   //--- Por ahora, simulamos horarios de alta volatilidad
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   //--- Evitar horarios de noticias importantes (ejemplo: 8:30, 10:00, 14:30)
   if(dt.hour == 8 && dt.min >= 30 - MinutesBeforeNews && dt.min <= 30 + MinutesAfterNews) return true;
   if(dt.hour == 10 && dt.min >= 0 - MinutesBeforeNews && dt.min <= 0 + MinutesAfterNews) return true;
   if(dt.hour == 14 && dt.min >= 30 - MinutesBeforeNews && dt.min <= 30 + MinutesAfterNews) return true;
   
   return false;
}
//+------------------------------------------------------------------+