//+------------------------------------------------------------------+
//|                                                  HedgingZone.mq5 |
//|                                      Desarrollo Técnico Avanzado |
//+------------------------------------------------------------------+
#property copyright "Arquitectura Algorítmica - Senior Refactor"
#property link      ""
#property version   "2.00" // Motor V2: ATR, TimeStop, Escalado Profit

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Inputs 1: Gestión de Riesgo y Lotes (ORIGINAL INTACTO)
input double   InpLot1           = 0.01;      // Lote Operación 1
input double   InpLot2           = 0.03;      // Lote Operación 2 (Hedge)
input double   InpLot3           = 0.03;      // Lote Operación 3 (Desempate)
input double   InpLossTrigger1   = -4.5;      // Gatillo Pérdida 1 Fijo ($)
input double   InpLossTrigger2   = -9.0;      // Gatillo Pérdida 2 Fijo ($)
input double   InpTargetProfit   = 1.0;       // Ganancia Mínima Bloque ($)
input double   InpMaxDrawdown    = 50.0;      // Drawdown Máximo (%)

//--- Inputs 2: Trailing Stop (AJUSTADO A PUNTOS XAUUSD)
input int      InpBreakevenStart = 200;       // Breakeven Inicio (Puntos)
input int      InpTrailingStop   = 300;       // Trailing Stop (Puntos)
input int      InpTrailingStep   = 50;        // Trailing Step (Puntos)

//--- Inputs 3: Estrategia de Entrada M15 (ORIGINAL INTACTO)
input int      InpBBPeriod       = 20;        // Periodo Bollinger/Volatilidad
input double   InpBBDeviation    = 2.0;       // Desviación de Volatilidad

//--- Inputs 4: SEGURIDAD DINÁMICA Y ESCALADO (VALORES OPTIMIZADOS)
input bool     InpUseDynamicATR  = true;      // Usar ATR para Gatillos Pérdida
input int      InpATRPeriod      = 14;        // Periodo ATR
input double   InpATRMult1       = 10.0;      // Multiplicador ATR Fase 1
input double   InpATRMult2       = 20.0;      // Multiplicador ATR Fase 2
input int      InpMaxBlockHours  = 24;        // Time Stop: Max Horas de Cobertura
input double   InpTargetMult2    = 2.0;       // Escala Profit Fase 2 (x2)
input double   InpTargetMult3    = 5.0;       // Escala Profit Fase 3 (x5)

input ulong    InpMagicNumber    = 777888;    // Magic Number

