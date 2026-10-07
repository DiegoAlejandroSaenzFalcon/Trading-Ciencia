//+------------------------------------------------------------------+
//|                    TrendSniper XAUUSD EA v2.0                    |
//|          Expert Advisor Profesional para XAUUSD / MT5            |
//|    Estrategia: Multi-Timeframe Trend Following + Breakout Entry  |
//|                                                                  |
//|  Logica principal:                                               |
//|   1. Filtro de tendencia macro (D1 + H4 + H1) via EMA + ADX     |
//|   2. Entrada por ruptura de rango comprimido en M1               |
//|   3. SL ajustable (recomendado >= 30 pts), TP amplio (500 pts)   |
//|   4. Trailing stop + Breakeven automatico                        |
//|   5. Gestion de riesgo por % de balance                         |
//|   6. Filtro de sesion, spread y drawdown diario                 |
//|                                                                  |
//|  IMPORTANTE: SL de 5 puntos es EXTREMADAMENTE ajustado para      |
//|  el oro. Se recomienda minimo 30-50 pts de SL en live trading.   |
//|  En demo puede funcionar puntualmente pero en real el spread     |
//|  y slippage lo liquidaran rapidamente. Usa al menos SL=30.       |
//+------------------------------------------------------------------+
#property copyright   "TrendSniper EA"
#property link        "https://www.mql5.com"
#property version     "2.00"
#property description "Multi-TF Trend Following EA para XAUUSD"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Objetos de trading
CTrade          trade;
CPositionInfo   posInfo;
COrderInfo      ordInfo;

//+------------------------------------------------------------------+
//|  ============  PARAMETROS DE ENTRADA  ============               |
//+------------------------------------------------------------------+

//--- [1] IDENTIFICACION
input group "=== IDENTIFICACION ==="
input ulong    MagicNumber       = 20260101;   // Magic Number unico del EA
input string   TradeComment      = "TrendSniper";  // Comentario en las ordenes

//--- [2] FILTRO DE TENDENCIA MULTI-TIMEFRAME
input group "=== FILTROS DE TENDENCIA (Multi-TF) ==="
input bool     UseD1Filter       = true;        // Activar filtro D1
input int      D1_EMA_Fast       = 50;          // EMA rapida en D1
input int      D1_EMA_Slow       = 200;         // EMA lenta en D1
input bool     UseH4Filter       = true;        // Activar filtro H4
input int      H4_EMA_Fast       = 21;          // EMA rapida en H4
input int      H4_EMA_Slow       = 50;          // EMA lenta en H4
input bool     UseH1Filter       = true;        // Activar filtro H1
input int      H1_EMA_Fast       = 8;           // EMA rapida en H1
input int      H1_EMA_Slow       = 21;          // EMA media en H1

//--- [3] FILTRO ADX (FUERZA DE TENDENCIA)
input group "=== FILTRO ADX - FUERZA DE TENDENCIA ==="
input bool     UseADXFilter      = true;        // Activar filtro ADX
input ENUM_TIMEFRAMES ADX_TF     = PERIOD_H1;   // Timeframe del ADX
input int      ADX_Period        = 14;          // Periodo ADX
input double   ADX_MinLevel      = 25.0;        // ADX minimo para operar (25=tendencia fuerte)
input double   ADX_MaxLevel      = 70.0;        // ADX maximo (evitar sobreextension)

//--- [4] SEÑAL DE ENTRADA (BREAKOUT EN M1)
input group "=== SEÑAL DE ENTRADA - BREAKOUT ==="
input int      BreakoutBars      = 20;          // Barras para calcular rango de ruptura
input int      ConsolidationBars = 10;          // Barras de compresion previa (0=desactivar)
input double   MaxRangePoints    = 25.0;        // Rango maximo de consolidacion en puntos
input bool     UseRSIConfirm     = true;        // Confirmar con RSI
input int      RSI_Period        = 14;          // Periodo RSI
input double   RSI_OverboughtSell= 60.0;        // RSI maximo para vender (no sobrecomprado extremo)
input double   RSI_OversoldBuy   = 40.0;        // RSI minimo para comprar
input bool     UseStochasticConf = false;       // Confirmar con Estocastico
input int      Stoch_K           = 5;           // Periodo K del estocastico
input int      Stoch_D           = 3;           // Periodo D del estocastico
input double   Stoch_OB          = 80.0;        // Sobrecompra estocastico
input double   Stoch_OS          = 20.0;        // Sobreventa estocastico

//--- [5] STOP LOSS Y TAKE PROFIT
input group "=== STOP LOSS Y TAKE PROFIT ==="
input double   StopLoss_Points   = 50.0;        // Stop Loss en puntos precio (RECOMENDADO: 30-100)
input double   TakeProfit_Points = 500.0;       // Take Profit en puntos precio
input bool     UseATR_SL         = false;       // Usar SL dinamico basado en ATR
input int      ATR_Period        = 14;          // Periodo ATR
input double   ATR_Multiplier    = 1.5;         // Multiplicador ATR para SL
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_H1;   // Timeframe del ATR

