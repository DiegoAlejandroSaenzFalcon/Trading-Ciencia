//+------------------------------------------------------------------+
//|                                                 SatoshiumEA.mq5  |
//|                    Replica fiel de Satoshium EA                   |
//|    BTCUSD | SMC + Reinforcement Learning Scoring | ATR SL        |
//+------------------------------------------------------------------+
#property copyright   "Replica Satoshium EA"
#property link        ""
#property version     "1.00"
#property description "BTCUSD | Smart Money Concepts | RL-Scoring Engine | ATR-based SL | Sin Martingala"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs: Par y Temporalidades
input group              "=== PAR Y TEMPORALIDADES ==="
input ENUM_TIMEFRAMES InpAnalysisTF1 = PERIOD_H4;   // TF análisis macro
input ENUM_TIMEFRAMES InpAnalysisTF2 = PERIOD_H1;   // TF análisis intermedio
input ENUM_TIMEFRAMES InpEntryTF     = PERIOD_M15;  // TF de ejecución (M5 o M15)

//--- Inputs: Gestión de Riesgo (Sin Martingala, Sin Grid)
input group              "=== GESTIÓN DE RIESGO ==="
input double   InpRiskPercent        = 1.0;    // Riesgo fijo % por operación
input int      InpMaxOpenTrades      = 1;      // Máximo 1 posición (sin grid)
input double   InpMaxDDPercent       = 15.0;   // Drawdown máximo (%)

//--- Inputs: ATR Stop Loss
input group              "=== ATR STOP LOSS (FIJO) ==="
input int      InpATRPeriod          = 14;     // Período ATR
input double   InpATRSLMultiplier    = 2.0;    // Multiplicador ATR para SL
input double   InpATRTPMultiplier    = 3.5;    // Multiplicador ATR para TP
input ENUM_TIMEFRAMES InpATRTimeframe = PERIOD_H1; // TF del ATR

//--- Inputs: Order Block BTC
input group              "=== ORDER BLOCKS BTC ==="
input int      InpOBLookback         = 40;    // Velas atrás para OB
input int      InpImpulseLookback    = 5;     // Velas impulso para confirmar OB
input double   InpOBMinBodyMulti     = 0.8;   // Tamaño mínimo cuerpo OB (x ATR)
input double   InpOBMitigationPct    = 0.3;   // % penetración OB para mitigación

//--- Inputs: RL Scoring Engine
input group              "=== MOTOR DE SCORING (RL-LIKE) ==="
input int      InpMinScore           = 70;    // Puntuación mínima para entrar (0-100)
input int      InpHistoricalBars     = 200;   // Barras históricas para calcular score
input double   InpWinRateWeight      = 0.4;   // Peso tasa de éxito en score
input double   InpRRWeight           = 0.3;   // Peso Riesgo/Recompensa en score
input double   InpVolatWeight        = 0.15;  // Peso volatilidad en score
input double   InpTrendWeight        = 0.15;  // Peso alineación tendencia en score

//--- Inputs: Estructura de Mercado
input group              "=== ESTRUCTURA DE MERCADO ==="
input int      InpSwingLookback      = 15;    // Velas para swing points
input bool     InpRequireMSS         = true;  // Requerir Market Structure Shift
input bool     InpRequireLiqSweep    = false; // Requerir Barrido de Liquidez

//--- Inputs: Config
input group              "=== CONFIGURACIÓN ==="
input ulong    InpMagic              = 20240704;   // Magic Number
input int      InpSlippage           = 30;         // Slippage (puntos, BTC)
input bool     InpPrintLogs          = true;       // Logs detallados
input bool     InpUseTrailing        = true;       // Trailing Stop
input double   InpTrailATRMulti      = 1.5;        // Multiplicador ATR Trailing

