//+------------------------------------------------------------------+
//|                                  NeurAlgo_AsianMeanReversion.mq5 |
//|                             Institutional Quant Architecture V1.0|
//|                                     Strict MQL5 - No Warnings    |
//+------------------------------------------------------------------+
#property copyright "NeurAlgo Algorithmic Trading"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "Advanced Statistical Arbitrage & Mean Reversion for Asian Session."
#property description "Z-Score + ADX Filter + Micro-RSI Trigger. Market Ready."
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Input Parameters ---
input group "=== Institutional Risk Management ==="
input double   InpRiskPercent       = 1.5;      // Max Risk per Trade (%)
input double   InpMaxSpreadPips     = 2.0;      // Maximum Spread allowed (Pips)

input group "=== Temporal Filters (GMT Based) ==="
input int      InpStartHourGMT      = 22;       // Trading Start Hour (GMT)
input int      InpEndHourGMT        = 4;        // Trading End Hour (GMT)

input group "=== Algorithmic Logic (Math) ==="
input int      InpZScorePeriod      = 50;       // SMA & StDev Period
input double   InpZScoreThreshold   = 2.5;      // Standard Deviation Extremes (+/-)
input int      InpADXPeriod         = 14;       // ADX Trend Filter Period
input double   InpADXLevel          = 25.0;     // Max ADX allowed for Mean Reversion
input int      InpRsiPeriod         = 3;        // Micro RSI Period (Trigger)
input double   InpATRPeriod         = 14;       // ATR Period for Dynamic Stops
input double   InpATRMultiplierSL   = 2.0;      // ATR Multiplier for Stop Loss

input group "=== Magic Number & ID ==="
input ulong    InpMagicNumber       = 20260428; // Unique EA Identifier

//--- Global Objects ---
CTrade         m_trade;
CSymbolInfo    m_symbol;
CPositionInfo  m_position;
CAccountInfo   m_account;

//--- Indicator Handles ---
int            m_handle_sma;
int            m_handle_stddev;
int            m_handle_adx;
int            m_handle_rsi;
int            m_handle_atr;

//--- Global Variables ---
double         m_point;
int            m_digits;
datetime       m_last_bar_time;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   // 1. Init Symbol Info
   if(!m_symbol.Name(_Symbol))
     {
      Print("Error initializing symbol.");
      return(INIT_FAILED);
     }
   
   m_point = m_symbol.Point();
   m_digits = m_symbol.Digits();
   
   // 2. Setup Trade Class
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetMarginMode();
   m_trade.SetTypeFillingBySymbol(_Symbol);

   // 3. Initialize Indicator Handles
   m_handle_sma = iMA(_Symbol, PERIOD_M15, InpZScorePeriod, 0, MODE_SMA, PRICE_CLOSE);
   m_handle_stddev = iStdDev(_Symbol, PERIOD_M15, InpZScorePeriod, 0, MODE_SMA, PRICE_CLOSE);
   m_handle_adx = iADX(_Symbol, PERIOD_M15, InpADXPeriod);
   m_handle_rsi = iRSI(_Symbol, PERIOD_M15, InpRsiPeriod, PRICE_CLOSE);
   m_handle_atr = iATR(_Symbol, PERIOD_M15, (int)InpATRPeriod);

   if(m_handle_sma == INVALID_HANDLE || m_handle_stddev == INVALID_HANDLE || 
      m_handle_adx == INVALID_HANDLE || m_handle_rsi == INVALID_HANDLE || m_handle_atr == INVALID_HANDLE)
     {
      Print("Error creating indicator handles.");
      return(INIT_FAILED);
     }

   Print("NeurAlgo V1.0 initialized successfully on ", _Symbol);
   Print("Ensure your VPS GMT time corresponds correctly. System mapped for Asian Session.");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(m_handle_sma);
   IndicatorRelease(m_handle_stddev);
   IndicatorRelease(m_handle_adx);
   IndicatorRelease(m_handle_rsi);
   IndicatorRelease(m_handle_atr);
   Print("NeurAlgo de-initialized.");
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // Operate strictly on New Bar (M15) to save CPU and simulate institutional HFT batching
   datetime time[];
   if(CopyTime(_Symbol, PERIOD_M15, 0, 1, time) <= 0) return;
   if(time[0] == m_last_bar_time) return; // Not a new bar
   
   // Update Time
   m_last_bar_time = time[0];

   // 1. Time Session Gate Check (GMT Based)
   if(!IsAsianSessionActive()) return;

   // 2. Spread Check
   m_symbol.RefreshRates();
   double current_spread = (m_symbol.Ask() - m_symbol.Bid()) / m_point;
   if(current_spread > (InpMaxSpreadPips * 10)) // Converting pips to points
     {
      Print("Spread too high: ", current_spread, " points. Order skipped.");
      return;
     }

   // 3. Manage Open Positions (Time Stop or TP Logic)
   ManageOpenPositions();

   // 4. Do not open new if we already have an open position for this symbol
   if(PositionsTotal() > 0)
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(m_position.SelectByIndex(i))
           {
            if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber) return;
           }
        }
     }

   // 5. Signal Generation Core
   GenerateTradingSignals();
  }