//--- [6] TRAILING STOP Y BREAKEVEN
input group "=== TRAILING STOP Y BREAKEVEN ==="
input bool     UseTrailingStop   = true;        // Activar trailing stop
input double   TrailStart_Points = 50.0;        // Iniciar trailing al llegar a X puntos de ganancia
input double   TrailStep_Points  = 15.0;        // Paso del trailing stop en puntos
input double   TrailDistance_Pts = 30.0;        // Distancia del trailing al precio
input bool     UseBreakeven      = true;        // Activar breakeven
input double   BreakevenAt_Pts   = 40.0;        // Mover SL a breakeven al llegar a X puntos
input double   BreakevenBuffer   = 2.0;         // Buffer de breakeven (SL = entrada + buffer)

//--- [7] GESTION DE RIESGO
input group "=== GESTION DE RIESGO ==="
input bool     UseRiskPercent    = true;        // Calcular lotes por % de riesgo
input double   RiskPercent       = 1.0;         // Riesgo por operacion (% del balance)
input double   FixedLotSize      = 0.01;        // Lote fijo (si UseRiskPercent=false)
input double   MaxLotSize        = 5.0;         // Lote maximo permitido
input double   MinLotSize        = 0.01;        // Lote minimo
input bool     MaxOnePosition    = true;        // Solo 1 posicion abierta a la vez
input double   MaxDailyLoss_Pct  = 3.0;        // Detener si perdida diaria > X% del balance
input int      MaxTradesPerDay   = 5;           // Maximo de operaciones por dia

//--- [8] FILTROS DE MERCADO
input group "=== FILTROS DE MERCADO ==="
input double   MaxSpread_Points  = 20.0;        // Spread maximo permitido en puntos
input bool     UseSessionFilter  = true;        // Filtrar por sesion de trading
input int      Session_StartHour = 7;           // Hora inicio sesion (GMT)
input int      Session_EndHour   = 21;          // Hora fin sesion (GMT)
input bool     PauseOnFriday     = true;        // Pausar nuevas entradas el viernes tarde
input int      FridayPauseHour   = 18;          // Hora del viernes para pausar (GMT)
input bool     PauseOnMonday     = false;       // Pausar lunes al inicio
input int      MondayStartHour   = 2;           // Hora inicio lunes para operar

//--- [9] DASHBOARD Y ALERTAS
input group "=== DASHBOARD Y ALERTAS ==="
input bool     ShowDashboard     = true;        // Mostrar panel en pantalla
input int      DashX             = 10;          // Posicion X del panel
input int      DashY             = 25;          // Posicion Y del panel
input color    ColorBull         = clrLimeGreen; // Color tendencia alcista
input color    ColorBear         = clrOrangeRed; // Color tendencia bajista
input color    ColorNeutral      = clrGold;      // Color neutral/filtro
input bool     SendAlerts        = false;       // Enviar alertas MT5
input bool     SendPushNotif     = false;       // Enviar notificaciones push
input bool     SendEmail         = false;       // Enviar emails

//+------------------------------------------------------------------+
//|  ============  VARIABLES GLOBALES  ============                  |
//+------------------------------------------------------------------+

//--- Handles de indicadores
int hEMA_D1_Fast, hEMA_D1_Slow;
int hEMA_H4_Fast, hEMA_H4_Slow;
int hEMA_H1_Fast, hEMA_H1_Slow;
int hADX_H1;
int hRSI_M1;
int hStoch_M1;
int hATR;

//--- Variables de estado
datetime lastBarTime    = 0;
int      dailyTrades    = 0;
double   dailyStartBal  = 0;
datetime lastTradeDay   = 0;
bool     isBullTrend    = false;
bool     isBearTrend    = false;
bool     adxConfirm     = false;
double   currentATR     = 0;

//--- Informacion del simbolo
double   pointSize;
int      symDigits;
double   minSL_Pts;

//--- Nombre de objetos del dashboard
string   dashPrefix     = "TS_";

