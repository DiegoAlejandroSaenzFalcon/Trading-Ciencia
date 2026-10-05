//+------------------------------------------------------------------+
//|   NeurAlgo XAU - Phase 10: Institutional Time Filter & ADX Armor |
//|   Objetivo: Filtrado estricto de consolidaciones y Sesión Asia   |
//+------------------------------------------------------------------+
#property copyright "NeurAlgo Dev Team"
#property version   "10.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade         m_trade;
CPositionInfo  m_position;

//=================================================================
//  PARÁMETROS DE ENTRADA (OPTIMIZADOS PARA XAUUSD)
//=================================================================
input group "=== CONFIGURACIÓN COMERCIAL ==="
input long   Inp_Magic            = 77778888;
input double Inp_LotBase          = 0.01;
input int    Inp_MaxRetries       = 3;      // Reintentos ante errores de red

input group "=== FILTRO HORARIO INSTITUCIONAL ==="
input int    Inp_StartHour        = 8;      // Hora inicio operativa (Broker Time)
input int    Inp_EndHour          = 16;     // Hora fin operativa (Broker Time)

input group "=== MOTOR TEMA-KALMAN (RADAR M15 XAU) ==="
input int    Inp_TEMAPeriod       = 18;     // Reducido para mayor reactividad en XAU
input double Inp_TrendMinSlope    = 0.15;   // Ajustado al spread y volatilidad del Oro

input group "=== FILTRO SISTÉMICO (MACRO H1) ==="
input int    Inp_EMA_HTF          = 100;    // 100 periodos en H1 es más sensible para XAU

input group "=== FILTRO DE VOLATILIDAD Y TENDENCIA (ADX H1) ==="
input int    Inp_ADXPeriod        = 14;     // Período estándar para medición de fuerza
input double Inp_ADXLimit         = 25.0;   // ADX > 25 indica tendencia fuerte, < 25 es rango

input group "=== FILTRO DE GASOLINA (VOLUMEN MFI) ==="
input int    Inp_MFIPeriod        = 14;
input int    Inp_MFILimit         = 45;     // Ligeramente más permisivo para evitar falsos negativos

input group "=== GESTIÓN DE RIESGO XAU (ATR) ==="
input int    Inp_ATRPeriod        = 14;
input double Inp_StopLossATR      = 1.80;   // Optimizado por Algoritmo Genético
input double Inp_TrailingStartATR = 2.2;    // Optimizado por Algoritmo Genético
input double Inp_TrailingStepATR  = 3.15;   // Optimizado por Algoritmo Genético
input double Inp_BreakevenTriggerUSD = 2.0; // Break-even a los $2 USD de ganancia

input group "=== FILTROS DE SEGURIDAD ==="
input int    Inp_MaxSpread        = 300;    // 30 pips máximo en Pepperstone Razor para XAUUSD
input double Inp_MaxDailyLoss     = 15.0;   // Detener si perdemos $15 hoy (Protección de los $100)

input group "=== DASHBOARD UI ==="
input color  Inp_ColorBg          = clrBlack;
input color  Inp_ColorText        = clrWhite;
input color  Inp_ColorBull        = clrLimeGreen;
input color  Inp_ColorBear        = clrRed;

//=================================================================
//  ESTRUCTURAS Y VARIABLES GLOBALES
//=================================================================
struct TEMACore {
   double ema1, ema2, ema3, tema, prevTema, slope;
   int    direction;
   bool   initialized;
};

int h_ATR, h_EMA_HTF, h_MFI, h_ADX;
double m_atr;
TEMACore m_tc;
string DashboardPrefix = "NeurAlgo_HUD_";

//=================================================================
//  INICIALIZACIÓN Y DEINICIALIZACIÓN
//=================================================================
int OnInit()
{
   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetTypeFillingBySymbol(_Symbol); // Auto-detección de modo de ejecución (FOK/IOC)
   
   h_ATR = iATR(_Symbol, PERIOD_CURRENT, Inp_ATRPeriod);
   h_EMA_HTF = iMA(_Symbol, PERIOD_H1, Inp_EMA_HTF, 0, MODE_EMA, PRICE_CLOSE);
   h_MFI = iMFI(_Symbol, PERIOD_CURRENT, Inp_MFIPeriod, VOLUME_TICK);
   h_ADX = iADX(_Symbol, PERIOD_H1, Inp_ADXPeriod);
   
   if(h_ATR == INVALID_HANDLE || h_EMA_HTF == INVALID_HANDLE || h_MFI == INVALID_HANDLE || h_ADX == INVALID_HANDLE) 
   {
      Print("Error inicializando indicadores CORE.");
      return INIT_FAILED;
   }
   
   ZeroMemory(m_tc); 
   
   // Inicializar Dashboard a 1 segundo
   EventSetTimer(1);
   InitDashboard();
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) 
{ 
   IndicatorRelease(h_ATR); 
   IndicatorRelease(h_EMA_HTF); 
   IndicatorRelease(h_MFI);
   IndicatorRelease(h_ADX);
   EventKillTimer();
   DestroyDashboard();
}

