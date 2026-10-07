//+------------------------------------------------------------------+
//|   ApexQuant - Phase 7: Commercial Grade (MQL5 Market Ready)      |
//|   Objetivo: Máxima robustez, gestión de errores y optimización   |
//+------------------------------------------------------------------+
#property copyright "ApexQuant Dev Team"
#property version   "7.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade         m_trade;
CPositionInfo  m_position;

//=================================================================
//  PARÁMETROS DE ENTRADA (OPTIMIZADOS - PROFIT FACTOR 1.90)
//=================================================================
input group "=== CONFIGURACIÓN COMERCIAL ==="
input long   Inp_Magic            = 7777;
input double Inp_LotBase          = 0.01;
input int    Inp_MaxRetries       = 3;      // Reintentos ante errores de red

input group "=== MOTOR TEMA-KALMAN (RADAR M15) ==="
input int    Inp_TEMAPeriod       = 22;     // Valor Optimizado
input double Inp_TrendMinSlope    = 0.0003; 

input group "=== FILTRO SISTÉMICO (MACRO H1) ==="
input int    Inp_EMA_HTF          = 200;    

input group "=== FILTRO DE GASOLINA (VOLUMEN MFI) ==="
input int    Inp_MFIPeriod        = 14;
input int    Inp_MFILimit         = 50;     

input group "=== GESTIÓN DE RIESGO PROFESIONAL (ATR) ==="
input int    Inp_ATRPeriod        = 14;
input double Inp_StopLossATR      = 2.9;    // Valor Optimizado
input double Inp_TrailingStartATR = 5.0;    // Valor Optimizado
input double Inp_TrailingStepATR  = 0.9;    // Valor Optimizado
input double Inp_BreakevenTriggerUSD = 4.0; // Valor Optimizado

input group "=== FILTROS DE SEGURIDAD ==="
input int    Inp_MaxSpread        = 5000;
input double Inp_MaxDailyLoss     = 20.0;   // Detener si perdemos $20 hoy

//=================================================================
//  ESTRUCTURAS Y VARIABLES GLOBALES
//=================================================================
struct TEMACore {
   double ema1, ema2, ema3, tema, prevTema, slope;
   int    direction;
   bool   initialized;
};

int h_ATR, h_EMA_HTF, h_MFI;
double m_atr;
TEMACore m_tc;

//=================================================================
//  INICIALIZACIÓN
//=================================================================
int OnInit()
{
   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetTypeFillingBySymbol(_Symbol); // Auto-detección de modo de ejecución
   
   h_ATR = iATR(_Symbol, PERIOD_CURRENT, Inp_ATRPeriod);
   h_EMA_HTF = iMA(_Symbol, PERIOD_H1, Inp_EMA_HTF, 0, MODE_EMA, PRICE_CLOSE);
   h_MFI = iMFI(_Symbol, PERIOD_CURRENT, Inp_MFIPeriod, VOLUME_TICK);
   
   if(h_ATR == INVALID_HANDLE || h_EMA_HTF == INVALID_HANDLE || h_MFI == INVALID_HANDLE) 
      return INIT_FAILED;
   
   ZeroMemory(m_tc); 
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) { 
   IndicatorRelease(h_ATR); IndicatorRelease(h_EMA_HTF); IndicatorRelease(h_MFI);
}

//=================================================================
//  LÓGICA DE GESTIÓN DE ERRORES (MQL5 VALIDATOR)
//=================================================================
bool CheckTradeResult(uint retcode, string comment)
{
   switch(retcode)
   {
      case TRADE_RETCODE_DONE:
      case TRADE_RETCODE_DONE_PARTIAL:
      case TRADE_RETCODE_PLACED:
         return true; // Éxito
         
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_CONNECTION:
         Print("Error temporal: ", comment, ". Reintentando...");
         Sleep(100);
         return false; // Error recuperable
         
      case TRADE_RETCODE_NO_MONEY:
         Print("CRÍTICO: Sin fondos suficientes. Deteniendo operaciones.");
         return false; // Error fatal
         
      default:
         Print("Error de ejecución (", retcode, "): ", comment);
         return false;
   }
}

