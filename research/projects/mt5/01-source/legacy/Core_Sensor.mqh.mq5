//+------------------------------------------------------------------+
//|                                                  Core_Sensor.mqh |
//|                                      Apex-X Quantum Architecture |
//+------------------------------------------------------------------+
#ifndef CORE_SENSOR_MQH
#define CORE_SENSOR_MQH

#include "Core_Structs.mqh"

//+------------------------------------------------------------------+
//| Class: CSensorEngine                                             |
//| Purpose: Zero-lag trend estimator using TEMA + Kalman Filter     |
//+------------------------------------------------------------------+
class CSensorEngine
  {
private:
   // TEMA state variables
   double            m_ema1;
   double            m_ema2;
   double            m_ema3;
   double            m_alpha;
   
   // Kalman state variables
   double            m_kalman_x;
   double            m_kalman_p;
   double            m_kalman_q;
   double            m_kalman_r;
   
   // Tracking variables
   double            m_prev_kalman_x;
   bool              m_initialized;
   double            m_current_slope;

public:
                     CSensorEngine(int tema_period, double kalman_q, double kalman_r);
   void              InitializeState(double initial_price);
   void              ProcessTick(const MarketSnap &snap);
   double            GetSlope() const { return m_current_slope; }
   double            GetKalmanValue() const { return m_kalman_x; }
  };

//+------------------------------------------------------------------+
//| Constructor                                                      |
//+------------------------------------------------------------------+
CSensorEngine::CSensorEngine(int tema_period, double kalman_q, double kalman_r)
  {
   m_alpha = 2.0 / (tema_period + 1.0);
   m_ema1 = 0.0;
   m_ema2 = 0.0;
   m_ema3 = 0.0;
   m_kalman_x = 0.0;
   m_prev_kalman_x = 0.0;
   m_current_slope = 0.0;
   
   m_kalman_p = 1.0;
   m_kalman_q = kalman_q;
   m_kalman_r = kalman_r;
   m_initialized = false;
  }

//+------------------------------------------------------------------+
//| Initialize State                                                 |
//+------------------------------------------------------------------+
void CSensorEngine::InitializeState(double initial_price)
  {
   m_ema1 = initial_price;
   m_ema2 = initial_price;
   m_ema3 = initial_price;
   m_kalman_x = initial_price;
   m_prev_kalman_x = initial_price;
   m_kalman_p = 1.0;
   m_initialized = true;
  }

//+------------------------------------------------------------------+
//| Process Tick (Core Engine)                                       |
//+------------------------------------------------------------------+
void CSensorEngine::ProcessTick(const MarketSnap &snap)
  {
   double mid_price = (snap.ask + snap.bid) / 2.0;
   
   if(!m_initialized)
     {
      InitializeState(mid_price);
      return;
     }
     
   // Calculate TEMA recursively
   m_ema1 = m_alpha * mid_price + (1.0 - m_alpha) * m_ema1;
   m_ema2 = m_alpha * m_ema1 + (1.0 - m_alpha) * m_ema2;
   m_ema3 = m_alpha * m_ema2 + (1.0 - m_alpha) * m_ema3;
   double raw_tema = 3.0 * m_ema1 - 3.0 * m_ema2 + m_ema3;
   
   // Apply Discrete Kalman Filter
   double p_pred = m_kalman_p + m_kalman_q;
   double k = p_pred / (p_pred + m_kalman_r);
   
   m_kalman_x = m_kalman_x + k * (raw_tema - m_kalman_x);
   m_kalman_p = (1.0 - k) * p_pred;
   
   // Calculate Slope
   m_current_slope = m_kalman_x - m_prev_kalman_x;
   m_prev_kalman_x = m_kalman_x;
  }
#endif // CORE_SENSOR_MQH
//+------------------------------------------------------------------+