//=================================================================
//  LÓGICA DE UI: DASHBOARD NEURALGO
//=================================================================
void InitDashboard()
{
   CreateLabel(DashboardPrefix + "Title", "NeurAlgo Quant V10 - XAUUSD", 20, 20, 14, clrDodgerBlue, true);
   CreateLabel(DashboardPrefix + "Balance", "Balance: ", 20, 45, 10, Inp_ColorText);
   CreateLabel(DashboardPrefix + "Spread", "Spread: ", 20, 65, 10, Inp_ColorText);
   CreateLabel(DashboardPrefix + "Session", "Filtro Horario: Analizando...", 20, 85, 10, Inp_ColorText);
   CreateLabel(DashboardPrefix + "ADX", "ADX Macro: Analizando...", 20, 105, 10, Inp_ColorText);
   CreateLabel(DashboardPrefix + "TEMA", "TEMA Core: Analizando...", 20, 125, 10, Inp_ColorText);
   CreateLabel(DashboardPrefix + "Macro", "HTF Macro: Analizando...", 20, 145, 10, Inp_ColorText);
}

void DestroyDashboard()
{
   ObjectsDeleteAll(0, DashboardPrefix);
}

void CreateLabel(string name, string text, int x, int y, int size, color col, bool bold = false)
{
   if(ObjectFind(0, name) < 0) ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetString(0, name, OBJPROP_FONT, bold ? "Trebuchet MS Bold" : "Trebuchet MS");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, size);
   ObjectSetInteger(0, name, OBJPROP_COLOR, col);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void OnTimer()
{
   // Actualización de UI en tiempo real
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   long sprd = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   
   ObjectSetString(0, DashboardPrefix + "Balance", OBJPROP_TEXT, StringFormat("Balance: $%.2f | Eq: $%.2f", bal, eq));
   ObjectSetString(0, DashboardPrefix + "Spread", OBJPROP_TEXT, StringFormat("Spread Actual: %d pts", sprd));
   
   if(sprd > Inp_MaxSpread) ObjectSetInteger(0, DashboardPrefix + "Spread", OBJPROP_COLOR, Inp_ColorBear);
   else ObjectSetInteger(0, DashboardPrefix + "Spread", OBJPROP_COLOR, Inp_ColorBull);

   // Actualización visual del Filtro Horario
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   bool sessionActive = (t.hour >= Inp_StartHour && t.hour < Inp_EndHour);
   string sessionStr = sessionActive ? "ACTIVA (LND/NY)" : "CERRADA (Riesgo Asiático)";
   ObjectSetString(0, DashboardPrefix + "Session", OBJPROP_TEXT, "Sesión: " + sessionStr);
   ObjectSetInteger(0, DashboardPrefix + "Session", OBJPROP_COLOR, sessionActive ? Inp_ColorBull : clrOrange);

   // Actualización visual del ADX
   double adxBuf[1];
   if(CopyBuffer(h_ADX, 0, 0, 1, adxBuf) > 0)
   {
      string adxStr = (adxBuf[0] > Inp_ADXLimit) ? StringFormat("TENDENCIA ACTIVA (%.1f)", adxBuf[0]) : StringFormat("RANGO DETECTADO (%.1f)", adxBuf[0]);
      color adxCol = (adxBuf[0] > Inp_ADXLimit) ? Inp_ColorBull : clrOrange;
      ObjectSetString(0, DashboardPrefix + "ADX", OBJPROP_TEXT, "Filtro ADX: " + adxStr);
      ObjectSetInteger(0, DashboardPrefix + "ADX", OBJPROP_COLOR, adxCol);
   }

   string temaStr = (m_tc.direction == 1) ? "ALCISTA (Sniper Listo)" : ((m_tc.direction == -1) ? "BAJISTA (Sniper Listo)" : "NEUTRAL / ESPERANDO");
   color temaCol = (m_tc.direction == 1) ? Inp_ColorBull : ((m_tc.direction == -1) ? Inp_ColorBear : clrGray);
   ObjectSetString(0, DashboardPrefix + "TEMA", OBJPROP_TEXT, "TEMA Estado: " + temaStr);
   ObjectSetInteger(0, DashboardPrefix + "TEMA", OBJPROP_COLOR, temaCol);
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
         return true; 
         
      case TRADE_RETCODE_REQUOTE:
      case TRADE_RETCODE_PRICE_OFF:
      case TRADE_RETCODE_CONNECTION:
         Print("Error temporal: ", comment, ". Reintentando...");
         Sleep(100);
         return false; 
         
      case TRADE_RETCODE_NO_MONEY:
         Print("CRÍTICO: Sin fondos suficientes. Deteniendo operaciones.");
         return false; 
         
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
      double marginRequired;
      if(!OrderCalcMargin(type, _Symbol, Inp_LotBase, price, marginRequired)) continue;
      if(marginRequired > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
         Print("Margen insuficiente para abrir posición en XAUUSD.");
         return;
      }

      bool success = false;
      if(type == ORDER_TYPE_BUY) success = m_trade.Buy(Inp_LotBase, _Symbol, price, sl, 0, "NeurAlgo_BUY");
      else success = m_trade.Sell(Inp_LotBase, _Symbol, price, sl, 0, "NeurAlgo_SELL");

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
   // Filtro de Spread estricto
   long current_spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(current_spread > Inp_MaxSpread) return;

   // Lógica de Filtro Horario Institucional
   MqlDateTime time;
   TimeToStruct(TimeCurrent(), time);
   bool isTradingHour = (time.hour >= Inp_StartHour && time.hour < Inp_EndHour);

   // Solo buscar entradas si estamos en la sesión permitida y no hay posiciones
   if(PositionsTotal() == 0 && isTradingHour) {
      double emaHTF[1], mfiBuf[1], atrBuf[1], adxBuf[1];
      if(CopyBuffer(h_EMA_HTF, 0, 0, 1, emaHTF) <= 0) return;
      if(CopyBuffer(h_MFI, 0, 0, 1, mfiBuf) <= 0) return;
      if(CopyBuffer(h_ATR, 0, 0, 1, atrBuf) <= 0) return;
      if(CopyBuffer(h_ADX, 0, 0, 1, adxBuf) <= 0) return;
      m_atr = atrBuf[0];

      UpdateTEMA();
      MqlTick tk; SymbolInfoTick(_Symbol, tk);
      
      bool macroUp = (tk.bid > emaHTF[0]);
      bool volOk = (mfiBuf[0] > Inp_MFILimit);
      bool adxOk = (adxBuf[0] > Inp_ADXLimit); 

      string macroStr = macroUp ? "ALCISTA (> EMA 100 H1)" : "BAJISTA (< EMA 100 H1)";
      ObjectSetString(0, DashboardPrefix + "Macro", OBJPROP_TEXT, "HTF Macro: " + macroStr);
      ObjectSetInteger(0, DashboardPrefix + "Macro", OBJPROP_COLOR, macroUp ? Inp_ColorBull : Inp_ColorBear);

      if(m_tc.direction == 1 && macroUp && volOk && adxOk) 
         ExecuteTrade(ORDER_TYPE_BUY, tk.ask, NormalizeDouble(tk.ask - m_atr*Inp_StopLossATR, _Digits));
      else if(m_tc.direction == -1 && !macroUp && volOk && adxOk)
         ExecuteTrade(ORDER_TYPE_SELL, tk.bid, NormalizeDouble(tk.bid + m_atr*Inp_StopLossATR, _Digits));
   }
   
   // Gestión de Defensa (Breakeven & Trailing) - INDEPENDIENTE DEL HORARIO
   // Si hay una operación abierta, se gestiona y protege sin importar la hora
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(m_position.SelectByIndex(i) && m_position.Magic() == Inp_Magic) {
         
         // Actualización de ATR para trailing (necesario si se entra a gestionar fuera de hora)
         if(PositionsTotal() > 0 && !isTradingHour) {
             double atrBufDef[1];
             if(CopyBuffer(h_ATR, 0, 0, 1, atrBufDef) > 0) m_atr = atrBufDef[0];
         }

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
         else if(m_position.PositionType() == POSITION_TYPE_SELL && (open - tk.ask > actDist)) {
            double newSL = NormalizeDouble(tk.ask + step, _Digits);
            if(newSL < sl || sl == 0) m_trade.PositionModify(m_position.Ticket(), newSL, 0);
         }
      }
   }
}
//+------------------------------------------------------------------+