//+------------------------------------------------------------------+
//|                        NeurAlgo_EA.mq5                           |
//|           Proprietary Quantitative Trading Framework             |
//|      XAUUSD · Pepperstone Razor · MT5 Production Build v1.0      |
//+------------------------------------------------------------------+
//  Architecture:
//    CDataFeed       — OHLCV cache, ATR, spread, tick-value helpers
//    CQuantRegime    — Hurst Exponent R/S + TR Z-Score fallback
//    CAlphaEngine_MR — VWAP Z-Score mean reversion signals
//    CAlphaEngine_MOM— Donchian breakout + volume surge signals
//    CRiskModel      — Volatility-targeted sizing + kill switch
//    CExecution      — Async order routing + retcode telemetry
//+------------------------------------------------------------------+
#property copyright "NeurAlgo Framework"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//===================================================================
//  INPUT PARAMETERS
//===================================================================
input group "=== REGIME DETECTION ==="
input int    InpHurstWindow            = 100;  // Rolling window N for Hurst R/S
input int    InpTRSMAWindow            = 200;  // Window for TR Z-Score fallback

input group "=== MEAN REVERSION ENGINE ==="
input int    InpVWAPWindow             = 50;   // VWAP rolling window (bars)
input double InpMR_ZEntry              = 2.0;  // Z-Score threshold (|Z| > this)
input int    InpMR_StdDevPeriod        = 20;   // StdDev window for Z-Score

input group "=== MOMENTUM ENGINE ==="
input int    InpDonchianPeriod         = 20;   // Donchian channel period K
input int    InpVolMA_Period           = 20;   // Tick-volume SMA period
input double InpVolSurgeMult           = 1.5;  // Volume surge multiplier

input group "=== RISK MODEL ==="
input double InpTargetVolatilityPercent = 1.0; // Target equity risk % per trade
input double InpHardDrawdownLimit       = 5.0; // Drawdown % → Kill Switch
input int    InpMaxSpreadPoints         = 25;  // Max spread before aborting order
input int    InpATR_Period              = 14;  // ATR period for sizing & stops

input group "=== CHANDELIER EXIT ==="
input double InpChandelierMult_MOM     = 3.0;  // ATR mult — MOM trailing stop
input double InpChandelierMult_MR      = 1.5;  // ATR mult — MR initial SL

input group "=== EXECUTION ==="
input int    InpMaxSlippagePoints      = 10;   // Max slippage deviation (pts)
input ulong  InpMagicNumber            = 202401; // EA Magic Number


//===================================================================
//  CLASS: CDataFeed
//  Handles OHLCV caching, True Range computation, ATR, spread, and
//  tick-value calculations for downstream quant engines.
//===================================================================
class CDataFeed
{
private:
   string          m_symbol;
   ENUM_TIMEFRAMES m_tf;
   int             m_bars_required;
   int             m_bars_loaded;

   // Series arrays (index 0 = most recent COMPLETED bar)
   double   m_close[];
   double   m_high[];
   double   m_low[];
   double   m_open[];
   long     m_tick_volume[];
   double   m_true_range[];   // size = m_bars_loaded - 1

   double   m_point;
   double   m_tick_value;  // Dollar value per tick (1 lot)
   double   m_tick_size;   // Minimum price increment

public:
   CDataFeed() : m_bars_loaded(0), m_point(0), m_tick_value(0), m_tick_size(0) {}

   ~CDataFeed()
   {
      ArrayFree(m_close);  ArrayFree(m_high);       ArrayFree(m_low);
      ArrayFree(m_open);   ArrayFree(m_tick_volume); ArrayFree(m_true_range);
   }

   bool Init(const string symbol, const ENUM_TIMEFRAMES tf, const int bars_required)
   {
      m_symbol        = symbol;
      m_tf            = tf;
      m_bars_required = bars_required + 5; // safety buffer

      m_point      = SymbolInfoDouble(symbol, SYMBOL_POINT);
      m_tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
      m_tick_size  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);

      // All arrays are indexed as series: [0] = newest completed bar
      ArraySetAsSeries(m_close,       true);
      ArraySetAsSeries(m_high,        true);
      ArraySetAsSeries(m_low,         true);
      ArraySetAsSeries(m_open,        true);
      ArraySetAsSeries(m_tick_volume, true);