//--- Estructuras
struct SBTCOrderBlock
{
   double   high;
   double   low;
   double   mid;
   datetime time;
   int      direction;       // 1=demanda, -1=oferta
   bool     mitigated;
   double   impulsePips;     // Tamaño del impulso que validó el OB
   int      touchCount;      // Veces que el precio tocó el OB
   double   scoreAtFormation;// Score del motor RL al momento de formación
};

struct SRLScore
{
   double   totalScore;      // Score total 0-100
   double   winRateScore;    // Sub-score win rate
   double   rrScore;         // Sub-score R:R
   double   volatScore;      // Sub-score volatilidad
   double   trendScore;      // Sub-score tendencia
   int      sampleSize;      // Muestra utilizada
};

struct SBTCMarketStructure
{
   int      trend;           // 1=alcista, -1=bajista, 0=lateral
   double   lastHighPoint;
   double   lastLowPoint;
   bool     mssDetected;
   int      mssDirection;    // 1=MSS alcista, -1=MSS bajista
   bool     liquiditySweep;
   double   liquidityLevel;
   int      sweepDirection;
};

//--- Variables globales
CTrade        trade;
CPositionInfo posInfo;

int    handleATR_H1, handleATR_H4;
int    handleEMA20, handleEMA50, handleEMA200;
int    handleRSI, handleMACD;

double pipSize;
datetime lastBarEntry = 0;
double   peakBalance  = 0.0;

SBTCOrderBlock bullOB, bearOB;
SBTCMarketStructure btcStructure;
SRLScore       lastScore;

//+------------------------------------------------------------------+
//| Inicialización                                                     |
//+------------------------------------------------------------------+
int OnInit()
{
   // Validar símbolo BTC
   string sym = _Symbol;
   bool isBTC = (StringFind(sym, "BTC") >= 0) || (StringFind(sym, "btc") >= 0) ||
                (StringFind(sym, "BITCOIN") >= 0);
   if(!isBTC)
      Print("[SATO] ADVERTENCIA: Este EA está diseñado para BTCUSD. Símbolo: ", sym);

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFilling(ORDER_FILLING_FOK);

   pipSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;

   handleATR_H1  = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
   handleATR_H4  = iATR(_Symbol, InpAnalysisTF1,  InpATRPeriod);
   handleEMA20   = iMA(_Symbol, InpAnalysisTF2, 20, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA50   = iMA(_Symbol, InpAnalysisTF2, 50, 0, MODE_EMA, PRICE_CLOSE);
   handleEMA200  = iMA(_Symbol, InpAnalysisTF1, 200, 0, MODE_EMA, PRICE_CLOSE);
   handleRSI     = iRSI(_Symbol, InpEntryTF, 14, PRICE_CLOSE);
   handleMACD    = iMACD(_Symbol, InpEntryTF, 12, 26, 9, PRICE_CLOSE);

   if(handleATR_H1 == INVALID_HANDLE || handleATR_H4 == INVALID_HANDLE ||
      handleEMA20  == INVALID_HANDLE || handleEMA50  == INVALID_HANDLE ||
      handleEMA200 == INVALID_HANDLE || handleRSI    == INVALID_HANDLE ||
      handleMACD   == INVALID_HANDLE)
   {
      Print("[SATO] ERROR: Fallo al crear indicadores.");
      return INIT_FAILED;
   }

   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   ZeroMemory(bullOB);
   ZeroMemory(bearOB);
   ZeroMemory(btcStructure);
   ZeroMemory(lastScore);

   Print("[SATO] Satoshium EA inicializado. Par: ", _Symbol);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Liberación                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(handleATR_H1);
   IndicatorRelease(handleATR_H4);
   IndicatorRelease(handleEMA20);
   IndicatorRelease(handleEMA50);
   IndicatorRelease(handleEMA200);
   IndicatorRelease(handleRSI);
   IndicatorRelease(handleMACD);
}

//+------------------------------------------------------------------+
//| Tick principal                                                     |
//+------------------------------------------------------------------+
void OnTick()
{
   // Control de drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal    = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal > peakBalance) peakBalance = bal;
   if(peakBalance > 0.0 && (peakBalance - equity) / peakBalance * 100.0 >= InpMaxDDPercent)
   {
      Print("[SATO] Drawdown máximo alcanzado. Cerrando posiciones.");
      CloseAllMyPositions();
      return;
   }

   // Trailing Stop (cada tick)
   if(InpUseTrailing) ManageTrailingATR();

   // Solo nueva vela de entrada
   if(!IsNewBar(InpEntryTF)) return;

   // Máximo 1 trade abierto (sin grid, sin martingala)
   if(CountMyPositions() >= InpMaxOpenTrades) return;

   // Actualizar análisis macro
   UpdateBTCStructure();
   FindBTCOrderBlocks();

   // Motor de Scoring RL-like
   SRLScore score;
   CalculateRLScore(score);
   lastScore = score;

   if(score.totalScore < (double)InpMinScore)
   {
      if(InpPrintLogs)
         Print("[SATO] Score insuficiente: ", DoubleToString(score.totalScore, 1),
               " (mín:", InpMinScore, ")");
      return;
   }

   // Calcular ATR para SL/TP
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_H1, 0, 0, 3, atrBuf) < 3) return;
   double atr = atrBuf[1];

   // Evaluar entrada
   EvaluateBTCEntry(atr, score);
}