//+------------------------------------------------------------------+
//| Function to calculate statistical Z-Score                        |
//+------------------------------------------------------------------+
double CalculateZScore()
  {
   double sma_arr[], stddev_arr[];
   ArraySetAsSeries(sma_arr, true);
   ArraySetAsSeries(stddev_arr, true);

   // Validación y copiado de buffers de los indicadores
   if(CopyBuffer(m_handle_sma, 0, 1, 1, sma_arr) <= 0) return 0.0;
   if(CopyBuffer(m_handle_stddev, 0, 1, 1, stddev_arr) <= 0) return 0.0;

   // Extracción precisa del precio de cierre utilizando el tipo nativo double
   double close_price;
   double timeseries[];
   ArraySetAsSeries(timeseries, true);
   
   if(CopyClose(_Symbol, PERIOD_M15, 1, 1, timeseries) <= 0) return 0.0;
   close_price = timeseries[0];

   // Protección contra división por cero en mercados planos
   if(stddev_arr[0] == 0) return 0.0; 
   
   // Fórmula de Arbitraje Estadístico: Z = (Price - Mean) / Standard Deviation
   return (close_price - sma_arr[0]) / stddev_arr[0];
  }
  
//+------------------------------------------------------------------+
//| Function to Generate Signals and Execute                         |
//+------------------------------------------------------------------+
void GenerateTradingSignals()
  {
   double adx_arr[], rsi_arr[], rsi_prev_arr[];
   ArraySetAsSeries(adx_arr, true);
   ArraySetAsSeries(rsi_arr, true);
   ArraySetAsSeries(rsi_prev_arr, true);

   if(CopyBuffer(m_handle_adx, 0, 1, 1, adx_arr) <= 0) return;
   if(CopyBuffer(m_handle_rsi, 0, 1, 1, rsi_arr) <= 0) return;       // Current closed bar
   if(CopyBuffer(m_handle_rsi, 0, 2, 1, rsi_prev_arr) <= 0) return;  // Previous closed bar

   // ADX Filter Check
   if(adx_arr[0] > InpADXLevel) return; // Market is trending, avoid mean reversion

   double z_score = CalculateZScore();
   
   // LONG SIGNAL LOGIC
   // Z-Score deeply negative AND RSI crossed up from extreme oversold (< 10)
   if(z_score < -InpZScoreThreshold && rsi_prev_arr[0] < 10.0 && rsi_arr[0] >= 10.0)
     {
      ExecuteTrade(ORDER_TYPE_BUY);
     }
     
   // SHORT SIGNAL LOGIC
   // Z-Score deeply positive AND RSI crossed down from extreme overbought (> 90)
   else if(z_score > InpZScoreThreshold && rsi_prev_arr[0] > 90.0 && rsi_arr[0] <= 90.0)
     {
      ExecuteTrade(ORDER_TYPE_SELL);
     }
  }