      return Refresh();
   }

   bool Refresh()
   {
      int copied = CopyClose (m_symbol, m_tf, 1, m_bars_required, m_close);
      // shift=1 so bar[0] is the last COMPLETED bar, not the forming bar
      if(copied < m_bars_required - 4) return false;

      CopyHigh      (m_symbol, m_tf, 1, m_bars_required, m_high);
      CopyLow       (m_symbol, m_tf, 1, m_bars_required, m_low);
      CopyOpen      (m_symbol, m_tf, 1, m_bars_required, m_open);
      CopyTickVolume(m_symbol, m_tf, 1, m_bars_required, m_tick_volume);

      // True Range: max(H-L, |H - C_prev|, |L - C_prev|)
      // Requires Close[i+1] = previous bar's close
      int tr_size = copied - 1;
      ArrayResize(m_true_range, tr_size);
      for(int i = 0; i < tr_size; i++)
      {
         double hl  = m_high[i]  - m_low[i];
         double hcp = MathAbs(m_high[i]  - m_close[i+1]);
         double lcp = MathAbs(m_low[i]   - m_close[i+1]);
         m_true_range[i] = MathMax(hl, MathMax(hcp, lcp));
      }
      m_bars_loaded = copied;
      return true;
   }

   // --- Accessors ---
   double Close    (int i) const { return (i < m_bars_loaded)             ? m_close[i]       : 0.0; }
   double High     (int i) const { return (i < m_bars_loaded)             ? m_high[i]        : 0.0; }
   double Low      (int i) const { return (i < m_bars_loaded)             ? m_low[i]         : 0.0; }
   double Open     (int i) const { return (i < m_bars_loaded)             ? m_open[i]        : 0.0; }
   long   TickVol  (int i) const { return (i < m_bars_loaded)             ? m_tick_volume[i] : 0;   }
   double TrueRange(int i) const { return (i < ArraySize(m_true_range))   ? m_true_range[i]  : 0.0; }

   int    BarsLoaded()  const { return m_bars_loaded; }
   double Point()       const { return m_point;       }
   double TickValue()   const { return m_tick_value;  }
   double TickSize()    const { return m_tick_size;   }
   string Symbol()      const { return m_symbol;      }

   // Live spread in points (ask - bid) / point
   double CurrentSpreadPoints() const
   {
      return (SymbolInfoDouble(m_symbol, SYMBOL_ASK) -
              SymbolInfoDouble(m_symbol, SYMBOL_BID)) / m_point;
   }

   // Wilder's Average True Range (simple mean over 'period' bars starting at 'shift')
   // Full Wilder smoothing requires long history; this simple-average approximation
   // is stable for walk-forward windows and avoids warm-up instability.
   double ATR(int period, int shift = 0) const
   {
      if(m_bars_loaded < period + shift + 1) return 0.0;
      double sum = 0.0;
      for(int i = shift; i < shift + period; i++)
         sum += TrueRange(i);
      return sum / period;
   }
};


//===================================================================
//  ENUM: Market Regime
//===================================================================
enum ENUM_REGIME { REGIME_UNDEFINED, REGIME_MEAN_REVERT, REGIME_MOMENTUM };


//===================================================================
//  CLASS: CQuantRegime
//
//  Primary: Hurst Exponent via R/S (Rescaled Range) Analysis
//  ─────────────────────────────────────────────────────────────────
//  Theory (Mandelbrot & Wallis 1969, Lo 1991):
//    Given a price series P[0..N-1], compute log-returns r[i]:
//      r[i] = ln(P[i] / P[i+1])              (newest-first indexing)
//    Mean of returns:   μ = (1/n) Σ r[i]
//    Cumulative deviation at step t:
//      Y[t] = Σ_{i=0}^{t} (r[i] - μ)
//    Range:            R = max(Y) - min(Y)
//    Std of returns:   S = sqrt((1/n) Σ (r[i]-μ)²)
//    Rescaled range:   RS = R / S
//    Hurst estimate:   H = log(RS) / log(n)
//
//    H < 0.5 → mean-reverting (negative autocorrelation)
//    H = 0.5 → random walk (no autocorrelation)
//    H > 0.5 → trending (positive autocorrelation)
//
//  Fallback: TR Z-Score
//  ─────────────────────────────────────────────────────────────────
//    Z = (TR_current - μ_TR) / σ_TR  over a rolling window
//    High Z → volatility expansion  → trending bias
//    Low  Z → volatility compression → mean-reverting bias
//===================================================================
class CQuantRegime
{
private:
   int          m_hurst_window;
   int          m_tr_sma_window;
   ENUM_REGIME  m_current_regime;
   double       m_last_hurst;
   double       m_last_tr_zscore;

   double ComputeHurst(const CDataFeed* feed)
   {
      int N = m_hurst_window;
      // Need N+1 bars to form N log-returns
      if(feed.BarsLoaded() < N + 2) return 0.5;

      int n = N; // number of returns
      double returns[];
      ArrayResize(returns, n);

      // Compute log-returns from confirmed bars [0..N]
      for(int i = 0; i < n; i++)
      {
         double p_new = feed.Close(i);
         double p_old = feed.Close(i + 1);
         if(p_old <= 1e-10) return 0.5;
         returns[i] = MathLog(p_new / p_old);
      }

      // Mean of returns
      double mu = 0.0;
      for(int i = 0; i < n; i++) mu += returns[i];
      mu /= n;

      // Cumulative deviation — track running max and min
      double cum = 0.0, R_max = -DBL_MAX, R_min = DBL_MAX;
      for(int i = 0; i < n; i++)
      {
         cum += (returns[i] - mu);
         if(cum > R_max) R_max = cum;
         if(cum < R_min) R_min = cum;
      }
      double R = R_max - R_min;

      // Standard deviation of returns
      double var = 0.0;
      for(int i = 0; i < n; i++) var += MathPow(returns[i] - mu, 2.0);
      var /= n;
      double S = MathSqrt(var);

      ArrayFree(returns);

      if(S < 1e-12 || R < 1e-12) return 0.5;

      double H = MathLog(R / S) / MathLog((double)n);
      return MathMin(MathMax(H, 0.0), 1.0); // clamp to [0, 1]
   }