//--- Global Objects & Variables
CTrade         m_trade;
CPositionInfo  m_position;
bool           m_ea_halted       = false;
int            m_handle_bb;                   // Handle Bollinger
int            m_handle_atr;                  // Handle ATR

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("Error: La cuenta debe ser tipo Hedging para operar este EA.");
      return(INIT_FAILED);
     }

   // Inicializar Indicadores
   m_handle_bb = iBands(_Symbol, PERIOD_M15, InpBBPeriod, 0, InpBBDeviation, PRICE_CLOSE);
   m_handle_atr = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   
   if(m_handle_bb == INVALID_HANDLE || m_handle_atr == INVALID_HANDLE)
     {
      Print("Error al inicializar los indicadores del motor estadístico.");
      return(INIT_FAILED);
     }

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(m_handle_bb);
   IndicatorRelease(m_handle_atr);
   Comment(""); // Limpiar telemetría
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(m_ea_halted) return;

   CheckDrawdownAndFailsafe();
   if(m_ea_halted) return;

   int total_positions = CountPositions();
   double net_profit = CalculateNetProfit();

   //--- CÁLCULO DE PARÁMETROS DINÁMICOS EN TIEMPO REAL
   double current_trigger1, current_trigger2;
   GetDynamicTriggers(current_trigger1, current_trigger2);
   
   double current_target = InpTargetProfit;
   if(total_positions == 2) current_target = InpTargetProfit * InpTargetMult2;
   if(total_positions >= 3) current_target = InpTargetProfit * InpTargetMult3;

   //--- CHEQUEO DE TIME STOP (Mitigación de colas pesadas)
   if(total_positions >= 2)
     {
      if(CheckTimeStop()) return; // Si el EA cierra por tiempo, se aborta este tick
     }

   //--- ACTUALIZACIÓN DE TELEMETRÍA
   UpdateDashboard(current_trigger1, current_trigger2, current_target);

   // FASE 0: Abrir posición inicial basada en Ruptura de Volatilidad M15
   if(total_positions == 0)
     {
      static datetime last_time = 0;
      datetime current_time = iTime(_Symbol, PERIOD_M15, 0);
      
      if(current_time != last_time) 
        {
         double bb_upper[], bb_lower[], close_prices[];
         ArraySetAsSeries(bb_upper, true);
         ArraySetAsSeries(bb_lower, true);
         ArraySetAsSeries(close_prices, true);

         if(CopyBuffer(m_handle_bb, 1, 1, 1, bb_upper) > 0 && 
            CopyBuffer(m_handle_bb, 2, 1, 1, bb_lower) > 0 &&
            CopyClose(_Symbol, PERIOD_M15, 1, 1, close_prices) > 0)
           {
            if(close_prices[0] > bb_upper[0]) 
              {
               if(m_trade.Buy(InpLot1, _Symbol)) last_time = current_time;
              }
            else if(close_prices[0] < bb_lower[0])
              {
               if(m_trade.Sell(InpLot1, _Symbol)) last_time = current_time;
              }
           }
        }
      return;
     }

   // FASE 1: Una sola operación activa
   if(total_positions == 1)
     {
      ManageTrailingStop();

      // Usar el gatillo dinámico (o el estático si InpUseDynamicATR es false)
      if(net_profit <= current_trigger1)
        {
         ENUM_POSITION_TYPE pos_type = GetFirstPositionType();
         if(pos_type == POSITION_TYPE_BUY)
            m_trade.Sell(InpLot2, _Symbol);
         else if(pos_type == POSITION_TYPE_SELL)
            m_trade.Buy(InpLot2, _Symbol);
        }
      return;
     }

   // FASE 2: Dos operaciones activas (Cobertura)
   if(total_positions == 2)
     {
      // Validar contra el Target Profit Escalado
      if(net_profit >= current_target)
        {
         CloseAllPositions();
         return;
        }

      // Validar contra el Gatillo Dinámico 2
      if(net_profit <= current_trigger2)
        {
         ENUM_POSITION_TYPE last_pos_type = GetLastPositionType();
         if(last_pos_type == POSITION_TYPE_SELL)
            m_trade.Buy(InpLot3, _Symbol);
         else if(last_pos_type == POSITION_TYPE_BUY)
            m_trade.Sell(InpLot3, _Symbol);
        }
      return;
     }

   // FASE 3: Tres operaciones activas (Desempate)
   if(total_positions >= 3)
     {
      // Validar contra el Target Profit Escalado
      if(net_profit >= current_target)
        {
         CloseAllPositions();
        }
      return;
     }
  }

//+------------------------------------------------------------------+
//| Calcula los gatillos de pérdida convirtiendo ATR a USD Flotante  |
//+------------------------------------------------------------------+
void GetDynamicTriggers(double &trigger1, double &trigger2)
  {
   if(!InpUseDynamicATR)
     {
      trigger1 = InpLossTrigger1;
      trigger2 = InpLossTrigger2;
      return;
     }

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(m_handle_atr, 0, 1, 1, atr) > 0)
     {
      double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      
      // Conversión: Valor en USD del movimiento del ATR para 1 Lote
      double atr_usd_1lot = (atr[0] / tick_size) * tick_value;
      
      // Gatillo calculado sobre el lote base (InpLot1) y los multiplicadores
      trigger1 = - (atr_usd_1lot * InpLot1 * InpATRMult1);
      trigger2 = - (atr_usd_1lot * InpLot1 * InpATRMult2);
     }
   else
     {
      // Failsafe por si el buffer falla
      trigger1 = InpLossTrigger1;
      trigger2 = InpLossTrigger2;
     }
  }