//+------------------------------------------------------------------+
//| Function to Calculate Dynamic Institutional Lot Size             |
//+------------------------------------------------------------------+
double CalculateDynamicLot(double sl_distance_points)
  {
   double account_balance = m_account.Balance();
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   if(tick_value == 0 || tick_size == 0 || sl_distance_points == 0) return 0.0;

   // Risk in base currency
   double risk_amount = account_balance * (InpRiskPercent / 100.0);
   
   // Value of 1 lot for the SL distance
   double loss_for_one_lot = sl_distance_points * (tick_value / tick_size) * m_point;
   
   if(loss_for_one_lot == 0) return 0.0; // Zero divide protection
   
   double lot_size = risk_amount / loss_for_one_lot;

   // Normalize lot size to broker limits
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot_size = MathRound(lot_size / step_lot) * step_lot;
   
   if(lot_size < min_lot) lot_size = min_lot; // Always allow minimum participation for testing
   if(lot_size > max_lot) lot_size = max_lot;

   return lot_size;
  }

//+------------------------------------------------------------------+
//| Trade Execution Engine                                           |
//+------------------------------------------------------------------+
void ExecuteTrade(ENUM_ORDER_TYPE type)
  {
   double atr_arr[];
   ArraySetAsSeries(atr_arr, true);
   if(CopyBuffer(m_handle_atr, 0, 1, 1, atr_arr) <= 0) return;

   m_symbol.RefreshRates();
   double price = (type == ORDER_TYPE_BUY) ? m_symbol.Ask() : m_symbol.Bid();
   
   // Dynamic Stop Loss based on volatility (ATR)
   double sl_distance = atr_arr[0] * InpATRMultiplierSL;
   double sl = 0.0, tp = 0.0;
   
   // Get SMA for Take Profit (Mean Reversion target)
   double sma_arr[];
   ArraySetAsSeries(sma_arr, true);
   CopyBuffer(m_handle_sma, 0, 1, 1, sma_arr);
   tp = sma_arr[0];

   if(type == ORDER_TYPE_BUY)
     {
      sl = price - sl_distance;
      if(tp <= price) tp = price + sl_distance; // Failsafe TP if SMA is distorted
     }
   else if(type == ORDER_TYPE_SELL)
     {
      sl = price + sl_distance;
      if(tp >= price) tp = price - sl_distance; // Failsafe TP
     }

   // Normalize prices
   sl = NormalizeDouble(sl, m_digits);
   tp = NormalizeDouble(tp, m_digits);

   // Get precise dynamic lot
   double sl_points = MathAbs(price - sl) / m_point;
   double volume = CalculateDynamicLot(sl_points);

   if(volume <= 0)
     {
      Print("Error: Volume calculation failed.");
      return;
     }

   // Send Institutional Order
   if(type == ORDER_TYPE_BUY)
     {
      if(!m_trade.Buy(volume, _Symbol, price, sl, tp, "NeurAlgo Buy"))
         Print("Buy Order Failed. Return Code: ", m_trade.ResultRetcode());
     }
   else
     {
      if(!m_trade.Sell(volume, _Symbol, price, sl, tp, "NeurAlgo Sell"))
         Print("Sell Order Failed. Return Code: ", m_trade.ResultRetcode());
     }
  }

//+------------------------------------------------------------------+
//| Time Session Gate Module (GMT Synchronized)                      |
//+------------------------------------------------------------------+
bool IsAsianSessionActive()
  {
   MqlDateTime gmt_time;
   TimeGMT(gmt_time); // Strictly pulls GMT ignoring PC or Server TZ
   
   int current_hour = gmt_time.hour;
   
   if(InpStartHourGMT > InpEndHourGMT) // Crosses midnight (e.g., 22:00 to 04:00)
     {
      if(current_hour >= InpStartHourGMT || current_hour < InpEndHourGMT) return true;
     }
   else // Same day
     {
      if(current_hour >= InpStartHourGMT && current_hour < InpEndHourGMT) return true;
     }
     
   return false;
  }

//+------------------------------------------------------------------+
//| Position Management Engine (Time Stop)                           |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   // If the Asian session is over, force close all positions to avoid European volatility
   if(!IsAsianSessionActive())
     {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(m_position.SelectByIndex(i))
           {
            if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
              {
               Print("Time Gate Closed. Forcing Institutional Market Close on: ", _Symbol);
               m_trade.PositionClose(m_position.Ticket());
              }
           }
        }
     }
  }
//+------------------------------------------------------------------+