   double ComputeTR_ZScore(const CDataFeed* feed)
   {
      int window = MathMin(m_tr_sma_window, feed.BarsLoaded() - 2);
      if(window < 10) return 0.0;

      double sum = 0.0, sum_sq = 0.0;
      for(int i = 0; i < window; i++)
      {
         double tr = feed.TrueRange(i);
         sum    += tr;
         sum_sq += tr * tr;
      }
      double mean = sum / window;
      double var  = (sum_sq / window) - (mean * mean);
      double stdev = (var > 0.0) ? MathSqrt(var) : 1e-12;

      // Current TR is bar[0] (most recent completed bar)
      return (feed.TrueRange(0) - mean) / stdev;
   }

public:
   CQuantRegime() : m_current_regime(REGIME_UNDEFINED),
                    m_last_hurst(0.5), m_last_tr_zscore(0.0) {}

   void Init(int hurst_window, int tr_sma_window)
   {
      m_hurst_window  = hurst_window;
      m_tr_sma_window = tr_sma_window;
   }

   ENUM_REGIME Classify(const CDataFeed* feed)
   {
      m_last_hurst     = ComputeHurst(feed);
      m_last_tr_zscore = ComputeTR_ZScore(feed);

      // Primary classifier: Hurst
      // Neutral band [0.45, 0.55] resolved by TR Z-Score tiebreaker
      if     (m_last_hurst < 0.45) m_current_regime = REGIME_MEAN_REVERT;
      else if(m_last_hurst > 0.55) m_current_regime = REGIME_MOMENTUM;
      else
         m_current_regime = (m_last_tr_zscore > 1.0) ? REGIME_MOMENTUM
                                                      : REGIME_MEAN_REVERT;
      return m_current_regime;
   }

   ENUM_REGIME CurrentRegime()  const { return m_current_regime;  }
   double      LastHurst()      const { return m_last_hurst;      }
   double      LastTRZScore()   const { return m_last_tr_zscore;  }
};


//===================================================================
//  ENUM: Signal Direction
//===================================================================
enum ENUM_SIGNAL { SIGNAL_NONE, SIGNAL_LONG, SIGNAL_SHORT };


//===================================================================
//  CLASS: CAlphaEngine_MR  (Statistical Mean Reversion)
//
//  Volume-Weighted Average Price (VWAP):
//    TP[i]   = (High[i] + Low[i] + Close[i]) / 3    [typical price]
//    VWAP    = Σ(TP[i] × Vol[i]) / Σ(Vol[i])        over window W
//
//  Z-Score of price relative to VWAP:
//    σ       = StdDev(Close, n)                      [price dispersion]
//    Z       = (Close - VWAP) / σ
//
//  Entry logic:
//    Z < -threshold → price statistically below fair value → LONG
//    Z >  threshold → price statistically above fair value → SHORT
//
//  Exit: price mean-reverts to VWAP (Close crosses VWAP)
//===================================================================
class CAlphaEngine_MR
{
private:
   int    m_vwap_window;
   int    m_stddev_period;
   double m_z_threshold;
   double m_last_vwap;
   double m_last_zscore;

   double CalcVWAP(const CDataFeed* feed) const
   {
      double sum_pv = 0.0, sum_v = 0.0;
      for(int i = 0; i < m_vwap_window; i++)
      {
         double tp  = (feed.High(i) + feed.Low(i) + feed.Close(i)) / 3.0;
         double vol = (double)feed.TickVol(i);
         sum_pv += tp * vol;
         sum_v  += vol;
      }
      return (sum_v > 0.0) ? sum_pv / sum_v : feed.Close(0);
   }

   double CalcStdDev(const CDataFeed* feed) const
   {
      double sum = 0.0, sum_sq = 0.0;
      for(int i = 0; i < m_stddev_period; i++)
      {
         double c = feed.Close(i);
         sum    += c;
         sum_sq += c * c;
      }
      double mean = sum / m_stddev_period;
      double var  = (sum_sq / m_stddev_period) - (mean * mean);
      return (var > 0.0) ? MathSqrt(var) : 1e-10;
   }

public:
   CAlphaEngine_MR() : m_last_vwap(0.0), m_last_zscore(0.0) {}

   void Init(int vwap_window, int stddev_period, double z_threshold)
   {
      m_vwap_window   = vwap_window;
      m_stddev_period = stddev_period;
      m_z_threshold   = z_threshold;
   }

   ENUM_SIGNAL Generate(const CDataFeed* feed)
   {
      int need = MathMax(m_vwap_window, m_stddev_period) + 2;
      if(feed.BarsLoaded() < need) return SIGNAL_NONE;

      m_last_vwap   = CalcVWAP(feed);
      double stdev  = CalcStdDev(feed);
      m_last_zscore = (feed.Close(0) - m_last_vwap) / stdev;

      if(m_last_zscore < -m_z_threshold) return SIGNAL_LONG;
      if(m_last_zscore >  m_z_threshold) return SIGNAL_SHORT;
      return SIGNAL_NONE;
   }

   // Exit condition: price has returned to VWAP (mean touch)
   bool ExitLong (const CDataFeed* feed) const { return feed.Close(0) >= m_last_vwap; }
   bool ExitShort(const CDataFeed* feed) const { return feed.Close(0) <= m_last_vwap; }

   double LastVWAP()   const { return m_last_vwap;   }
   double LastZScore() const { return m_last_zscore; }
};