//+------------------------------------------------------------------+
//|  OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validaciones basicas
   if(_Symbol != "XAUUSD" && _Symbol != "XAUUSDm" && _Symbol != "XAUUSD." &&
      _Symbol != "GOLD" && _Symbol != "GOLDm")
   {
      Print("ADVERTENCIA: Este EA esta optimizado para XAUUSD. Simbolo actual: ", _Symbol);
   }
   
   if(StopLoss_Points < 5)
   {
      Alert("ERROR: StopLoss_Points no puede ser menor que 5 puntos.");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(StopLoss_Points < 20)
   {
      Print("ADVERTENCIA: SL de ", StopLoss_Points, " pts es muy ajustado para XAUUSD en live trading.");
      Print("El spread tipico de XAUUSD es 10-25 pts. Se recomienda SL >= 30 pts.");
   }
   
   //--- Info del simbolo
   pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   symDigits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   minSL_Pts = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   
   Print("Simbolo: ", _Symbol, " | Point: ", pointSize, " | Digits: ", symDigits, " | Min SL: ", minSL_Pts);
   
   //--- Configurar trade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.LogLevel(LOG_LEVEL_ERRORS);
   
   //--- Crear handles de indicadores
   //-- D1 EMAs
   hEMA_D1_Fast = iMA(_Symbol, PERIOD_D1, D1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_D1_Slow = iMA(_Symbol, PERIOD_D1, D1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   
   //-- H4 EMAs
   hEMA_H4_Fast = iMA(_Symbol, PERIOD_H4, H4_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_H4_Slow = iMA(_Symbol, PERIOD_H4, H4_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   
   //-- H1 EMAs
   hEMA_H1_Fast = iMA(_Symbol, PERIOD_H1, H1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_H1_Slow = iMA(_Symbol, PERIOD_H1, H1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   
   //-- ADX
   hADX_H1 = iADX(_Symbol, ADX_TF, ADX_Period);
   
   //-- RSI en M1
   hRSI_M1 = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   
   //-- Estocastico en M1
   hStoch_M1 = iStochastic(_Symbol, PERIOD_M1, Stoch_K, Stoch_D, 3, MODE_SMA, STO_LOWHIGH);
   
   //-- ATR
   hATR = iATR(_Symbol, ATR_TF, ATR_Period);
   
   //--- Verificar handles
   if(hEMA_D1_Fast == INVALID_HANDLE || hEMA_D1_Slow == INVALID_HANDLE ||
      hEMA_H4_Fast == INVALID_HANDLE || hEMA_H4_Slow == INVALID_HANDLE ||
      hEMA_H1_Fast == INVALID_HANDLE || hEMA_H1_Slow == INVALID_HANDLE ||
      hADX_H1 == INVALID_HANDLE || hRSI_M1 == INVALID_HANDLE ||
      hATR == INVALID_HANDLE)
   {
      Print("ERROR: Fallo al crear handles de indicadores.");
      return INIT_FAILED;
   }
   
   //--- Resetear contadores diarios
   ResetDailyCounters();
   
   //--- Crear dashboard
   if(ShowDashboard) CreateDashboard();
   
   Print("TrendSniper XAUUSD EA v2.0 inicializado correctamente.");
   Print("Magic: ", MagicNumber, " | SL: ", StopLoss_Points, " pts | TP: ", TakeProfit_Points, " pts");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   //--- Liberar handles
   IndicatorRelease(hEMA_D1_Fast); IndicatorRelease(hEMA_D1_Slow);
   IndicatorRelease(hEMA_H4_Fast); IndicatorRelease(hEMA_H4_Slow);
   IndicatorRelease(hEMA_H1_Fast); IndicatorRelease(hEMA_H1_Slow);
   IndicatorRelease(hADX_H1);
   IndicatorRelease(hRSI_M1);
   IndicatorRelease(hStoch_M1);
   IndicatorRelease(hATR);
   
   //--- Eliminar objetos del dashboard
   if(ShowDashboard) DeleteDashboard();
   
   Print("TrendSniper EA desinicializado. Razon: ", reason);
}

//+------------------------------------------------------------------+
//|  OnTick - Logica principal                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Solo procesar en nueva barra M1 para evitar re-entradas
   datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
   bool     isNewBar   = (currentBar != lastBarTime);
   if(isNewBar) lastBarTime = currentBar;
   
   //--- Resetear contadores al inicio de nuevo dia
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(today != lastTradeDay)
   {
      ResetDailyCounters();
      lastTradeDay = today;
      dailyStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   }
   
   //--- Gestionar posiciones abiertas SIEMPRE (trailing/breakeven en cada tick)
   ManageOpenPositions();
   
   //--- Solo evaluar entradas en nueva barra
   if(!isNewBar) return;
   
   //--- Actualizar indicadores y estado de tendencia
   UpdateTrendState();
   
   //--- Actualizar dashboard
   if(ShowDashboard) UpdateDashboard();
   
   //--- Verificar si podemos operar
   if(!CanTrade()) return;
   
   //--- Si ya hay posicion abierta y solo se permite 1, salir
   if(MaxOnePosition && HasOpenPosition()) return;
   
   //--- Evaluar señales de entrada
   int signal = GetEntrySignal();
   
   if(signal == 1)       OpenTrade(ORDER_TYPE_BUY);
   else if(signal == -1) OpenTrade(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
//|  UpdateTrendState - Lee todos los filtros de tendencia            |
//+------------------------------------------------------------------+
void UpdateTrendState()
{
   double buf[2];
   
   //--- Reset
   isBullTrend = true;
   isBearTrend = true;
   
   //--- Filtro D1
   if(UseD1Filter)
   {
      double d1fast[], d1slow[];
      ArraySetAsSeries(d1fast, true); ArraySetAsSeries(d1slow, true);
      if(CopyBuffer(hEMA_D1_Fast, 0, 0, 3, d1fast) < 3) return;
      if(CopyBuffer(hEMA_D1_Slow, 0, 0, 3, d1slow) < 3) return;
      
      bool d1bull = (d1fast[1] > d1slow[1]);  // Usar barra cerrada [1]
      bool d1bear = (d1fast[1] < d1slow[1]);
      
      isBullTrend = isBullTrend && d1bull;
      isBearTrend = isBearTrend && d1bear;
   }
   
   //--- Filtro H4
   if(UseH4Filter)
   {
      double h4fast[], h4slow[];
      ArraySetAsSeries(h4fast, true); ArraySetAsSeries(h4slow, true);
      if(CopyBuffer(hEMA_H4_Fast, 0, 0, 3, h4fast) < 3) return;
      if(CopyBuffer(hEMA_H4_Slow, 0, 0, 3, h4slow) < 3) return;
      
      bool h4bull = (h4fast[1] > h4slow[1]);
      bool h4bear = (h4fast[1] < h4slow[1]);
      
      isBullTrend = isBullTrend && h4bull;
      isBearTrend = isBearTrend && h4bear;
   }
   
   //--- Filtro H1
   if(UseH1Filter)
   {
      double h1fast[], h1slow[];
      ArraySetAsSeries(h1fast, true); ArraySetAsSeries(h1slow, true);
      if(CopyBuffer(hEMA_H1_Fast, 0, 0, 3, h1fast) < 3) return;
      if(CopyBuffer(hEMA_H1_Slow, 0, 0, 3, h1slow) < 3) return;
      
      bool h1bull = (h1fast[1] > h1slow[1]);
      bool h1bear = (h1fast[1] < h1slow[1]);
      
      isBullTrend = isBullTrend && h1bull;
      isBearTrend = isBearTrend && h1bear;
   }
   
   //--- Filtro ADX
   adxConfirm = true;
   if(UseADXFilter)
   {
      double adxMain[], diPlus[], diMinus[];
      ArraySetAsSeries(adxMain, true);
      ArraySetAsSeries(diPlus, true);
      ArraySetAsSeries(diMinus, true);
      
      if(CopyBuffer(hADX_H1, 0, 0, 3, adxMain) < 3) { adxConfirm = false; return; }
      if(CopyBuffer(hADX_H1, 1, 0, 3, diPlus)  < 3) { adxConfirm = false; return; }
      if(CopyBuffer(hADX_H1, 2, 0, 3, diMinus) < 3) { adxConfirm = false; return; }
      
      double adxVal = adxMain[1];  // Barra cerrada
      double dip    = diPlus[1];
      double dim    = diMinus[1];
      
      //--- ADX debe estar en rango de tendencia fuerte
      bool adxStrong = (adxVal >= ADX_MinLevel && adxVal <= ADX_MaxLevel);
      
      //--- DI+ > DI- para alcista, DI- > DI+ para bajista
      if(adxStrong)
      {
         isBullTrend = isBullTrend && (dip > dim);
         isBearTrend = isBearTrend && (dim > dip);
         adxConfirm  = true;
      }
      else
      {
         //--- Tendencia debil o sobreextendida: no operar
         isBullTrend = false;
         isBearTrend = false;
         adxConfirm  = false;
      }
   }
   
   //--- Actualizar ATR
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 0, 3, atrBuf) >= 3)
      currentATR = atrBuf[1] / pointSize;  // ATR en puntos
}

//+------------------------------------------------------------------+
//|  GetEntrySignal - Detecta señal de breakout en M1                |
//|  Retorna: 1=BUY, -1=SELL, 0=Sin señal                           |
//+------------------------------------------------------------------+
int GetEntrySignal()
{
   //--- Necesitamos tendencia clara
   if(!isBullTrend && !isBearTrend) return 0;
   
   //--- Obtener high/low de las ultimas N barras (sin incluir barra actual)
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   
   int barsNeeded = BreakoutBars + 2;
   if(CopyHigh(_Symbol, PERIOD_M1, 1, barsNeeded, highs) < barsNeeded) return 0;
   if(CopyLow(_Symbol,  PERIOD_M1, 1, barsNeeded, lows)  < barsNeeded) return 0;
   
   //--- Nivel de ruptura: highest high / lowest low de las N barras pasadas
   double breakHigh = highs[ArrayMaximum(highs, 0, BreakoutBars)];
   double breakLow  = lows[ArrayMinimum(lows, 0, BreakoutBars)];
   
   //--- Precio actual
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   //--- Verificar si hay compresion (consolidacion previa)
   if(ConsolidationBars > 0)
   {
      double consHigh = highs[ArrayMaximum(highs, 0, ConsolidationBars)];
      double consLow  = lows[ArrayMinimum(lows, 0, ConsolidationBars)];
      double range    = (consHigh - consLow) / pointSize;
      
      //--- Si el rango es mayor al maximo permitido, mercado muy volatil
      if(range > MaxRangePoints * 2) return 0;
   }
   
   //--- Obtener RSI
   double rsiVal = 50;
   if(UseRSIConfirm)
   {
      double rsiBuf[];
      ArraySetAsSeries(rsiBuf, true);
      if(CopyBuffer(hRSI_M1, 0, 0, 3, rsiBuf) < 3) return 0;
      rsiVal = rsiBuf[1];
   }
   
   //--- Obtener Estocastico
   double stochK = 50, stochD = 50;
   if(UseStochasticConf)
   {
      double stochKBuf[], stochDBuf[];
      ArraySetAsSeries(stochKBuf, true);
      ArraySetAsSeries(stochDBuf, true);
      if(CopyBuffer(hStoch_M1, 0, 0, 3, stochKBuf) < 3) return 0;
      if(CopyBuffer(hStoch_M1, 1, 0, 3, stochDBuf) < 3) return 0;
      stochK = stochKBuf[1];
      stochD = stochDBuf[1];
   }
   
   //--- Obtener cierre de la ultima barra completada
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, PERIOD_M1, 1, 3, closes) < 3) return 0;
   double lastClose = closes[0];  // Cierre de barra [1]
   
   //--- === SEÑAL SELL ===
   if(isBearTrend)
   {
      //--- Precio rompio por debajo del minimo del rango
      bool priceBreakdown = (bid < breakLow);
      
      //--- RSI no sobrevendido extremo (no perseguir precios ya extendidos)
      bool rsiOK = !UseRSIConfirm || (rsiVal < RSI_OverboughtSell && rsiVal > 20);
      
      //--- Estocastico bajista o en zona alta (confirmando bajada)
      bool stochOK = !UseStochasticConf || (stochK < Stoch_OB && stochK > stochD ? false : true);
      
      if(priceBreakdown && rsiOK)
         return -1;  // SELL
   }
   
   //--- === SEÑAL BUY ===
   if(isBullTrend)
   {
      //--- Precio rompio por encima del maximo del rango
      bool priceBreakout = (ask > breakHigh);
      
      //--- RSI no sobrecomprado extremo
      bool rsiOK = !UseRSIConfirm || (rsiVal > RSI_OversoldBuy && rsiVal < 80);
      
      //--- Estocastico alcista
      bool stochOK = !UseStochasticConf || (stochK > Stoch_OS && stochK > stochD);
      
      if(priceBreakout && rsiOK)
         return 1;  // BUY
   }
   
   return 0;
}

//+------------------------------------------------------------------+
//|  OpenTrade - Abre la operacion                                    |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   double entryPrice, sl, tp;
   double slPoints, tpPoints;
   
   //--- Calcular SL en puntos (usando ATR o fijo)
   if(UseATR_SL && currentATR > 0)
      slPoints = currentATR * ATR_Multiplier;
   else
      slPoints = StopLoss_Points;
   
   //--- Asegurar que SL no sea menor al minimo del broker
   if(slPoints < minSL_Pts + 2) slPoints = minSL_Pts + 2;
   
   tpPoints = TakeProfit_Points;
   
   //--- Calcular precios
   if(type == ORDER_TYPE_BUY)
   {
      entryPrice = ask;
      sl         = NormalizeDouble(ask - slPoints * pointSize, symDigits);
      tp         = NormalizeDouble(ask + tpPoints * pointSize, symDigits);
   }
   else
   {
      entryPrice = bid;
      sl         = NormalizeDouble(bid + slPoints * pointSize, symDigits);
      tp         = NormalizeDouble(bid - tpPoints * pointSize, symDigits);
   }
   
   //--- Calcular lote
   double lots = CalculateLotSize(slPoints);
   if(lots <= 0)
   {
      Print("ERROR: Calculo de lote invalido: ", lots);
      return;
   }
   
   //--- Verificar spread actual
   double currentSpread = (ask - bid) / pointSize;
   if(currentSpread > MaxSpread_Points)
   {
      Print("Spread demasiado alto: ", currentSpread, " pts (max: ", MaxSpread_Points, " pts). Operacion cancelada.");
      return;
   }
   
   //--- Abrir operacion
   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lots, _Symbol, entryPrice, sl, tp, TradeComment);
   else
      result = trade.Sell(lots, _Symbol, entryPrice, sl, tp, TradeComment);
   
   if(result)
   {
      dailyTrades++;
      
      string typeStr = (type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
      Print("=== OPERACION ABIERTA ===");
      Print("Tipo: ", typeStr, " | Lotes: ", lots);
      Print("Entrada: ", entryPrice, " | SL: ", sl, " | TP: ", tp);
      Print("SL puntos: ", slPoints, " | TP puntos: ", tpPoints);
      Print("R:R = 1:", DoubleToString(tpPoints / slPoints, 1));
      Print("Riesgo USD: $", DoubleToString(slPoints * lots * (1.0 / pointSize) * pointSize * 
            SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) / 
            SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) * pointSize, 2));
      
      //--- Alertas
      if(SendAlerts)
         Alert("TrendSniper: ", typeStr, " XAUUSD | SL:", sl, " | TP:", tp);
      if(SendPushNotif)
         SendNotification("TrendSniper: " + typeStr + " XAUUSD @ " + DoubleToString(entryPrice, symDigits));
      if(SendEmail)
         SendMail("TrendSniper Trade", typeStr + " XAUUSD abierto @ " + DoubleToString(entryPrice, symDigits));
   }
   else
   {
      Print("ERROR al abrir operacion: ", GetLastError(), " | ", trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//|  ManageOpenPositions - Trailing stop y Breakeven                  |
//+------------------------------------------------------------------+
void ManageOpenPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != MagicNumber) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      
      double openPrice  = posInfo.PriceOpen();
      double currentSL  = posInfo.StopLoss();
      double currentTP  = posInfo.TakeProfit();
      double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      ENUM_POSITION_TYPE posType = posInfo.PositionType();
      
      double newSL = currentSL;
      bool   needModify = false;
      
      //--- Calcular ganancia actual en puntos
      double profitPts;
      if(posType == POSITION_TYPE_BUY)
         profitPts = (currentBid - openPrice) / pointSize;
      else
         profitPts = (openPrice - currentAsk) / pointSize;
      
      //--- === BREAKEVEN ===
      if(UseBreakeven && profitPts >= BreakevenAt_Pts)
      {
         double beSL;
         if(posType == POSITION_TYPE_BUY)
         {
            beSL = NormalizeDouble(openPrice + BreakevenBuffer * pointSize, symDigits);
            if(currentSL < beSL - pointSize)  // Solo subir SL, nunca bajar
            {
               newSL = beSL;
               needModify = true;
            }
         }
         else
         {
            beSL = NormalizeDouble(openPrice - BreakevenBuffer * pointSize, symDigits);
            if(currentSL > beSL + pointSize || currentSL == 0)  // Solo bajar SL
            {
               newSL = beSL;
               needModify = true;
            }
         }
      }
      
      //--- === TRAILING STOP ===
      if(UseTrailingStop && profitPts >= TrailStart_Points)
      {
         double trailSL;
         if(posType == POSITION_TYPE_BUY)
         {
            trailSL = NormalizeDouble(currentBid - TrailDistance_Pts * pointSize, symDigits);
            //--- Solo mover SL hacia arriba (nunca bajar)
            if(trailSL > newSL + TrailStep_Points * pointSize)
            {
               newSL = trailSL;
               needModify = true;
            }
         }
         else
         {
            trailSL = NormalizeDouble(currentAsk + TrailDistance_Pts * pointSize, symDigits);
            //--- Solo mover SL hacia abajo (nunca subir)
            if(trailSL < newSL - TrailStep_Points * pointSize || newSL == 0)
            {
               newSL = trailSL;
               needModify = true;
            }
         }
      }
      
      //--- Aplicar modificacion si es necesario
      if(needModify && newSL != currentSL)
      {
         //--- Verificar minimo de distancia al precio
         double minDist = (minSL_Pts + 2) * pointSize;
         bool slValid = true;
         
         if(posType == POSITION_TYPE_BUY && newSL > currentBid - minDist)
            slValid = false;
         if(posType == POSITION_TYPE_SELL && newSL < currentAsk + minDist)
            slValid = false;
         
         if(slValid)
         {
            if(!trade.PositionModify(posInfo.Ticket(), newSL, currentTP))
               Print("ERROR al modificar SL: ", trade.ResultRetcodeDescription());
         }
      }
   }
}

