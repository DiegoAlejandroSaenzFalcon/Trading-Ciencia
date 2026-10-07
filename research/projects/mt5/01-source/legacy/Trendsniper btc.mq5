//+------------------------------------------------------------------+
//|                  TrendSniper BTC EA v2.0                         |
//|        Expert Advisor Profesional para BTCUSD / MT5              |
//|   Estrategia: Multi-Timeframe Trend Following + Breakout Entry   |
//|                                                                  |
//|  Versión optimizada para Bitcoin — parámetros ajustados para     |
//|  la alta volatilidad, spreads amplios y tendencias explosivas     |
//|  características del mercado cripto.                             |
//|                                                                  |
//|  Simbolos compatibles: BTCUSD, BTCUSDm, BTCUSDT, BITCOIN        |
//+------------------------------------------------------------------+
#property copyright   "TrendSniper BTC EA"
#property link        "https://www.mql5.com"
#property version     "2.00"
#property description "Multi-TF Trend Following EA para BTCUSD"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

CTrade          trade;
CPositionInfo   posInfo;
COrderInfo      ordInfo;

//+------------------------------------------------------------------+
//|  ============  PARAMETROS DE ENTRADA  ============               |
//+------------------------------------------------------------------+

input group "=== IDENTIFICACION ==="
input ulong    MagicNumber       = 20260202;
input string   TradeComment      = "TrendSniper_BTC";

//--- [2] FILTRO MULTI-TIMEFRAME
input group "=== FILTROS DE TENDENCIA (Multi-TF) ==="
input bool     UseD1Filter       = true;
input int      D1_EMA_Fast       = 50;
input int      D1_EMA_Slow       = 200;
input bool     UseH4Filter       = true;
input int      H4_EMA_Fast       = 21;
input int      H4_EMA_Slow       = 50;
input bool     UseH1Filter       = true;
input int      H1_EMA_Fast       = 8;
input int      H1_EMA_Slow       = 21;

//--- [3] ADX — umbral mas alto que en oro por el ruido del BTC
input group "=== FILTRO ADX ==="
input bool     UseADXFilter      = true;
input ENUM_TIMEFRAMES ADX_TF     = PERIOD_H1;
input int      ADX_Period        = 14;
input double   ADX_MinLevel      = 28.0;   // BTC: minimo 28 (mas exigente que el oro)
input double   ADX_MaxLevel      = 75.0;   // BTC permite sobreextension mayor

//--- [4] SEÑAL DE ENTRADA
input group "=== SEÑAL DE ENTRADA - BREAKOUT ==="
input int      BreakoutBars      = 20;
input int      ConsolidationBars = 10;
input double   MaxRangePoints    = 200.0;  // BTC: rango de consolidacion mucho mayor
input bool     UseRSIConfirm     = true;
input int      RSI_Period        = 14;
input double   RSI_OverboughtSell= 60.0;
input double   RSI_OversoldBuy   = 40.0;
input bool     UseStochasticConf = false;
input int      Stoch_K           = 5;
input int      Stoch_D           = 3;
input double   Stoch_OB          = 80.0;
input double   Stoch_OS          = 20.0;

//--- [5] SL Y TP — ajustados para la volatilidad del BTC
input group "=== STOP LOSS Y TAKE PROFIT ==="
input double   StopLoss_Points   = 300.0;  // BTC mueve $500-2000 en minutos
input double   TakeProfit_Points = 3000.0; // Tendencias BTC son ampliamente mas largas
input bool     UseATR_SL         = true;   // ATR dinamico recomendado para BTC
input int      ATR_Period        = 14;
input double   ATR_Multiplier    = 2.0;    // Mayor multiplicador para volatilidad BTC
input ENUM_TIMEFRAMES ATR_TF     = PERIOD_H1;