//===================================================================
//  CLASS: CAlphaEngine_MOM  (Volatility Breakout + Volume Surge)
//
//  Donchian Channel (liquidity void detection):
//    DonchianHigh = max(High[1..K])    [prior K confirmed bars]
//    DonchianLow  = min(Low[1..K])
//
//  Volume surge validation (order flow proxy):
//    VolMA  = SMA(TickVol, 20)
//    Surge  = TickVol[0] > VolSurgeMult × VolMA
//
//  Breakout entry (no-repaint: signal on confirmed bar):
//    Close[0] broke above prior DonchianHigh AND Surge → LONG
//    Close[0] broke below prior DonchianLow  AND Surge → SHORT
//
//  ATR-Chandelier trailing stop:
//    StopLong  = HighestHigh - N × ATR   (trails upward)
//    StopShort = LowestLow   + N × ATR   (trails downward)
//===================================================================
class CAlphaEngine_MOM
{
private:
   int    m_donchian_period;
   int    m_vol_ma_period;
   double m_vol_surge_mult;

   double m_last_dcn_high;
   double m_last_dcn_low;
   double m_last_vol_ma;

   double m_highest_high;   // Running max for chandelier (long)
   double m_lowest_low;     // Running min for chandelier (short)

public:
   CAlphaEngine_MOM() : m_last_dcn_high(0), m_last_dcn_low(0),
                         m_last_vol_ma(0), m_highest_high(0), m_lowest_low(DBL_MAX) {}

   void Init(int donchian_period, int vol_ma_period, double vol_surge_mult)
   {
      m_donchian_period = donchian_period;
      m_vol_ma_period   = vol_ma_period;
      m_vol_surge_mult  = vol_surge_mult;
   }

   ENUM_SIGNAL Generate(const CDataFeed* feed)
   {
      int need = m_donchian_period + m_vol_ma_period + 3;
      if(feed.BarsLoaded() < need) return SIGNAL_NONE;

      // Prior Donchian: bars [1..K] — exclude bar[0] to avoid self-inclusion
      double prior_high = feed.High(1), prior_low = feed.Low(1);
      for(int i = 1; i <= m_donchian_period; i++)
      {
         if(feed.High(i) > prior_high) prior_high = feed.High(i);
         if(feed.Low(i)  < prior_low)  prior_low  = feed.Low(i);
      }
      m_last_dcn_high = prior_high;
      m_last_dcn_low  = prior_low;

      // Volume MA over bars [1..VolMA_Period]
      double vol_sum = 0.0;
      for(int i = 1; i <= m_vol_ma_period; i++)
         vol_sum += (double)feed.TickVol(i);
      m_last_vol_ma = vol_sum / m_vol_ma_period;

      // Bar[0]: the just-completed breakout bar
      long   cur_vol   = feed.TickVol(0);
      double cur_close = feed.Close(0);
      bool   surge     = (cur_vol > m_last_vol_ma * m_vol_surge_mult);

      if(cur_close > prior_high && surge)
      {
         m_highest_high = cur_close; // seed chandelier
         return SIGNAL_LONG;
      }
      if(cur_close < prior_low && surge)
      {
         m_lowest_low = cur_close;   // seed chandelier
         return SIGNAL_SHORT;
      }
      return SIGNAL_NONE;
   }

   // Called on each bar to advance the trailing stop anchor
   void UpdateTrailing(const CDataFeed* feed, ENUM_SIGNAL dir)
   {
      if(dir == SIGNAL_LONG  && feed.High(0) > m_highest_high) m_highest_high = feed.High(0);
      if(dir == SIGNAL_SHORT && feed.Low(0)  < m_lowest_low)   m_lowest_low   = feed.Low(0);
   }

   double ChandelierStopLong (double atr, double mult) const { return m_highest_high - mult * atr; }
   double ChandelierStopShort(double atr, double mult) const { return m_lowest_low   + mult * atr; }

   void SetHighestHigh(double v) { m_highest_high = v; }
   void SetLowestLow  (double v) { m_lowest_low   = v; }

   double LastDCNHigh() const { return m_last_dcn_high; }
   double LastDCNLow()  const { return m_last_dcn_low;  }
   double LastVolMA()   const { return m_last_vol_ma;   }
};


//===================================================================
//  CLASS: CRiskModel
//
//  Volatility-Targeted Lot Sizing:
//  ─────────────────────────────────────────────────────────────────
//    DollarRisk       = Equity × (TargetVolPct / 100)
//    PointValue       = TickValue / TickSize   [$ per point, per lot]
//    ATR_dollar_1lot  = ATR × PointValue
//    RawLot           = DollarRisk / ATR_dollar_1lot
//    Lot              = floor(RawLot / LotStep) × LotStep
//                       clamped to [MinLot, MaxLot]
//
//  Kill Switch:
//    Tracks peak equity; if drawdown% ≥ HardDrawdownLimit,
//    sets m_kill_switch=true, preventing all future orders.
//===================================================================
class CRiskModel
{
private:
   double m_target_vol_pct;
   double m_hard_dd_limit;
   double m_peak_equity;
   bool   m_kill_switch;

   double m_min_lot;
   double m_max_lot;
   double m_lot_step;

public:
   CRiskModel() : m_peak_equity(0), m_kill_switch(false),
                  m_min_lot(0.01), m_max_lot(100), m_lot_step(0.01) {}