//+------------------------------------------------------------------+
//| Analiza estructura de mercado BTC                                 |
//+------------------------------------------------------------------+
void UpdateBTCStructure()
{
   // Swing points en HTF
   double highs[], lows[];
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows,  true);
   int bars = InpSwingLookback + 5;
   if(CopyHigh(_Symbol, InpAnalysisTF1, 1, bars, highs) < bars) return;
   if(CopyLow(_Symbol,  InpAnalysisTF1, 1, bars, lows)  < bars) return;

   // Encontrar swing high y low
   double swH = 0.0, swL = DBL_MAX;
   for(int i = 2; i < InpSwingLookback; i++)
   {
      if(highs[i] > highs[i-1] && highs[i] > highs[i-2] &&
         highs[i] > highs[i+1] && highs[i] > highs[i+2])
         if(highs[i] > swH) swH = highs[i];

      if(lows[i] < lows[i-1] && lows[i] < lows[i-2] &&
         lows[i] < lows[i+1] && lows[i] < lows[i+2])
         if(lows[i] < swL) swL = lows[i];
   }
   if(swL == DBL_MAX) swL = 0.0;

   double prevH = btcStructure.lastHighPoint;
   double prevL = btcStructure.lastLowPoint;
   btcStructure.lastHighPoint = swH;
   btcStructure.lastLowPoint  = swL;

   double ema200Buf[], ema50Buf[];
   ArraySetAsSeries(ema200Buf, true);
   ArraySetAsSeries(ema50Buf,  true);
   if(CopyBuffer(handleEMA200, 0, 0, 3, ema200Buf) < 3) return;
   if(CopyBuffer(handleEMA50,  0, 0, 3, ema50Buf)  < 3) return;

   double close = iClose(_Symbol, InpAnalysisTF1, 1);

   // Tendencia HTF
   if(close > ema200Buf[1] && ema50Buf[1] > ema200Buf[1]) btcStructure.trend = 1;
   else if(close < ema200Buf[1] && ema50Buf[1] < ema200Buf[1]) btcStructure.trend = -1;
   else btcStructure.trend = 0;

   // Market Structure Shift (MSS)
   btcStructure.mssDetected  = false;
   btcStructure.mssDirection = 0;
   if(prevH > 0.0 && prevL > 0.0)
   {
      // MSS Alcista: precio rompe swing high en tendencia bajista
      if(close > prevH && btcStructure.trend == -1)
      {
         btcStructure.mssDetected  = true;
         btcStructure.mssDirection = 1;
         Print("[SATO] MSS Alcista detectado en HTF! Precio:", DoubleToString(close, 2));
      }
      // MSS Bajista: precio rompe swing low en tendencia alcista
      if(close < prevL && prevL > 0.0 && btcStructure.trend == 1)
      {
         btcStructure.mssDetected  = true;
         btcStructure.mssDirection = -1;
         Print("[SATO] MSS Bajista detectado en HTF! Precio:", DoubleToString(close, 2));
      }
   }

   // Barrido de liquidez (Liquidity Sweep)
   btcStructure.liquiditySweep = false;
   if(swH > 0.0 && swL > 0.0)
   {
      double atr4Buf[];
      ArraySetAsSeries(atr4Buf, true);
      if(CopyBuffer(handleATR_H4, 0, 0, 3, atr4Buf) < 3) return;
      double atr4 = atr4Buf[1];

      // Precio barrió swing high pero cerró abajo (barrido bajista)
      double candleHigh = iHigh(_Symbol, InpAnalysisTF1, 1);
      double candleLow  = iLow(_Symbol,  InpAnalysisTF1, 1);

      if(candleHigh > swH && close < swH - atr4 * 0.1)
      {
         btcStructure.liquiditySweep = true;
         btcStructure.liquidityLevel = swH;
         btcStructure.sweepDirection = -1;
      }
      if(swL > 0.0 && candleLow < swL && close > swL + atr4 * 0.1)
      {
         btcStructure.liquiditySweep = true;
         btcStructure.liquidityLevel = swL;
         btcStructure.sweepDirection = 1;
      }
   }
}