//--- [6] TRAILING Y BREAKEVEN — con espacio para respirar
input group "=== TRAILING STOP Y BREAKEVEN ==="
input bool     UseTrailingStop   = true;
input double   TrailStart_Points = 200.0;  // Iniciar trailing al llegar a 200 pts de ganancia
input double   TrailStep_Points  = 50.0;   // Paso mas grande para evitar salidas prematuras
input double   TrailDistance_Pts = 120.0;  // BTC retrocede fuerte: distancia mayor
input bool     UseBreakeven      = true;
input double   BreakevenAt_Pts   = 150.0;  // Mover BE al llegar a 150 pts de ganancia
input double   BreakevenBuffer   = 5.0;    // Pequeno buffer encima de entrada

//--- [7] GESTION DE RIESGO — mas conservador que en oro
input group "=== GESTION DE RIESGO ==="
input bool     UseRiskPercent    = true;
input double   RiskPercent       = 0.75;   // BTC: 0.5-1% por la volatilidad
input double   FixedLotSize      = 0.001;  // Lote minimo en BTC (1 contrato = 1 BTC)
input double   MaxLotSize        = 1.0;    // Maximo 1 BTC por operacion
input double   MinLotSize        = 0.001;
input bool     MaxOnePosition    = true;
input double   MaxDailyLoss_Pct  = 2.0;   // BTC: limite diario mas conservador
input int      MaxTradesPerDay   = 4;      // Menos operaciones por la mayor volatilidad

//--- [8] FILTROS DE MERCADO — spread amplio para cripto
input group "=== FILTROS DE MERCADO ==="
input double   MaxSpread_Points  = 200.0;  // BTC: spread puede ser 50-150 puntos
input bool     UseSessionFilter  = false;  // BTC opera 24/7, sesion opcional
input int      Session_StartHour = 0;      // Si activas sesion: hora inicio GMT
input int      Session_EndHour   = 23;     // Si activas sesion: hora fin GMT
input bool     PauseOnFriday     = false;  // BTC no tiene fin de semana
input int      FridayPauseHour   = 22;
input bool     PauseOnMonday     = false;
input int      MondayStartHour   = 0;
// Nota: considera pausar durante anuncios macro (FOMC, CPI) que afectan BTC

//--- [9] DASHBOARD
input group "=== DASHBOARD Y ALERTAS ==="
input bool     ShowDashboard     = true;
input int      DashX             = 10;
input int      DashY             = 25;
input color    ColorBull         = clrLimeGreen;
input color    ColorBear         = clrOrangeRed;
input color    ColorNeutral      = clrDodgerBlue;
input bool     SendAlerts        = false;
input bool     SendPushNotif     = false;
input bool     SendEmail         = false;

//+------------------------------------------------------------------+
//|  ============  VARIABLES GLOBALES  ============                  |
//+------------------------------------------------------------------+

int hEMA_D1_Fast, hEMA_D1_Slow;
int hEMA_H4_Fast, hEMA_H4_Slow;
int hEMA_H1_Fast, hEMA_H1_Slow;
int hADX_H1;
int hRSI_M1;
int hStoch_M1;
int hATR;

datetime lastBarTime    = 0;
int      dailyTrades    = 0;
double   dailyStartBal  = 0;
datetime lastTradeDay   = 0;
bool     isBullTrend    = false;
bool     isBearTrend    = false;
bool     adxConfirm     = false;
double   currentATR     = 0;

double   pointSize;
int      symDigits;
double   minSL_Pts;

string   dashPrefix     = "TSBTC_";