   void Init(double target_vol_pct, double hard_dd_limit)
   {
      m_target_vol_pct = target_vol_pct;
      m_hard_dd_limit  = hard_dd_limit;
      m_peak_equity    = AccountInfoDouble(ACCOUNT_EQUITY);
      m_min_lot        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      m_max_lot        = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
      m_lot_step       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   }

   // Returns true if kill switch is (or becomes) active
   bool CheckDrawdown()
   {
      if(m_kill_switch) return true;
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peak_equity) m_peak_equity = equity;
      double dd_pct = (m_peak_equity - equity) / m_peak_equity * 100.0;
      if(dd_pct >= m_hard_dd_limit)
      {
         m_kill_switch = true;
         PrintFormat("[KILL SWITCH] Drawdown %.2f%% ≥ limit %.2f%% — EA HALTED.",
                     dd_pct, m_hard_dd_limit);
      }
      return m_kill_switch;
   }

   double ComputeLotSize(const CDataFeed* feed, int atr_period) const
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double atr    = feed.ATR(atr_period, 0);
      if(atr <= 0.0) return m_min_lot;

      // Dollar value of 1 point of price movement for 1 lot
      double point_val = feed.TickValue() / feed.TickSize(); // $/point/lot

      double dollar_risk      = equity * (m_target_vol_pct / 100.0);
      double atr_dollar_1lot  = atr * point_val;
      if(atr_dollar_1lot <= 0.0) return m_min_lot;

      double raw_lot = dollar_risk / atr_dollar_1lot;

      // Quantize to broker lot step
      double lot = MathFloor(raw_lot / m_lot_step) * m_lot_step;
      return MathMax(m_min_lot, MathMin(m_max_lot, lot));
   }

   bool   KillSwitch()  const { return m_kill_switch;  }
   double PeakEquity()  const { return m_peak_equity;  }
};


//===================================================================
//  CLASS: CExecution
//  Asynchronous order routing with exhaustive TRADE_RETCODE handling,
//  spread gate, slippage measurement, and deep telemetry logging.
//===================================================================
class CExecution
{
private:
   CTrade      m_trade;
   CSymbolInfo m_sym;
   ulong       m_magic;
   int         m_max_slip_pts;
   int         m_max_spread_pts;
   double      m_point;

   bool        m_pending_async;   // True while async fill is unconfirmed
   ulong       m_last_req_id;
   datetime    m_order_sent_time;

public:
   CExecution() : m_pending_async(false), m_last_req_id(0), m_order_sent_time(0) {}

   bool Init(const string symbol, ulong magic, int max_slip_pts, int max_spread_pts)
   {
      m_magic          = magic;
      m_max_slip_pts   = max_slip_pts;
      m_max_spread_pts = max_spread_pts;
      m_point          = SymbolInfoDouble(symbol, SYMBOL_POINT);

      m_trade.SetExpertMagicNumber(magic);
      m_trade.SetDeviationInPoints(max_slip_pts);
      m_trade.SetAsyncMode(true); // Async: OrderSendAsync path

      if(!m_sym.Name(symbol)) { Print("[EXEC INIT] Symbol load failed."); return false; }
      m_sym.RefreshRates();
      return true;
   }

   // Spread gate — must clear before any order attempt
   bool SpreadOK() const
   {
      // Refresh inline to get live bid/ask
      double ask = SymbolInfoDouble(m_sym.Name(), SYMBOL_ASK);
      double bid = SymbolInfoDouble(m_sym.Name(), SYMBOL_BID);
      double sp  = (ask - bid) / m_point;
      if(sp > m_max_spread_pts)
      {
         PrintFormat("[EXEC] SPREAD BLOCKED: %.1f pts > limit %d pts", sp, m_max_spread_pts);
         return false;
      }
      return true;
   }

   bool OpenPosition(ENUM_ORDER_TYPE type, double lots,
                     double sl, double tp, const string comment = "")
   {
      if(!SpreadOK()) return false;

      m_sym.RefreshRates();
      double price = (type == ORDER_TYPE_BUY) ? m_sym.Ask() : m_sym.Bid();
      m_order_sent_time = TimeCurrent();

      bool ok = (type == ORDER_TYPE_BUY)
                ? m_trade.Buy (lots, m_sym.Name(), price, sl, tp, comment)
                : m_trade.Sell(lots, m_sym.Name(), price, sl, tp, comment);

      if(ok)
      {
         m_last_req_id = m_trade.ResultOrder();
         m_pending_async = true;
         PrintFormat("[EXEC] ORDER SENT | %s %.2f @ %.5f | SL:%.5f TP:%.5f | ReqID:%I64u",
                     (type==ORDER_TYPE_BUY)?"BUY":"SELL", lots, price, sl, tp, m_last_req_id);
      }
      else LogRetcode(m_trade.ResultRetcode());

      return ok;
   }

   bool CloseAll(const string symbol)
   {
      bool ok = true;
      for(int i = PositionsTotal()-1; i >= 0; i--)
      {
         ulong tkt = PositionGetTicket(i);
         if(!PositionSelectByTicket(tkt)) continue;
         if(PositionGetString(POSITION_SYMBOL)  != symbol)          continue;
         if(PositionGetInteger(POSITION_MAGIC)  != (long)m_magic)   continue;
         if(!m_trade.PositionClose(tkt)) { LogRetcode(m_trade.ResultRetcode()); ok=false; }
      }
      return ok;
   }