//+------------------------------------------------------------------+
//|  CalculateLotSize - Calcula lotes basados en riesgo               |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
{
   if(!UseRiskPercent)
      return NormalizeLot(FixedLotSize);
   
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);
   
   //--- Valor por punto para 1 lote
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointValue = tickValue / tickSize * pointSize;
   
   if(pointValue <= 0 || slPoints <= 0)
      return NormalizeLot(FixedLotSize);
   
   double lots = riskAmount / (slPoints * pointValue);
   return NormalizeLot(lots);
}

//+------------------------------------------------------------------+
//|  NormalizeLot - Normaliza el lote segun los limites del broker    |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   //--- Aplicar limites configurados
   lots = MathMax(lots, MinLotSize);
   lots = MathMin(lots, MaxLotSize);
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   
   //--- Redondear al paso del lote
   lots = MathFloor(lots / lotStep) * lotStep;
   
   return NormalizeDouble(lots, 2);
}

//+------------------------------------------------------------------+
//|  CanTrade - Verifica condiciones para operar                      |
//+------------------------------------------------------------------+
bool CanTrade()
{
   //--- Verificar que el mercado esta abierto
   if(!SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_FULL)
      return false;
   
   //--- Verificar drawdown diario
   if(MaxDailyLoss_Pct > 0 && dailyStartBal > 0)
   {
      double currentBal   = AccountInfoDouble(ACCOUNT_BALANCE);
      double dailyLossPct = ((dailyStartBal - currentBal) / dailyStartBal) * 100.0;
      if(dailyLossPct >= MaxDailyLoss_Pct)
      {
         Print("Limite de perdida diaria alcanzado: ", DoubleToString(dailyLossPct, 2), "%");
         return false;
      }
   }
   
   //--- Verificar maximo de operaciones diarias
   if(dailyTrades >= MaxTradesPerDay)
      return false;
   
   //--- Verificar sesion de trading
   if(UseSessionFilter && !IsInTradingSession())
      return false;
   
   //--- Verificar cuenta
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < 100)
   {
      Print("Margen libre insuficiente.");
      return false;
   }
   
   //--- Verificar modo de trading
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   
   return true;
}