//+------------------------------------------------------------------+
//| Encuentra Order Blocks específicos para BTC                       |
//+------------------------------------------------------------------+
void FindBTCOrderBlocks()
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_H1, 0, 0, InpOBLookback + 5, atrBuf) < InpOBLookback + 5) return;

   double atrAvg = 0.0;
   for(int k = 1; k <= 10; k++) atrAvg += atrBuf[k];
   atrAvg /= 10.0;

   ZeroMemory(bullOB);
   ZeroMemory(bearOB);

   // Buscar en H1 para mayor precisión en BTC
   for(int i = 3; i < InpOBLookback; i++)
   {
      double open_i  = iOpen(_Symbol,  InpAnalysisTF2, i);
      double close_i = iClose(_Symbol, InpAnalysisTF2, i);
      double high_i  = iHigh(_Symbol,  InpAnalysisTF2, i);
      double low_i   = iLow(_Symbol,   InpAnalysisTF2, i);
      datetime t_i   = iTime(_Symbol,  InpAnalysisTF2, i);

      double body_i = MathAbs(close_i - open_i);
      if(body_i < atrAvg * InpOBMinBodyMulti) continue;

      // Calcular el impulso generado tras el OB (velas i-1, i-2)
      double impulse = 0.0;
      for(int j = 1; j <= InpImpulseLookback && j < i; j++)
      {
         double c_j = iClose(_Symbol, InpAnalysisTF2, i - j);
         impulse += MathAbs(c_j - iOpen(_Symbol, InpAnalysisTF2, i - j));
      }

      double currentPrice = iClose(_Symbol, InpAnalysisTF2, 1);

      // OB Alcista (Demanda): vela bajista grande + impulso alcista posterior
      if(close_i < open_i)
      {
         double impulseUp = iClose(_Symbol, InpAnalysisTF2, i - 1) -
                            iOpen(_Symbol,  InpAnalysisTF2, i - 1);
         if(impulseUp > body_i * 1.2 && currentPrice > high_i)
         {
            if(bullOB.time == 0 || t_i > bullOB.time)
            {
               bullOB.high             = high_i;
               bullOB.low              = low_i;
               bullOB.mid              = (high_i + low_i) / 2.0;
               bullOB.time             = t_i;
               bullOB.direction        = 1;
               bullOB.mitigated        = (currentPrice < bullOB.low + (bullOB.high - bullOB.low) * InpOBMitigationPct);
               bullOB.impulsePips      = impulse / pipSize;
               bullOB.scoreAtFormation = 0.0;
            }
         }
      }

      // OB Bajista (Oferta): vela alcista grande + impulso bajista posterior
      if(close_i > open_i)
      {
         double impulseDown = iOpen(_Symbol,  InpAnalysisTF2, i - 1) -
                              iClose(_Symbol, InpAnalysisTF2, i - 1);
         if(impulseDown > body_i * 1.2 && currentPrice < low_i)
         {
            if(bearOB.time == 0 || t_i > bearOB.time)
            {
               bearOB.high             = high_i;
               bearOB.low              = low_i;
               bearOB.mid              = (high_i + low_i) / 2.0;
               bearOB.time             = t_i;
               bearOB.direction        = -1;
               bearOB.mitigated        = (currentPrice > bearOB.high - (bearOB.high - bearOB.low) * InpOBMitigationPct);
               bearOB.impulsePips      = impulse / pipSize;
               bearOB.scoreAtFormation = 0.0;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Motor de Scoring RL-like: valida probabilidad del setup BTC       |
//+------------------------------------------------------------------+
void CalculateRLScore(SRLScore &score)
{
   ZeroMemory(score);

   double atr4Buf[], ema20Buf[], ema50Buf[], ema200Buf[];
   ArraySetAsSeries(atr4Buf,  true);
   ArraySetAsSeries(ema20Buf, true);
   ArraySetAsSeries(ema50Buf, true);
   ArraySetAsSeries(ema200Buf,true);

   if(CopyBuffer(handleATR_H4,  0, 0, 20, atr4Buf)  < 20) return;
   if(CopyBuffer(handleEMA20,   0, 0,  5, ema20Buf)  < 5)  return;
   if(CopyBuffer(handleEMA50,   0, 0,  5, ema50Buf)  < 5)  return;
   if(CopyBuffer(handleEMA200,  0, 0,  5, ema200Buf) < 5)  return;

   double close = iClose(_Symbol, InpAnalysisTF2, 1);

   // 1. Score de Win Rate: basado en patrones históricos similares
   //    Simula el RL evaluando cuántas veces condiciones similares dieron resultado
   double winRateRaw = 0.0;
   int    wins = 0, total = 0;
   for(int i = 10; i < InpHistoricalBars && i < Bars(_Symbol, InpEntryTF) - 5; i++)
   {
      double h_close = iClose(_Symbol, InpEntryTF, i);
      double h_ema20 = 0.0, h_ema50 = 0.0;

      // Condición similar: precio sobre EMA20 y EMA50
      // (simplificado para no requerir CopyBuffer con offset dinámico)
      bool similarCondition = (h_close > ema20Buf[MathMin(4, i)] &&
                               h_close > ema50Buf[MathMin(4, i)]);
      if(!similarCondition) continue;

      // Resultado: precio 5 velas después
      double futureClose = iClose(_Symbol, InpEntryTF, i - 5);
      if(futureClose > h_close) wins++;
      total++;
   }
   if(total > 20) winRateRaw = (double)wins / total;
   else           winRateRaw = 0.5; // neutral si poca muestra
   score.sampleSize  = total;
   score.winRateScore = winRateRaw * 100.0;

   // 2. Score R:R: basado en la distancia al OB vs distancia al target histórico
   double rrRaw = 0.5;
   if(btcStructure.trend == 1 && bullOB.time > 0)
   {
      double risk = close - bullOB.low;
      double reward = btcStructure.lastHighPoint - close;
      if(risk > 0.0 && reward > 0.0) rrRaw = MathMin(1.0, reward / (risk * 5.0));
   }
   else if(btcStructure.trend == -1 && bearOB.time > 0)
   {
      double risk   = bearOB.high - close;
      double reward = close - btcStructure.lastLowPoint;
      if(risk > 0.0 && reward > 0.0 && btcStructure.lastLowPoint > 0.0)
         rrRaw = MathMin(1.0, reward / (risk * 5.0));
   }
   score.rrScore = rrRaw * 100.0;

   // 3. Score de Volatilidad: ATR estable vs alto (BTC es volátil, score penaliza extremos)
   double atrNow = atr4Buf[1];
   double atrAvg = 0.0;
   for(int k = 2; k <= 19; k++) atrAvg += atr4Buf[k];
   atrAvg /= 18.0;
   double atrRatio  = (atrAvg > 0.0) ? atrNow / atrAvg : 1.0;
   double volatRaw  = 1.0 - MathAbs(atrRatio - 1.0); // 1.0 si ATR = promedio
   volatRaw = MathMax(0.0, MathMin(1.0, volatRaw));
   score.volatScore = volatRaw * 100.0;

   // 4. Score de Alineación de Tendencia
   double trendRaw = 0.5;
   bool ema_bullish = (ema20Buf[1] > ema50Buf[1]) && (ema50Buf[1] > ema200Buf[1]) &&
                      (close > ema200Buf[1]);
   bool ema_bearish = (ema20Buf[1] < ema50Buf[1]) && (ema50Buf[1] < ema200Buf[1]) &&
                      (close < ema200Buf[1]);
   bool mssBonus = btcStructure.mssDetected;
   bool liquidBonus = btcStructure.liquiditySweep;

   if(ema_bullish || ema_bearish) trendRaw = 0.8;
   if(mssBonus)    trendRaw += 0.1;
   if(liquidBonus) trendRaw += 0.1;
   trendRaw = MathMin(1.0, trendRaw);
   score.trendScore = trendRaw * 100.0;

   // Score total ponderado
   score.totalScore = score.winRateScore * InpWinRateWeight +
                      score.rrScore      * InpRRWeight      +
                      score.volatScore   * InpVolatWeight   +
                      score.trendScore   * InpTrendWeight;

   if(InpPrintLogs)
      Print("[SATO] RL Score: TOTAL=", DoubleToString(score.totalScore,1),
            " WinRate=", DoubleToString(score.winRateScore,1),
            " RR=",      DoubleToString(score.rrScore,1),
            " Volat=",   DoubleToString(score.volatScore,1),
            " Trend=",   DoubleToString(score.trendScore,1),
            " Muestra=", score.sampleSize);
}

//+------------------------------------------------------------------+
//| Evalúa entrada BTC                                                |
//+------------------------------------------------------------------+
void EvaluateBTCEntry(double atr, const SRLScore &score)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double rsiB[];
   double macdMain[], macdSig[];
   ArraySetAsSeries(rsiB,    true);
   ArraySetAsSeries(macdMain,true);
   ArraySetAsSeries(macdSig, true);
   if(CopyBuffer(handleRSI,  0,          0, 3, rsiB)    < 3) return;
   if(CopyBuffer(handleMACD, MAIN_LINE,  0, 3, macdMain) < 3) return;
   if(CopyBuffer(handleMACD, SIGNAL_LINE,0, 3, macdSig)  < 3) return;

   bool macdBull = (macdMain[1] > macdSig[1]) && (macdMain[2] <= macdSig[2]);
   bool macdBear = (macdMain[1] < macdSig[1]) && (macdMain[2] >= macdSig[2]);

   // Filtros adicionales
   bool mssOK    = !InpRequireMSS     || btcStructure.mssDetected;
   bool sweepOK  = !InpRequireLiqSweep || btcStructure.liquiditySweep;

   // ===== LONG BTC =====
   if(btcStructure.trend == 1 && bullOB.time > 0 && !bullOB.mitigated && mssOK && sweepOK)
   {
      bool priceAtOB = (ask >= bullOB.low) && (ask <= bullOB.high + atr * 0.2);
      bool rsiOK     = (rsiB[1] > 40.0 && rsiB[1] < 70.0);

      if(priceAtOB && rsiOK && macdBull)
      {
         double slPrice = NormalizeDouble(bullOB.low - atr * InpATRSLMultiplier, _Digits);
         double risk    = ask - slPrice;
         if(risk <= 0.0) return;
         double tpPrice = NormalizeDouble(ask + atr * InpATRTPMultiplier, _Digits);

         double lot = CalcFixedRiskLot(risk);
         if(lot <= 0.0) return;

         if(trade.Buy(lot, _Symbol, ask, slPrice, tpPrice, "SATO_LONG"))
         {
            bullOB.scoreAtFormation = score.totalScore;
            Print("[SATO] BTC LONG | OB[", DoubleToString(bullOB.low,2),"-",
                  DoubleToString(bullOB.high,2), "] Score:", DoubleToString(score.totalScore,1),
                  " SL:", DoubleToString(slPrice,2), " TP:", DoubleToString(tpPrice,2),
                  " Lot:", lot);
         }
      }
   }

   // ===== SHORT BTC =====
   if(btcStructure.trend == -1 && bearOB.time > 0 && !bearOB.mitigated && mssOK && sweepOK)
   {
      bool priceAtOB = (bid <= bearOB.high) && (bid >= bearOB.low - atr * 0.2);
      bool rsiOK     = (rsiB[1] < 60.0 && rsiB[1] > 30.0);

      if(priceAtOB && rsiOK && macdBear)
      {
         double slPrice = NormalizeDouble(bearOB.high + atr * InpATRSLMultiplier, _Digits);
         double risk    = slPrice - bid;
         if(risk <= 0.0) return;
         double tpPrice = NormalizeDouble(bid - atr * InpATRTPMultiplier, _Digits);
         if(tpPrice <= 0.0) return;

         double lot = CalcFixedRiskLot(risk);
         if(lot <= 0.0) return;

         if(trade.Sell(lot, _Symbol, bid, slPrice, tpPrice, "SATO_SHORT"))
         {
            bearOB.scoreAtFormation = score.totalScore;
            Print("[SATO] BTC SHORT | OB[", DoubleToString(bearOB.low,2),"-",
                  DoubleToString(bearOB.high,2), "] Score:", DoubleToString(score.totalScore,1),
                  " SL:", DoubleToString(slPrice,2), " TP:", DoubleToString(tpPrice,2),
                  " Lot:", lot);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Trailing Stop basado en ATR                                       |
//+------------------------------------------------------------------+
void ManageTrailingATR()
{
   double atrBuf[];
   ArraySetAsSeries(atrBuf, true);
   if(CopyBuffer(handleATR_H1, 0, 0, 3, atrBuf) < 3) return;
   double trailDist = atrBuf[1] * InpTrailATRMulti;

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
         if(newSL > openP && newSL > curSL + SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10)
            trade.PositionModify(ticket, newSL, curTP);
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double newSL = NormalizeDouble(ask + trailDist, _Digits);
         if(newSL < openP && (curSL == 0.0 || newSL < curSL - SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10))
            trade.PositionModify(ticket, newSL, curTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Calcula lote con riesgo fijo (SIN Martingala)                    |
//+------------------------------------------------------------------+
double CalcFixedRiskLot(double slPrice)
{
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmt  = balance * InpRiskPercent / 100.0;
   double tickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSz   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double minLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(tickVal <= 0.0 || tickSz <= 0.0 || slPrice <= 0.0) return minLot;

   // Lote fijo por riesgo porcentual (jamás aumenta por pérdidas)
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
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic) count++;
   }
   return count;
}

bool IsNewBar(ENUM_TIMEFRAMES tf)
{
   datetime cur = iTime(_Symbol, tf, 0);
   if(cur != lastBarEntry)
   {
      lastBarEntry = cur;
      return true;
   }
   return false;
}
//+------------------------------------------------------------------+