   bool ModifySL(ulong ticket, double new_sl)
   {
      if(!PositionSelectByTicket(ticket)) return false;
      double tp = PositionGetDouble(POSITION_TP);
      return m_trade.PositionModify(ticket, new_sl, tp);
   }

   // Exhaustive TRADE_RETCODE decoder — covers all documented MT5 codes
   void LogRetcode(uint rc)
   {
      string s;
      switch(rc)
      {
         case TRADE_RETCODE_REQUOTE:            s="REQUOTE";             break;
         case TRADE_RETCODE_REJECT:             s="REJECT";              break;
         case TRADE_RETCODE_CANCEL:             s="CANCEL";              break;
         case TRADE_RETCODE_PLACED:             s="PLACED(ASYNC OK)";    break;
         case TRADE_RETCODE_DONE:               s="DONE";                break;
         case TRADE_RETCODE_DONE_PARTIAL:       s="DONE_PARTIAL";        break;
         case TRADE_RETCODE_ERROR:              s="ERROR";               break;
         case TRADE_RETCODE_TIMEOUT:            s="TIMEOUT";             break;
         case TRADE_RETCODE_INVALID:            s="INVALID";             break;
         case TRADE_RETCODE_INVALID_VOLUME:     s="INVALID_VOLUME";      break;
         case TRADE_RETCODE_INVALID_PRICE:      s="INVALID_PRICE";       break;
         case TRADE_RETCODE_INVALID_STOPS:      s="INVALID_STOPS";       break;
         case TRADE_RETCODE_TRADE_DISABLED:     s="TRADE_DISABLED";      break;
         case TRADE_RETCODE_MARKET_CLOSED:      s="MARKET_CLOSED";       break;
         case TRADE_RETCODE_NO_MONEY:           s="NO_MONEY";            break;
         case TRADE_RETCODE_PRICE_CHANGED:      s="PRICE_CHANGED";       break;
         case TRADE_RETCODE_PRICE_OFF:          s="PRICE_OFF";           break;
         case TRADE_RETCODE_INVALID_EXPIRATION: s="INVALID_EXPIRATION";  break;
         case TRADE_RETCODE_ORDER_CHANGED:      s="ORDER_CHANGED";       break;
         case TRADE_RETCODE_TOO_MANY_REQUESTS:  s="TOO_MANY_REQUESTS";   break;
         case TRADE_RETCODE_NO_CHANGES:         s="NO_CHANGES";          break;
         case TRADE_RETCODE_SERVER_DISABLES_AT: s="SERVER_DISABLES_AT";  break;
         case TRADE_RETCODE_CLIENT_DISABLES_AT: s="CLIENT_DISABLES_AT";  break;
         case TRADE_RETCODE_LOCKED:             s="LOCKED";              break;
         case TRADE_RETCODE_FROZEN:             s="FROZEN";              break;
         case TRADE_RETCODE_INVALID_FILL:       s="INVALID_FILL";        break;
         case TRADE_RETCODE_CONNECTION:         s="CONNECTION";          break;
         case TRADE_RETCODE_ONLY_REAL:          s="ONLY_REAL";           break;
         case TRADE_RETCODE_LIMIT_ORDERS:       s="LIMIT_ORDERS";        break;
         case TRADE_RETCODE_LIMIT_VOLUME:       s="LIMIT_VOLUME";        break;
         default: s="UNKNOWN(" + IntegerToString(rc) + ")"; break;
      }
      PrintFormat("[EXEC] RetCode: %s (%u)", s, rc);
   }

   // Called from OnTradeTransaction — confirms fills, logs latency & slippage
   void OnTransaction(const MqlTradeTransaction& trans,
                      const MqlTradeRequest&     request,
                      const MqlTradeResult&      result)
   {
      if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      {
         long latency = (long)(TimeCurrent() - m_order_sent_time);
         double slip_pts = 0.0;
         if(request.price > 0.0 && result.price > 0.0)
            slip_pts = MathAbs(result.price - request.price) / m_point;

         PrintFormat("[FILL] Deal:%I64u | ExecPx:%.5f | ReqPx:%.5f | "
                     "Slip:%.1f pts | Latency:~%I64ds | Vol:%.2f",
                     trans.deal, result.price, request.price,
                     slip_pts, latency, result.volume);

         m_pending_async = false;
      }

      if(trans.type == TRADE_TRANSACTION_ORDER_DELETE)
         PrintFormat("[TRANS] Order %I64u removed (fill/cancel).", trans.order);
   }

   bool  HasPendingAsync() const { return m_pending_async; }
   ulong Magic()           const { return m_magic;         }
};


//===================================================================
//  GLOBAL STATE
//===================================================================
CDataFeed*       g_feed      = NULL;
CQuantRegime*    g_regime    = NULL;
CAlphaEngine_MR* g_alpha_mr  = NULL;
CAlphaEngine_MOM*g_alpha_mom = NULL;
CRiskModel*      g_risk      = NULL;
CExecution*      g_exec      = NULL;

enum ENUM_TRADE_DIR { DIR_NONE, DIR_LONG, DIR_SHORT };

ENUM_TRADE_DIR  g_dir        = DIR_NONE;
ulong           g_ticket     = 0;
ENUM_REGIME     g_trade_regime = REGIME_UNDEFINED; // regime active at entry