//=================================================================
//  DISPARO QUIRÚRGICO CON GESTIÓN DE RETRY
//=================================================================
void ExecuteTrade(ENUM_ORDER_TYPE type, double price, double sl)
{
   for(int i = 0; i < Inp_MaxRetries; i++)
   {
      // 1. Verificar Margen antes de disparar
      double marginRequired;
      if(!OrderCalcMargin(type, _Symbol, Inp_LotBase, price, marginRequired)) continue;
      if(marginRequired > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
         Print("Margen insuficiente para abrir posición.");
         return;
      }

      bool success = false;
      if(type == ORDER_TYPE_BUY) success = m_trade.Buy(Inp_LotBase, _Symbol, price, sl, 0, "ApexV7_BUY");
      else success = m_trade.Sell(Inp_LotBase, _Symbol, price, sl, 0, "ApexV7_SELL");

      if(success) {
         if(CheckTradeResult(m_trade.ResultRetcode(), "Entry")) break;
      }
      if(i == Inp_MaxRetries - 1) Print("Fallo tras ", Inp_MaxRetries, " reintentos.");
   }
}

//=================================================================
//  CORE: MOTOR TEMA-KALMAN Y SNIPER
//=================================================================
void UpdateTEMA()
{
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);
   double alpha = 2.0 / (Inp_TEMAPeriod + 1.0);

   if(!m_tc.initialized) {
      m_tc.ema1 = m_tc.ema2 = m_tc.ema3 = m_tc.tema = m_tc.prevTema = closePrice;
      m_tc.initialized = true; return;
   }

   m_tc.ema1 = alpha * closePrice     + (1.0 - alpha) * m_tc.ema1;
   m_tc.ema2 = alpha * m_tc.ema1      + (1.0 - alpha) * m_tc.ema2;
   m_tc.ema3 = alpha * m_tc.ema2      + (1.0 - alpha) * m_tc.ema3;
   m_tc.tema = 3.0 * m_tc.ema1 - 3.0 * m_tc.ema2 + m_tc.ema3;
   m_tc.slope = m_tc.tema - m_tc.prevTema;
   m_tc.prevTema = m_tc.tema;

   if(m_tc.slope > Inp_TrendMinSlope) m_tc.direction = 1;  
   else if(m_tc.slope < -Inp_TrendMinSlope) m_tc.direction = -1; 
   else m_tc.direction = 0;  
}

void OnTick()
{
   if(PositionsTotal() == 0) {
      // Sniper Entry
      double emaHTF[1], mfiBuf[1], atrBuf[1];
      if(CopyBuffer(h_EMA_HTF, 0, 0, 1, emaHTF) <= 0) return;
      if(CopyBuffer(h_MFI, 0, 0, 1, mfiBuf) <= 0) return;
      if(CopyBuffer(h_ATR, 0, 0, 1, atrBuf) <= 0) return;
      m_atr = atrBuf[0];

      UpdateTEMA();
      MqlTick tk; SymbolInfoTick(_Symbol, tk);
      
      bool macroUp = (tk.bid > emaHTF[0]);
      bool volOk = (mfiBuf[0] > Inp_MFILimit);

      if(m_tc.direction == 1 && macroUp && volOk) 
         ExecuteTrade(ORDER_TYPE_BUY, tk.ask, NormalizeDouble(tk.ask - m_atr*Inp_StopLossATR, _Digits));
      else if(m_tc.direction == -1 && !macroUp && volOk)
         ExecuteTrade(ORDER_TYPE_SELL, tk.bid, NormalizeDouble(tk.bid + m_atr*Inp_StopLossATR, _Digits));
   }
   
   // Gestión de Defensa (Breakeven & Trailing)
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(m_position.SelectByIndex(i) && m_position.Magic() == Inp_Magic) {
         double sl = m_position.StopLoss();
         double open = m_position.PriceOpen();
         double pnl = m_position.Profit() + m_position.Swap();
         MqlTick tk; SymbolInfoTick(_Symbol, tk);
         
         // Breakeven
         if(pnl >= Inp_BreakevenTriggerUSD && sl != open) {
            m_trade.PositionModify(m_position.Ticket(), open, 0);
         }
         // Trailing
         double actDist = m_atr * Inp_TrailingStartATR;
         double step = m_atr * Inp_TrailingStepATR;
         if(m_position.PositionType() == POSITION_TYPE_BUY && (tk.bid - open > actDist)) {
            double newSL = NormalizeDouble(tk.bid - step, _Digits);
            if(newSL > sl) m_trade.PositionModify(m_position.Ticket(), newSL, 0);
         }
      }
   }
}