//+------------------------------------------------------------------+
//| Evalúa si el bloque lleva demasiado tiempo en drawdown           |
//+------------------------------------------------------------------+
bool CheckTimeStop()
  {
   if(InpMaxBlockHours <= 0) return false;
   
   datetime oldest_time = TimeCurrent();
   bool found = false;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            datetime pos_time = (datetime)m_position.Time();
            if(pos_time < oldest_time) oldest_time = pos_time;
            found = true;
           }
        }
     }
   
   if(found)
     {
      int hours_open = (int)(TimeCurrent() - oldest_time) / 3600;
      if(hours_open >= InpMaxBlockHours)
        {
         Print(">>> TIME STOP EJECUTADO: Bloque cerrado forzosamente tras ", hours_open, " horas.");
         CloseAllPositions();
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Dashboard de Telemetría (Actualizado para Motor Dinámico)        |
//+------------------------------------------------------------------+
void UpdateDashboard(double t_trigger1, double t_trigger2, double t_target)
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double current_dd = (balance > 0) ? ((balance - equity) / balance) * 100.0 : 0.0;
   
   string status = m_ea_halted ? "🛑 DETENIDO (Límite Riesgo)" : "🟢 MOTOR V2 OPERATIVO";
   int pos_count = CountPositions();
   double net_profit = CalculateNetProfit();
   
   string dash = "\n";
   dash += "=== PROYECTO NEURALGO: M15 HEDGING V2 ===\n\n";
   dash += "ESTADO         : " + status + "\n";
   dash += "POSICIONES     : " + IntegerToString(pos_count) + " activas\n";
   dash += "PnL BLOQUE     : $ " + DoubleToString(net_profit, 2) + "\n";
   dash += "DRAWDOWN REAL  : " + DoubleToString(current_dd, 2) + " %\n";
   dash += "--------------------------------------\n";
   
   if(InpUseDynamicATR) dash += "[ATR FILTER ACTIVO] - Gatillos Variables\n";
   else dash += "[ATR FILTER OFF] - Gatillos Fijos\n";
   
   dash += "Gatillo Fase 1 : $ " + DoubleToString(t_trigger1, 2) + "\n";
   dash += "Gatillo Fase 2 : $ " + DoubleToString(t_trigger2, 2) + "\n";
   dash += "Objetivo Actual: $ " + DoubleToString(t_target, 2) + "\n\n";
   
   if(pos_count >= 2 && InpMaxBlockHours > 0)
     {
      datetime oldest = TimeCurrent();
      for(int i=0; i<PositionsTotal(); i++)
        {
         if(m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            if((datetime)m_position.Time() < oldest) oldest = (datetime)m_position.Time();
           }
        }
      int h_open = (int)(TimeCurrent() - oldest) / 3600;
      dash += ">>> TIME STOP ALERTA: " + IntegerToString(h_open) + " / " + IntegerToString(InpMaxBlockHours) + " Horas.\n";
     }
     
   Comment(dash);
  }

//+------------------------------------------------------------------+
//| FUNCIONES BASE ORIGINALES PRESERVADAS INTACTAS                   |
//+------------------------------------------------------------------+
double CalculateNetProfit()
  {
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            profit += m_position.Profit() + m_position.Swap() + m_position.Commission();
           }
        }
     }
   return profit;
  }

int CountPositions()
  {
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
            count++;
        }
     }
   return count;
  }

void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            m_trade.PositionClose(m_position.Ticket());
           }
        }
     }
  }

void ManageTrailingStop()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
            
            double open_price = m_position.PriceOpen();
            double sl = m_position.StopLoss();
            ENUM_POSITION_TYPE type = m_position.PositionType();

            if(type == POSITION_TYPE_BUY)
              {
               if(bid - open_price > InpBreakevenStart * point)
                 {
                  double new_sl = bid - InpTrailingStop * point;
                  if(new_sl > open_price && (sl == 0 || new_sl > sl + InpTrailingStep * point))
                    {
                     m_trade.PositionModify(m_position.Ticket(), new_sl, 0);
                    }
                 }
              }
            else if(type == POSITION_TYPE_SELL)
              {
               if(open_price - ask > InpBreakevenStart * point)
                 {
                  double new_sl = ask + InpTrailingStop * point;
                  if(new_sl < open_price && (sl == 0 || new_sl < sl - InpTrailingStep * point))
                    {
                     m_trade.PositionModify(m_position.Ticket(), new_sl, 0);
                    }
                 }
              }
           }
        }
     }
  }

ENUM_POSITION_TYPE GetFirstPositionType()
  {
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
            return m_position.PositionType();
        }
     }
   return POSITION_TYPE_BUY; 
  }

ENUM_POSITION_TYPE GetLastPositionType()
  {
   ulong last_ticket = 0;
   ENUM_POSITION_TYPE last_type = POSITION_TYPE_BUY;
   
   for(int i = 0; i < PositionsTotal(); i++)
     {
      if(m_position.SelectByIndex(i))
        {
         if(m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber)
           {
            if(m_position.Ticket() > last_ticket)
              {
               last_ticket = m_position.Ticket();
               last_type = m_position.PositionType();
              }
           }
        }
     }
   return last_type;
  }

void CheckDrawdownAndFailsafe()
  {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   if(balance > 0)
     {
      double current_dd = ((balance - equity) / balance) * 100.0;
      if(current_dd >= InpMaxDrawdown)
        {
         Print("¡ALERTA CRÍTICA! Drawdown del 50% alcanzado. Cerrando operaciones y deteniendo EA.");
         CloseAllPositions();
         m_ea_halted = true;
        }
     }
  }
//+------------------------------------------------------------------+