//===================================================================
//  OnInit
//===================================================================
int OnInit()
{
   // Maximum bars required across all quantitative windows
   int bars = MathMax(InpHurstWindow + 5,
              MathMax(InpTRSMAWindow,
              MathMax(InpVWAPWindow + InpMR_StdDevPeriod,
                      InpDonchianPeriod + InpVolMA_Period + 5)));

   g_feed      = new CDataFeed();
   g_regime    = new CQuantRegime();
   g_alpha_mr  = new CAlphaEngine_MR();
   g_alpha_mom = new CAlphaEngine_MOM();
   g_risk      = new CRiskModel();
   g_exec      = new CExecution();

   if(!g_feed.Init(_Symbol, PERIOD_H1, bars))
   { Print("[INIT] DataFeed failed."); return INIT_FAILED; }

   g_regime.Init   (InpHurstWindow, InpTRSMAWindow);
   g_alpha_mr.Init (InpVWAPWindow, InpMR_StdDevPeriod, InpMR_ZEntry);
   g_alpha_mom.Init(InpDonchianPeriod, InpVolMA_Period, InpVolSurgeMult);
   g_risk.Init     (InpTargetVolatilityPercent, InpHardDrawdownLimit);

   if(!g_exec.Init(_Symbol, InpMagicNumber, InpMaxSlippagePoints, InpMaxSpreadPoints))
   { Print("[INIT] Execution engine failed."); return INIT_FAILED; }

   PrintFormat("[INIT] NeurAlgo EA online | %s | Magic:%I64u | BarsNeeded:%d",
               _Symbol, InpMagicNumber, bars);
   return INIT_SUCCEEDED;
}


//===================================================================
//  OnDeinit — deterministic heap cleanup (no leaks)
//===================================================================
void OnDeinit(const int reason)
{
   if(g_feed)     { delete g_feed;      g_feed     = NULL; }
   if(g_regime)   { delete g_regime;    g_regime   = NULL; }
   if(g_alpha_mr) { delete g_alpha_mr;  g_alpha_mr = NULL; }
   if(g_alpha_mom){ delete g_alpha_mom; g_alpha_mom= NULL; }
   if(g_risk)     { delete g_risk;      g_risk     = NULL; }
   if(g_exec)     { delete g_exec;      g_exec     = NULL; }
   PrintFormat("[DEINIT] NeurAlgo EA offline. Reason:%d", reason);
}


//===================================================================
//  Helper: scan positions for this EA's active ticket
//===================================================================
ulong FindActiveTicket(ENUM_TRADE_DIR& dir_out)
{
   dir_out = DIR_NONE;
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong tkt = PositionGetTicket(i);
      if(!PositionSelectByTicket(tkt)) continue;
      if(PositionGetString (POSITION_SYMBOL) != _Symbol)         continue;
      if(PositionGetInteger(POSITION_MAGIC)  != (long)InpMagicNumber) continue;
      dir_out = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                ? DIR_LONG : DIR_SHORT;
      return tkt;
   }
   return 0;
}