//+------------------------------------------------------------------+
//|  OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Verificar que sea un simbolo BTC
   string sym = _Symbol;
   StringToUpper(sym);
   if(StringFind(sym, "BTC") < 0 && StringFind(sym, "BITCOIN") < 0)
   {
      Print("ADVERTENCIA: Este EA esta optimizado para BTC. Simbolo actual: ", _Symbol);
      Print("Si estas en BTCUSD, BTCUSDm o BTCUSDT el EA funcionara correctamente.");
   }

   if(StopLoss_Points < 50)
   {
      Alert("ERROR: StopLoss_Points no puede ser menor a 50 para BTCUSD.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(StopLoss_Points < 150)
      Print("ADVERTENCIA: SL de ", StopLoss_Points, 
            " pts puede ser muy ajustado para BTC. Recomendado >= 200 pts.");

   //--- Info del simbolo
   pointSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   symDigits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   minSL_Pts = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   Print("BTC EA | Simbolo: ", _Symbol, " | Point: ", pointSize, 
         " | Digits: ", symDigits, " | Min SL broker: ", minSL_Pts);

   //--- Configurar trade
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);   // Mayor slippage tolerado en BTC
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.LogLevel(LOG_LEVEL_ERRORS);

   //--- Crear handles
   hEMA_D1_Fast = iMA(_Symbol, PERIOD_D1, D1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_D1_Slow = iMA(_Symbol, PERIOD_D1, D1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_H4_Fast = iMA(_Symbol, PERIOD_H4, H4_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_H4_Slow = iMA(_Symbol, PERIOD_H4, H4_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_H1_Fast = iMA(_Symbol, PERIOD_H1, H1_EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_H1_Slow = iMA(_Symbol, PERIOD_H1, H1_EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
   hADX_H1      = iADX(_Symbol, ADX_TF, ADX_Period);
   hRSI_M1      = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
   hStoch_M1    = iStochastic(_Symbol, PERIOD_M1, Stoch_K, Stoch_D, 3, MODE_SMA, STO_LOWHIGH);
   hATR         = iATR(_Symbol, ATR_TF, ATR_Period);

   if(hEMA_D1_Fast == INVALID_HANDLE || hEMA_D1_Slow == INVALID_HANDLE ||
      hEMA_H4_Fast == INVALID_HANDLE || hEMA_H4_Slow == INVALID_HANDLE ||
      hEMA_H1_Fast == INVALID_HANDLE || hEMA_H1_Slow == INVALID_HANDLE ||
      hADX_H1 == INVALID_HANDLE || hRSI_M1 == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("ERROR: Fallo al crear handles de indicadores.");
      return INIT_FAILED;
   }

   ResetDailyCounters();
   if(ShowDashboard) CreateDashboard();

   Print("TrendSniper BTC EA v2.0 inicializado.");
   Print("SL: ", StopLoss_Points, " pts | TP: ", TakeProfit_Points, 
         " pts | R:R = 1:", DoubleToString(TakeProfit_Points / StopLoss_Points, 1));

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//|  OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hEMA_D1_Fast); IndicatorRelease(hEMA_D1_Slow);
   IndicatorRelease(hEMA_H4_Fast); IndicatorRelease(hEMA_H4_Slow);
   IndicatorRelease(hEMA_H1_Fast); IndicatorRelease(hEMA_H1_Slow);
   IndicatorRelease(hADX_H1);
   IndicatorRelease(hRSI_M1);
   IndicatorRelease(hStoch_M1);
   IndicatorRelease(hATR);
   if(ShowDashboard) DeleteDashboard();
   Print("TrendSniper BTC EA desinicializado.");
}

//+------------------------------------------------------------------+
//|  OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
   bool     isNewBar   = (currentBar != lastBarTime);
   if(isNewBar) lastBarTime = currentBar;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(today != lastTradeDay)
   {
      ResetDailyCounters();
      lastTradeDay = today;
      dailyStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
   }

   ManageOpenPositions();

   if(!isNewBar) return;

   UpdateTrendState();

   if(ShowDashboard) UpdateDashboard();

   if(!CanTrade()) return;
   if(MaxOnePosition && HasOpenPosition()) return;

   int signal = GetEntrySignal();
   if(signal == 1)       OpenTrade(ORDER_TYPE_BUY);
   else if(signal == -1) OpenTrade(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
//|  UpdateTrendState                                                 |
//+------------------------------------------------------------------+
void UpdateTrendState()
{
   isBullTrend = true;
   isBearTrend = true;

   if(UseD1Filter)
   {
      double d1fast[], d1slow[];
      ArraySetAsSeries(d1fast, true); ArraySetAsSeries(d1slow, true);
      if(CopyBuffer(hEMA_D1_Fast, 0, 0, 3, d1fast) < 3) return;
      if(CopyBuffer(hEMA_D1_Slow, 0, 0, 3, d1slow) < 3) return;
      isBullTrend = isBullTrend && (d1fast[1] > d1slow[1]);
      isBearTrend = isBearTrend && (d1fast[1] < d1slow[1]);
   }

   if(UseH4Filter)
   {
      double h4fast[], h4slow[];
      ArraySetAsSeries(h4fast, true); ArraySetAsSeries(h4slow, true);
      if(CopyBuffer(hEMA_H4_Fast, 0, 0, 3, h4fast) < 3) return;
      if(CopyBuffer(hEMA_H4_Slow, 0, 0, 3, h4slow) < 3) return;
      isBullTrend = isBullTrend && (h4fast[1] > h4slow[1]);
      isBearTrend = isBearTrend && (h4fast[1] < h4slow[1]);
   }

   if(UseH1Filter)
   {
      double h1fast[], h1slow[];
      ArraySetAsSeries(h1fast, true); ArraySetAsSeries(h1slow, true);
      if(CopyBuffer(hEMA_H1_Fast, 0, 0, 3, h1fast) < 3) return;
      if(CopyBuffer(hEMA_H1_Slow, 0, 0, 3, h1slow) < 3) return;
      isBullTrend = isBullTrend && (h1fast[1] > h1slow[1]);
      isBearTrend = isBearTrend && (h1fast[1] < h1slow[1]);
   }

   adxConfirm = true;
   if(UseADXFilter)
   {
      double adxMain[], diPlus[], diMinus[];
      ArraySetAsSeries(adxMain, true);
      ArraySetAsSeries(diPlus,  true);
      ArraySetAsSeries(diMinus, true);
      if(CopyBuffer(hADX_H1, 0, 0, 3, adxMain) < 3) { adxConfirm = false; return; }
      if(CopyBuffer(hADX_H1, 1, 0, 3, diPlus)  < 3) { adxConfirm = false; return; }
      if(CopyBuffer(hADX_H1, 2, 0, 3, diMinus) < 3) { adxConfirm = false; return; }

      double adxVal = adxMain[1];
      double dip    = diPlus[1];
      double dim    = diMinus[1];
      bool adxStrong = (adxVal >= ADX_MinLevel && adxVal <= ADX_MaxLevel);

      if(adxStrong)
      {
         isBullTrend = isBullTrend && (dip > dim);
         isBearTrend = isBearTrend && (dim > dip);
         adxConfirm  = true;
      }
      else
      {
         isBullTrend = false;
         isBearTrend = false;
         adxConfirm  = false;
      }
   }

   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(hATR, 0, 0, 3, atrBuf) >= 3)
      currentATR = atrBuf[1] / pointSize;
}

//+------------------------------------------------------------------+
//|  GetEntrySignal                                                   |
//+------------------------------------------------------------------+
int GetEntrySignal()
{
   if(!isBullTrend && !isBearTrend) return 0;

   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);

   int barsNeeded = BreakoutBars + 2;
   if(CopyHigh(_Symbol, PERIOD_M1, 1, barsNeeded, highs) < barsNeeded) return 0;
   if(CopyLow(_Symbol,  PERIOD_M1, 1, barsNeeded, lows)  < barsNeeded) return 0;

   double breakHigh = highs[ArrayMaximum(highs, 0, BreakoutBars)];
   double breakLow  = lows[ArrayMinimum(lows,  0, BreakoutBars)];

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Filtro de consolidacion previa
   if(ConsolidationBars > 0)
   {
      double consHigh = highs[ArrayMaximum(highs, 0, ConsolidationBars)];
      double consLow  = lows[ArrayMinimum(lows,  0, ConsolidationBars)];
      double range    = (consHigh - consLow) / pointSize;
      if(range > MaxRangePoints * 2) return 0;
   }

   //--- RSI
   double rsiVal = 50;
   if(UseRSIConfirm)
   {
      double rsiBuf[];
      ArraySetAsSeries(rsiBuf, true);
      if(CopyBuffer(hRSI_M1, 0, 0, 3, rsiBuf) < 3) return 0;
      rsiVal = rsiBuf[1];
   }

   //--- BTC tiene mayor volatilidad intrabar: usar cierre de barra anterior
   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(_Symbol, PERIOD_M1, 1, 3, closes) < 3) return 0;

   //--- SELL
   if(isBearTrend)
   {
      bool priceBreakdown = (bid < breakLow);
      bool rsiOK = !UseRSIConfirm || (rsiVal < RSI_OverboughtSell && rsiVal > 20);
      if(priceBreakdown && rsiOK) return -1;
   }

   //--- BUY
   if(isBullTrend)
   {
      bool priceBreakout = (ask > breakHigh);
      bool rsiOK = !UseRSIConfirm || (rsiVal > RSI_OversoldBuy && rsiVal < 80);
      if(priceBreakout && rsiOK) return 1;
   }

   return 0;
}

//+------------------------------------------------------------------+
//|  OpenTrade                                                        |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- SL dinamico con ATR (muy recomendado para BTC)
   double slPoints;
   if(UseATR_SL && currentATR > 0)
      slPoints = currentATR * ATR_Multiplier;
   else
      slPoints = StopLoss_Points;

   //--- En BTC nunca usar SL menor a 150 pts
   if(slPoints < 150) slPoints = 150;
   if(slPoints < minSL_Pts + 5) slPoints = minSL_Pts + 5;

   double tpPoints = TakeProfit_Points;

   double entryPrice, sl, tp;
   if(type == ORDER_TYPE_BUY)
   {
      entryPrice = ask;
      sl = NormalizeDouble(ask - slPoints * pointSize, symDigits);
      tp = NormalizeDouble(ask + tpPoints * pointSize, symDigits);
   }
   else
   {
      entryPrice = bid;
      sl = NormalizeDouble(bid + slPoints * pointSize, symDigits);
      tp = NormalizeDouble(bid - tpPoints * pointSize, symDigits);
   }

   double lots = CalculateLotSize(slPoints);
   if(lots <= 0) { Print("ERROR: Lote invalido: ", lots); return; }

   //--- Verificar spread (mas alto en BTC)
   double currentSpread = (ask - bid) / pointSize;
   if(currentSpread > MaxSpread_Points)
   {
      Print("Spread demasiado alto: ", currentSpread, " pts (max: ", MaxSpread_Points, ")");
      return;
   }

   bool result = false;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lots, _Symbol, entryPrice, sl, tp, TradeComment);
   else
      result = trade.Sell(lots, _Symbol, entryPrice, sl, tp, TradeComment);

   if(result)
   {
      dailyTrades++;
      string typeStr = (type == ORDER_TYPE_BUY) ? "BUY" : "SELL";
      Print("=== BTC OPERACION ABIERTA ===");
      Print("Tipo: ", typeStr, " | Lotes: ", lots);
      Print("Entrada: $", entryPrice, " | SL: $", sl, " | TP: $", tp);
      Print("SL: ", slPoints, " pts | TP: ", tpPoints, " pts | R:R = 1:", 
            DoubleToString(tpPoints / slPoints, 1));

      if(SendAlerts)
         Alert("TrendSniper BTC: ", typeStr, " @ $", entryPrice, 
               " | SL:", sl, " | TP:", tp);
      if(SendPushNotif)
         SendNotification("TrendSniper BTC: " + typeStr + " @ $" + 
                          DoubleToString(entryPrice, 0));
      if(SendEmail)
         SendMail("TrendSniper BTC Trade", typeStr + " BTC @ $" + 
                  DoubleToString(entryPrice, 0));
   }
   else
      Print("ERROR al abrir operacion BTC: ", trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//|  ManageOpenPositions — trailing y breakeven adaptados a BTC      |
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

      double newSL     = currentSL;
      bool   needMod   = false;

      double profitPts;
      if(posType == POSITION_TYPE_BUY)
         profitPts = (currentBid - openPrice) / pointSize;
      else
         profitPts = (openPrice - currentAsk) / pointSize;

      //--- BREAKEVEN
      if(UseBreakeven && profitPts >= BreakevenAt_Pts)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            double beSL = NormalizeDouble(openPrice + BreakevenBuffer * pointSize, symDigits);
            if(currentSL < beSL - pointSize) { newSL = beSL; needMod = true; }
         }
         else
         {
            double beSL = NormalizeDouble(openPrice - BreakevenBuffer * pointSize, symDigits);
            if(currentSL > beSL + pointSize || currentSL == 0)
               { newSL = beSL; needMod = true; }
         }
      }

      //--- TRAILING STOP
      if(UseTrailingStop && profitPts >= TrailStart_Points)
      {
         if(posType == POSITION_TYPE_BUY)
         {
            double trailSL = NormalizeDouble(currentBid - TrailDistance_Pts * pointSize, symDigits);
            if(trailSL > newSL + TrailStep_Points * pointSize)
               { newSL = trailSL; needMod = true; }
         }
         else
         {
            double trailSL = NormalizeDouble(currentAsk + TrailDistance_Pts * pointSize, symDigits);
            if(trailSL < newSL - TrailStep_Points * pointSize || newSL == 0)
               { newSL = trailSL; needMod = true; }
         }
      }

      //--- Aplicar modificacion
      if(needMod && newSL != currentSL)
      {
         double minDist = (minSL_Pts + 5) * pointSize;  // BTC: buffer mas amplio
         bool slValid = true;
         if(posType == POSITION_TYPE_BUY  && newSL > currentBid - minDist) slValid = false;
         if(posType == POSITION_TYPE_SELL && newSL < currentAsk + minDist) slValid = false;

         if(slValid)
            if(!trade.PositionModify(posInfo.Ticket(), newSL, currentTP))
               Print("ERROR modificando SL: ", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//|  CalculateLotSize                                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double slPoints)
{
   if(!UseRiskPercent) return NormalizeLot(FixedLotSize);

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (RiskPercent / 100.0);

   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointValue = (tickSize > 0) ? tickValue / tickSize * pointSize : 0;

   if(pointValue <= 0 || slPoints <= 0) return NormalizeLot(FixedLotSize);

   double lots = riskAmount / (slPoints * pointValue);
   return NormalizeLot(lots);
}

//+------------------------------------------------------------------+
//|  NormalizeLot                                                     |
//+------------------------------------------------------------------+
double NormalizeLot(double lots)
{
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lots = MathMax(lots, MinLotSize);
   lots = MathMin(lots, MaxLotSize);
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   lots = MathFloor(lots / lotStep) * lotStep;

   return NormalizeDouble(lots, 3);
}

//+------------------------------------------------------------------+
//|  CanTrade                                                         |
//+------------------------------------------------------------------+
bool CanTrade()
{
   if(MaxDailyLoss_Pct > 0 && dailyStartBal > 0)
   {
      double currentBal   = AccountInfoDouble(ACCOUNT_BALANCE);
      double dailyLossPct = ((dailyStartBal - currentBal) / dailyStartBal) * 100.0;
      if(dailyLossPct >= MaxDailyLoss_Pct)
      {
         Print("Limite diario alcanzado: ", DoubleToString(dailyLossPct, 2), "%");
         return false;
      }
   }
   if(dailyTrades >= MaxTradesPerDay) return false;
   if(UseSessionFilter && !IsInTradingSession()) return false;
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < 50) return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   return true;
}

//+------------------------------------------------------------------+
//|  IsInTradingSession                                               |
//+------------------------------------------------------------------+
bool IsInTradingSession()
{
   if(!UseSessionFilter) return true;

   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   int h = dt.hour;

   if(Session_StartHour < Session_EndHour)
      return (h >= Session_StartHour && h < Session_EndHour);
   else
      return (h >= Session_StartHour || h < Session_EndHour);
}

//+------------------------------------------------------------------+
//|  HasOpenPosition                                                  |
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
//|  ResetDailyCounters                                               |
//+------------------------------------------------------------------+
void ResetDailyCounters()
{
   dailyTrades   = 0;
   dailyStartBal = AccountInfoDouble(ACCOUNT_BALANCE);
}

//+------------------------------------------------------------------+
//|  CreateDashboard                                                  |
//+------------------------------------------------------------------+
void CreateDashboard()
{
   DeleteDashboard();

   int x = DashX, y = DashY, w = 290, lineH = 18, lines = 14;

   ObjectCreate(0, dashPrefix + "BG", OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_XDISTANCE,  x - 5);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_YDISTANCE,  y - 5);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_XSIZE,      w + 10);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_YSIZE,      lines * lineH + 15);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_BGCOLOR,    C'15,20,35');
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_COLOR,      C'40,100,200');
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_CORNER,     CORNER_LEFT_UPPER);
   ObjectSetInteger(0, dashPrefix + "BG", OBJPROP_BACK,       false);

   string labels[] = {"title","symbol","spread","trend_d1","trend_h4","trend_h1","adx",
                       "signal","sl","tp","rr","daily","trades","status"};

   for(int i = 0; i < ArraySize(labels); i++)
   {
      string n = dashPrefix + labels[i];
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_XDISTANCE,  x);
      ObjectSetInteger(0, n, OBJPROP_YDISTANCE,  y + i * lineH);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE,   8);
      ObjectSetString(0,  n, OBJPROP_FONT,       "Consolas");
      ObjectSetInteger(0, n, OBJPROP_COLOR,      clrWhite);
      ObjectSetString(0,  n, OBJPROP_TEXT,       "---");
   }

   ObjectSetString(0,  dashPrefix + "title", OBJPROP_TEXT, "=== TrendSniper BTC EA v2.0 ===");
   ObjectSetInteger(0, dashPrefix + "title", OBJPROP_COLOR, ColorNeutral);
   ObjectSetInteger(0, dashPrefix + "title", OBJPROP_FONTSIZE, 9);

   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|  UpdateDashboard                                                  |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) -
                    SymbolInfoDouble(_Symbol, SYMBOL_BID)) / pointSize;

   string trendStr;
   color  trendColor;
   if(isBullTrend)      { trendStr = "ALCISTA ▲"; trendColor = ColorBull; }
   else if(isBearTrend) { trendStr = "BAJISTA ▼"; trendColor = ColorBear; }
   else                 { trendStr = "NEUTRAL  -"; trendColor = ColorNeutral; }

   double d1f[], d1s[], h4f[], h4s[], h1f[], h1s[];
   ArraySetAsSeries(d1f,true); ArraySetAsSeries(d1s,true);
   ArraySetAsSeries(h4f,true); ArraySetAsSeries(h4s,true);
   ArraySetAsSeries(h1f,true); ArraySetAsSeries(h1s,true);

   bool d1bull=false, h4bull=false, h1bull=false;
   bool d1bear=false, h4bear=false, h1bear=false;

   if(CopyBuffer(hEMA_D1_Fast,0,1,1,d1f)==1 && CopyBuffer(hEMA_D1_Slow,0,1,1,d1s)==1)
      { d1bull=d1f[0]>d1s[0]; d1bear=d1f[0]<d1s[0]; }
   if(CopyBuffer(hEMA_H4_Fast,0,1,1,h4f)==1 && CopyBuffer(hEMA_H4_Slow,0,1,1,h4s)==1)
      { h4bull=h4f[0]>h4s[0]; h4bear=h4f[0]<h4s[0]; }
   if(CopyBuffer(hEMA_H1_Fast,0,1,1,h1f)==1 && CopyBuffer(hEMA_H1_Slow,0,1,1,h1s)==1)
      { h1bull=h1f[0]>h1s[0]; h1bear=h1f[0]<h1s[0]; }

   double adxBuf[];
   ArraySetAsSeries(adxBuf, true);
   string adxStr = "---";
   if(CopyBuffer(hADX_H1, 0, 1, 1, adxBuf) == 1)
      adxStr = DoubleToString(adxBuf[0], 1);

   string posStr = "Sin posicion";
   double profitVal = 0;
   if(HasOpenPosition())
   {
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(!posInfo.SelectByIndex(i)) continue;
         if(posInfo.Magic() != MagicNumber) continue;
         string dir = (posInfo.PositionType() == POSITION_TYPE_BUY) ? "BUY" : "SELL";
         profitVal  = posInfo.Profit() + posInfo.Swap();
         posStr = dir + " | P&L: $" + DoubleToString(profitVal, 2);
      }
   }

   double currentBal   = AccountInfoDouble(ACCOUNT_BALANCE);
   double dailyLossPct = 0;
   if(dailyStartBal > 0)
      dailyLossPct = ((dailyStartBal - currentBal) / dailyStartBal) * 100.0;

   //--- Precio actual BTC en dolares
   double btcPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   ObjectSetString(0, dashPrefix + "symbol",  OBJPROP_TEXT,
      StringFormat("BTC: $%.0f | Spread: %.0f pts", btcPrice, spread));
   ObjectSetString(0, dashPrefix + "spread",  OBJPROP_TEXT,
      StringFormat("ATR: %.0f pts | Sesion: %s", currentATR,
      IsInTradingSession() ? "ACTIVA" : "INACTIVA"));
   ObjectSetInteger(0, dashPrefix + "spread", OBJPROP_COLOR,
      IsInTradingSession() ? ColorBull : ColorNeutral);

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
      StringFormat("SL: %.0f pts ($%.0f) | TP: %.0f pts",
      StopLoss_Points, StopLoss_Points * pointSize, TakeProfit_Points));

   ObjectSetString(0, dashPrefix + "tp", OBJPROP_TEXT,
      StringFormat("ATR x%.1f = SL dinamico | R:R = 1:%.0f",
      ATR_Multiplier, TakeProfit_Points / StopLoss_Points));

   ObjectSetString(0, dashPrefix + "rr", OBJPROP_TEXT,
      StringFormat("Riesgo/op: %.2f%% | Max ops/dia: %d", RiskPercent, MaxTradesPerDay));

   ObjectSetString(0, dashPrefix + "daily", OBJPROP_TEXT,
      StringFormat("Dd diario: %.2f%% / %.1f%% | Ops: %d",
      MathAbs(dailyLossPct), MaxDailyLoss_Pct, dailyTrades));
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
//|  DeleteDashboard                                                  |
//+------------------------------------------------------------------+
void DeleteDashboard()
{
   ObjectsDeleteAll(0, dashPrefix);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//|  OnTradeTransaction                                               |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      if(HistoryDealSelect(trans.deal))
      {
         if(HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            double dealProfit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            double dealSwap   = HistoryDealGetDouble(trans.deal, DEAL_SWAP);
            double total      = dealProfit + dealSwap;

            Print("=== CIERRE BTC ===");
            Print("P&L: $", DoubleToString(total, 2),
                  total >= 0 ? " >>> GANANCIA" : " >>> SL activado");

            if(SendAlerts)
               Alert("TrendSniper BTC CERRADO: $", DoubleToString(total, 2));
         }
      }
   }
}

//+------------------------------------------------------------------+