//+------------------------------------------------------------------+
//|  IsInTradingSession - Verifica si estamos en sesion activa        |
//+------------------------------------------------------------------+
bool IsInTradingSession()
{
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   
   int currentHour = dt.hour;
   int currentDay  = dt.day_of_week;
   
   //--- No operar en fin de semana
   if(currentDay == 0 || currentDay == 6) return false;
   
   //--- Pausa el viernes tarde
   if(PauseOnFriday && currentDay == 5 && currentHour >= FridayPauseHour)
      return false;
   
   //--- Pausa inicio del lunes
   if(PauseOnMonday && currentDay == 1 && currentHour < MondayStartHour)
      return false;
   
   //--- Ventana horaria
   if(Session_StartHour < Session_EndHour)
      return (currentHour >= Session_StartHour && currentHour < Session_EndHour);
   else
      return (currentHour >= Session_StartHour || currentHour < Session_EndHour);
}

//+------------------------------------------------------------------+
//|  HasOpenPosition - Verifica si hay posicion abierta del EA        |
//+------------------------------------------------------------------+
bool HasOpenPosition()
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() == MagicNumber && posInfo.Symbol() == _Symbol)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//|  ResetDailyCounters - Resetea contadores del dia                  |
//+------------------------------------------------------------------+
void ResetDailyCounters()
{
   dailyTrades   = 0;
   dailyStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
//|  CreateDashboard - Crea el panel de informacion en pantalla       |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   DeleteDashboard();
   
   int x = DashX, y = DashY;
   int w = 280, lineH = 18;
   int lines = 14;
   
   //--- Fondo
   ObjectCreate(0, dashPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_XDISTANCE,  x - 5);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_YDISTANCE,  y - 5);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_XSIZE,      w + 10);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_YSIZE,      lines * lineH + 15);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_BGCOLOR,    C'20,20,30');
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_COLOR,      clrDimGray);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_BACK,       false);
   
   //--- Crear lineas de texto
   string labels[] = {"title","symbol","spread","trend_d1","trend_h4","trend_h1","adx",
                       "signal","sl","tp","rr","daily","trades","status"};
   
   for(int i = 0; i < ArraySize(labels); i++)
   {
      string objName = dashPrefix + labels[i];
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_XDISTANCE,  x);
      ObjectSetInteger(0, objName, OBJPROP_YDISTANCE,  y + i * lineH);
      ObjectSetInteger(0, objName, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE,   8);
      ObjectSetString(0,  objName, OBJPROP_FONT,       "Consolas");
      ObjectSetInteger(0, objName, OBJPROP_COLOR,      clrWhite);
      ObjectSetString(0,  objName, OBJPROP_TEXT,       "---");
   }
   
   //--- Titulo fijo
   ObjectSetString(0, dashPrefix + "title", OBJPROP_TEXT, "=== TrendSniper XAUUSD v2.0 ===");
   ObjectSetInteger(0, dashPrefix + "title", OBJPROP_COLOR, ColorNeutral);
   ObjectSetInteger(0, dashPrefix + "title", OBJPROP_FONTSIZE, 9);
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|  UpdateDashboard - Actualiza los valores del panel                |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - 
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pointSize;
   
   string trendStr;
   color  trendColor;
   
   if(isBullTrend)       { trendStr = "ALCISTA ▲"; trendColor = ColorBull; }
   else if(isBearTrend)  { trendStr = "BAJISTA ▼"; trendColor = ColorBear; }
   else                  { trendStr = "NEUTRAL  -"; trendColor = ColorNeutral; }
   
   //--- Verificar D1/H4/H1 individuales para mostrar
   double d1f[], d1s[], h4f[], h4s[], h1f[], h1s[];
   ArraySetAsSeries(d1f, true); ArraySetAsSeries(d1s, true);
   ArraySetAsSeries(h4f, true); ArraySetAsSeries(h4s, true);
   ArraySetAsSeries(h1f, true); ArraySetAsSeries(h1s, true);
   
   bool d1bull = false, h4bull = false, h1bull = false;
   bool d1bear = false, h4bear = false, h1bear = false;
   
   if(CopyBuffer(hEMA_D1_Fast, 0, 1, 1, d1f) == 1 && CopyBuffer(hEMA_D1_Slow, 0, 1, 1, d1s) == 1)
      { d1bull = d1f[0] > d1s[0]; d1bear = d1f[0] < d1s[0]; }
   if(CopyBuffer(hEMA_H4_Fast, 0, 1, 1, h4f) == 1 && CopyBuffer(hEMA_H4_Slow, 0, 1, 1, h4s) == 1)
      { h4bull = h4f[0] > h4s[0]; h4bear = h4f[0] < h4s[0]; }
   if(CopyBuffer(hEMA_H1_Fast, 0, 1, 1, h1f) == 1 && CopyBuffer(hEMA_H1_Slow, 0, 1, 1, h1s) == 1)
      { h1bull = h1f[0] > h1s[0]; h1bear = h1f[0] < h1s[0]; }
   
   //--- ADX
   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   string adxStr = "---";
   if(CopyBuffer(hADX_H1, 0, 1, 1, adxBuf) == 1)
      adxStr = DoubleToString(adxBuf[0], 1);
   
   //--- Informacion de la posicion abierta
   string posStr  = "Sin posicion";
   double profitVal = 0;
   if(HasOpenPosition())
   {
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Magic() != MagicNumber) continue;
         string dir  = (posInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         profitVal   = posInfo.Profit() + posInfo.Swap();
         posStr = dir + " | P&L: $" + DoubleToString(profitVal, 2);
      }
   }
   
   //--- Drawdown diario
   double currentBal    = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLossPct  = 0;
   if(dailyStartBal > 0) dailyLossPct = ((dailyStartBal - currentBal) / dailyStartBal) * 100.0;
   
   //--- Sesion activa?
   string sessionStr = IsInTradingSession() ? "ACTIVA" : "INACTIVA";
   color sessionColor = IsInTradingSession() ? ColorBull : ColorBear;
   
   //--- Actualizar textos
   ObjectSetString(0, dashPrefix + "symbol",  OBJPROP_TEXT, 
      StringFormat("Simbolo: %s | Spread: %.1f pts", _Symbol, spread));
   ObjectSetString(0, dashPrefix + "spread",  OBJPROP_TEXT, 
      StringFormat("Sesion GMT: %s | %02d:%02d", sessionStr, 
      (int)TimeHour(TimeGMT()), (int)TimeMinute(TimeGMT())));
   ObjectSetInteger(0, dashPrefix + "spread",  OBJPROP_COLOR, sessionColor);
   
   ObjectSetString(0,  dashPrefix + "trend_d1", OBJPROP_TEXT, 
      StringFormat("D1:  %s", d1bull ? "ALCISTA ▲" : d1bear ? "BAJISTA ▼" : "NEUTRAL"));
   ObjectSetInteger(0, dashPrefix + "trend_d1", OBJPROP_COLOR, 
      d1bull ? ColorBull : d1bear ? ColorBear : ColorNeutral);
   
   ObjectSetString(0,  dashPrefix + "trend_h4", OBJPROP_TEXT, 
      StringFormat("H4:  %s", h4bull ? "ALCISTA ▲" : h4bear ? "BAJISTA ▼" : "NEUTRAL"));
   ObjectSetInteger(0, dashPrefix + "trend_h4", OBJPROP_COLOR, 
      h4bull ? ColorBull : h4bear ? ColorBear : ColorNeutral);
   
   ObjectSetString(0,  dashPrefix + "trend_h1", OBJPROP_TEXT, 
      StringFormat("H1:  %s", h1bull ? "ALCISTA ▲" : h1bear ? "BAJISTA ▼" : "NEUTRAL"));
   ObjectSetInteger(0, dashPrefix + "trend_h1", OBJPROP_COLOR, 
      h1bull ? ColorBull : h1bear ? ColorBear : ColorNeutral);
   
   ObjectSetString(0,  dashPrefix + "adx", OBJPROP_TEXT, 
      StringFormat("ADX(%d): %s | Confirmacion: %s", ADX_Period, adxStr, 
      adxConfirm ? "SI" : "NO"));
   ObjectSetInteger(0, dashPrefix + "adx", OBJPROP_COLOR, 
      adxConfirm ? ColorBull : ColorNeutral);
   
   ObjectSetString(0,  dashPrefix + "signal", OBJPROP_TEXT, 
      StringFormat("Tendencia: %s", trendStr));
   ObjectSetInteger(0, dashPrefix + "signal", OBJPROP_COLOR, trendColor);
   
   ObjectSetString(0, dashPrefix + "sl", OBJPROP_TEXT, 
      StringFormat("SL: %.0f pts | TP: %.0f pts", StopLoss_Points, TakeProfit_Points));
   
   ObjectSetString(0, dashPrefix + "tp", OBJPROP_TEXT, 
      StringFormat("ATR: %.1f pts | R:R = 1:%.0f", currentATR, TakeProfit_Points/StopLoss_Points));
   
   ObjectSetString(0, dashPrefix + "rr", OBJPROP_TEXT, 
      StringFormat("Riesgo/op: %.1f%% | Lote min: %.2f", RiskPercent, FixedLotSize));
   
   ObjectSetString(0, dashPrefix + "daily", OBJPROP_TEXT, 
      StringFormat("Dd diario: %.2f%% | Ops hoy: %d/%d", 
      MathAbs(dailyLossPct), dailyTrades, MaxTradesPerDay));
   ObjectSetInteger(0, dashPrefix + "daily", OBJPROP_COLOR, 
      MathAbs(dailyLossPct) > MaxDailyLoss_Pct * 0.7 ? ColorBear : ColorBull);
   
   ObjectSetString(0,  dashPrefix + "trades", OBJPROP_TEXT, 
      StringFormat("Posicion: %s", posStr));
   ObjectSetInteger(0, dashPrefix + "trades", OBJPROP_COLOR, 
      profitVal >= 0 ? ColorBull : ColorBear);
   
   ObjectSetString(0, dashPrefix + "status", OBJPROP_TEXT, 
      StringFormat("Balance: $%.2f | Equity: $%.2f", 
      AccountInfoDouble(ACCOUNT_BALANCE), AccountInfoDouble(ACCOUNT_EQUITY)));
   
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|  DeleteDashboard - Elimina todos los objetos del panel            |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   ObjectsDeleteAll(0, dashPrefix);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|  Funciones auxiliares de tiempo                                   |
//+------------------------------------------------------------------+
int TimeHour(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour;
}

int TimeMinute(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.min;
}

//+------------------------------------------------------------------+
//|  OnTradeTransaction - Log de transacciones                        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(trans.deal_type == DEAL_TYPE_BUY || trans.deal_type == DEAL_TYPE_SELL)
      {
         if(HistoryDealSelect(trans.deal))
         {
            double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            double dealSwap   = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
            
            if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            {
               Print("=== CIERRE DE OPERACION ===");
               Print("Ticket: ", trans.order);
               Print("Beneficio: $", DoubleToString(dealProfit + dealSwap, 2));
               
               if(dealProfit + dealSwap >= 0)
                  Print("GANANCIA ALCANZADA >>> TP EXITOSO");
               else
                  Print("SL activado o cierre manual.");
               
               if(SendAlerts)
                  Alert("TrendSniper CERRADO: P&L = $", DoubleToString(dealProfit + dealSwap, 2));
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//|  FIN DEL EA                                                       |
//+------------------------------------------------------------------+