//===================================================================
//  OnTick — master event loop
//===================================================================
void OnTick()
{
   // ── 1. Refresh data cache ──────────────────────────────────────
   if(!g_feed.Refresh()) return;

   // ── 2. Kill Switch Guard ───────────────────────────────────────
   if(g_risk.CheckDrawdown())
   {
      // If positions remain open, close them on kill
      if(PositionsTotal() > 0) g_exec.CloseAll(_Symbol);
      return;
   }

   // ── 3. Bar-close gate: execute logic only on new confirmed bar ─
   static datetime s_last_bar = 0;
   datetime bar_time = (datetime)SeriesInfoInteger(_Symbol, PERIOD_H1,
                                                   SERIES_LASTBAR_DATE);
   if(bar_time == s_last_bar) return;
   s_last_bar = bar_time;

   // ── 4. Async gate: wait for pending fill confirmation ──────────
   if(g_exec.HasPendingAsync()) return;

   // ── 5. Synchronize active position state from broker ──────────
   g_ticket = FindActiveTicket(g_dir);

   // ── 6. ATR (used by both exit and entry) ──────────────────────
   double atr = g_feed.ATR(InpATR_Period, 0);
   if(atr <= 0.0) return;

   // ──────────────────────────────────────────────────────────────
   //  EXIT BLOCK (evaluated before entry to stay flat-first)
   // ──────────────────────────────────────────────────────────────
   if(g_ticket != 0)
   {
      bool close_now = false;

      if(g_trade_regime == REGIME_MEAN_REVERT)
      {
         // MR exit: price has mean-reverted to VWAP
         g_alpha_mr.Generate(g_feed); // refresh VWAP
         if(g_dir == DIR_LONG  && g_alpha_mr.ExitLong (g_feed)) close_now = true;
         if(g_dir == DIR_SHORT && g_alpha_mr.ExitShort(g_feed)) close_now = true;
      }
      else if(g_trade_regime == REGIME_MOMENTUM)
      {
         // MOM exit: ATR-Chandelier trailing stop
         ENUM_SIGNAL trail_dir = (g_dir == DIR_LONG) ? SIGNAL_LONG : SIGNAL_SHORT;
         g_alpha_mom.UpdateTrailing(g_feed, trail_dir);

         if(PositionSelectByTicket(g_ticket))
         {
            double cur_sl = PositionGetDouble(POSITION_SL);

            if(g_dir == DIR_LONG)
            {
               double new_sl = g_alpha_mom.ChandelierStopLong(atr, InpChandelierMult_MOM);
               // Trail up: only raise SL, never lower
               if(new_sl > cur_sl + g_feed.Point())
               {
                  g_exec.ModifySL(g_ticket, new_sl);
                  PrintFormat("[TRAIL] Long SL raised to %.5f", new_sl);
               }
               if(g_feed.Close(0) <= new_sl) close_now = true;
            }
            else // DIR_SHORT
            {
               double new_sl = g_alpha_mom.ChandelierStopShort(atr, InpChandelierMult_MOM);
               // Trail down: only lower SL, never raise
               if(cur_sl == 0.0 || new_sl < cur_sl - g_feed.Point())
               {
                  g_exec.ModifySL(g_ticket, new_sl);
                  PrintFormat("[TRAIL] Short SL lowered to %.5f", new_sl);
               }
               if(g_feed.Close(0) >= new_sl) close_now = true;
            }
         }
      }

      if(close_now)
      {
         PrintFormat("[EXIT] Closing %s | Ticket:%I64u | Regime:%s",
                     (g_dir==DIR_LONG)?"LONG":"SHORT", g_ticket,
                     (g_trade_regime==REGIME_MEAN_REVERT)?"MR":"MOM");
         g_exec.CloseAll(_Symbol);
         g_ticket      = 0;
         g_dir         = DIR_NONE;
         g_trade_regime= REGIME_UNDEFINED;
         return;
      }
   }

   // ──────────────────────────────────────────────────────────────
   //  ENTRY BLOCK (only when flat)
   // ──────────────────────────────────────────────────────────────
   if(g_ticket != 0) return; // still in a trade — no new entry

   // 8a. Classify current market regime
   ENUM_REGIME regime = g_regime.Classify(g_feed);

   // 8b. Generate directional signal from the active alpha engine
   ENUM_SIGNAL sig = SIGNAL_NONE;
   if     (regime == REGIME_MEAN_REVERT) sig = g_alpha_mr.Generate (g_feed);
   else if(regime == REGIME_MOMENTUM)   sig = g_alpha_mom.Generate(g_feed);
   if(sig == SIGNAL_NONE) return;

   // 8c. Compute volatility-adjusted lot size
   double lots = g_risk.ComputeLotSize(g_feed, InpATR_Period);

   // 8d. Compute initial SL / TP
   double price  = (sig == SIGNAL_LONG) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                        : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0, tp = 0.0;

   if(regime == REGIME_MEAN_REVERT)
   {
      // Fixed ATR stop + VWAP target
      double vwap = g_alpha_mr.LastVWAP();
      sl = (sig == SIGNAL_LONG) ? price - InpChandelierMult_MR * atr
                                : price + InpChandelierMult_MR * atr;
      tp = vwap; // exit at mean
   }
   else // MOMENTUM
   {
      // Seed chandelier; trailing stop replaces static TP
      if(sig == SIGNAL_LONG)
      {
         g_alpha_mom.SetHighestHigh(g_feed.High(0));
         sl = g_alpha_mom.ChandelierStopLong(atr, InpChandelierMult_MOM);
      }
      else
      {
         g_alpha_mom.SetLowestLow(g_feed.Low(0));
         sl = g_alpha_mom.ChandelierStopShort(atr, InpChandelierMult_MOM);
      }
      tp = 0.0; // No fixed TP — chandelier manages the exit
   }

   // 8e. Deep telemetry print before order submission
   PrintFormat("[SIGNAL] Regime:%s | H:%.4f | TRZ:%.4f | Dir:%s | "
               "VWAP_Z:%.4f | Lots:%.2f | Price:%.5f | SL:%.5f | TP:%.5f | ATR:%.5f",
               (regime==REGIME_MEAN_REVERT)?"MR":"MOM",
               g_regime.LastHurst(), g_regime.LastTRZScore(),
               (sig==SIGNAL_LONG)?"LONG":"SHORT",
               g_alpha_mr.LastZScore(), lots, price, sl, tp, atr);

   // 8f. Route the order
   ENUM_ORDER_TYPE otype = (sig == SIGNAL_LONG) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   string comment = StringFormat("NA_%s_%s",
                      (regime==REGIME_MEAN_REVERT)?"MR":"MOM",
                      (sig==SIGNAL_LONG)?"L":"S");

   if(g_exec.OpenPosition(otype, lots, sl, tp, comment))
      g_trade_regime = regime; // record entry regime for exit logic
}


//===================================================================
//  OnTradeTransaction — async fill confirmation & telemetry
//===================================================================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     request,
                        const MqlTradeResult&      result)
{
   if(g_exec == NULL) return;
   g_exec.OnTransaction(trans, request, result);

   // Re-sync active ticket after a confirmed deal
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ENUM_TRADE_DIR d;
      g_ticket = FindActiveTicket(d);
      g_dir    = d;
      PrintFormat("[TRANS] Position synced | Ticket:%I64u | Dir:%s",
                  g_ticket, (d==DIR_LONG)?"LONG":(d==DIR_SHORT)?"SHORT":"NONE");
   }
}
//+------------------------------------------------------------------+
//  END OF FILE: NeurAlgo_EA.mq5
//+------------------------------------------------------------------+