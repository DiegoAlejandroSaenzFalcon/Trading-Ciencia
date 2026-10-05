//+------------------------------------------------------------------+
//|   NeurAlgo Gold Edition - Phase 2: Time Engine & Soft Close      |
//|   Autor: Diego Alejandro Saenz Falcon & Gem                      |
//+------------------------------------------------------------------+
#property copyright "NeurAlgo Dev Team"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade         m_trade;
CPositionInfo  m_position;

//=================================================================
//  PARÁMETROS DEL MOTOR DE TIEMPO (HORA DEL SERVIDOR MT5)
//=================================================================
input group "=== KILL ZONES (XAUUSD) ==="
input int Inp_HourStart = 11;      // Hora inicio (Londres/Pre-NY)
input int Inp_HourStop  = 21;      // Hora fin (Dejar de abrir nuevas)
input int Inp_HourKill  = 23;      // Hora de guillotina (Evitar Swap)
input int Inp_MinKill   = 50;      // Minuto de guillotina (23:50)

input group "=== MODO ESCAPE (SOFT CLOSE) ==="
input double Inp_EscapeProfitUSD = 1.00; // Si estamos en zona de escape, huir con $1.00

input group "=== THE SHIELD (PHASE 4: RISK MANAGEMENT) ==="
input ulong  Inp_Magic                 = 123456; // Magic Number NeurAlgo
input double Inp_BreakevenTriggerUSD   = 2.00;   // Beneficio USD para activar Breakeven
input int    Inp_BreakevenOffsetPoints = 20;     // Offset de Breakeven (Puntos XAUUSD)
input int    Inp_AtrPeriod             = 14;     // Periodo ATR para Trailing
input double Inp_TrailingStartATR      = 1.5;    // Multiplicador ATR (Activar Trailing)
input double Inp_TrailingStepATR       = 0.5;    // Multiplicador ATR (Distancia del Trailing)

int handle_atr;

//=================================================================
//  INICIALIZACIÓN DE INDICADORES (PHASE 4)
//=================================================================
int OnInit()
{
   handle_atr = iATR(_Symbol, PERIOD_M15, Inp_AtrPeriod);
   if(handle_atr == INVALID_HANDLE)
   {
      Print(">> ERROR CRÍTICO << Fallo al inicializar ATR para The Shield.");
      return INIT_FAILED;
   }
   m_trade.SetExpertMagicNumber(Inp_Magic);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorRelease(handle_atr);
}

//=================================================================
//  FUNCIÓN 1: ¿ESTAMOS EN HORARIO DE CAZA?
//=================================================================
bool IsHuntingZone()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // Si la hora actual está entre las 11:00 y las 20:59, podemos disparar
   if(dt.hour >= Inp_HourStart && dt.hour < Inp_HourStop) return true;
   
   return false;
}

//=================================================================
//  FUNCIÓN 2: EL MOTOR DE CIERRE CÍCLICO (TU IDEA)
//=================================================================
void RunEODProtocol()
{
   if(PositionsTotal() == 0) return; // Si no hay operaciones, no hay nada que gestionar
   
   MqlDateTime dt;
   TimeCurrent(dt);
   
   // 1. EVALUAR SI ESTAMOS EN LA ZONA DE ESCAPE O GUILLOTINA (De 21:00 en adelante)
   if(dt.hour >= Inp_HourStop)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(m_position.SelectByTicket(ticket))
         {
            double pnl = m_position.Profit() + m_position.Swap() + m_position.Commission();
            
            // FASE A: SOFT CLOSE (Cierre Cíclico)
            // Si la operación gana aunque sea nuestro profit de escape ($1.00), ¡Huye!
            if(pnl >= Inp_EscapeProfitUSD && dt.hour < Inp_HourKill)
            {
               m_trade.PositionClose(ticket);
               Print(">> SOFT CLOSE << Cerrando cíclicamente con +$", DoubleToString(pnl, 2), " antes del fin de día.");
               continue;
            }
            
            // FASE B: HARD CLOSE (Guillotina de las 23:50)
            // Si llegamos a las 23:50, matamos la operación para que el bróker no nos cobre el Swap de -$87
            if(dt.hour == Inp_HourKill && dt.min >= Inp_MinKill)
            {
               m_trade.PositionClose(ticket);
               Print(">> HARD CLOSE << Tiempo agotado. Cerrando para evitar penalización de Swap nocturno.");
            }
         }
      }
   }
}

//=================================================================
//  FUNCIÓN 3: EVALUACIÓN DE NUEVA VELA (M15)
//=================================================================
bool IsNewBar()
{
   static datetime last_time = 0;
   datetime current_time = iTime(_Symbol, PERIOD_M15, 0);
   if(current_time != last_time)
   {
      last_time = current_time;
      return true;
   }
   return false;
}

//=================================================================
//  FUNCIÓN 4: THE RADAR - SNIPER ENTRY LOGIC
//=================================================================
void SniperEntry()
{
   if(PositionsTotal() >= 1) return; // RESTRICCIÓN: Máximo 1 operación abierta por margen

   double tema[], ema_htf[], mfi[];
   ArraySetAsSeries(tema, true);
   ArraySetAsSeries(ema_htf, true);
   ArraySetAsSeries(mfi, true);

   // Extraer datos de la vela cerrada (índice 1 y 2 para pendiente TEMA en M15, índice 1 para EMA y MFI)
   if(CopyBuffer(handle_tema, 0, 1, 2, tema) <= 0) return;
   if(CopyBuffer(handle_ema_htf, 0, 1, 1, ema_htf) <= 0) return;
   if(CopyBuffer(handle_mfi, 0, 1, 1, mfi) <= 0) return;

   // Precio de cierre de la vela anterior M15 para evitar repintado intra-vela
   double close_price = iClose(_Symbol, PERIOD_M15, 1);

   // Cálculo de la pendiente (Absoluta para Gold): TEMA[0] (cerrada reciente) - TEMA[1] (anterior)
   double tema_slope = tema[0] - tema[1];

   // Verificación estricta de Margen Libre
   double margin_required;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, Inp_LotSize, SymbolInfoDouble(_Symbol, SYMBOL_ASK), margin_required)) return;
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required)
   {
      Print(">> ALERTA DE MARGEN << Margen libre insuficiente para The Sniper.");
      return;
   }

   // LÓGICA DE CONFLUENCIA ESTRICTA (THE SNIPER)
   if(tema_slope > Inp_TrendMinSlope && close_price > ema_htf[0] && mfi[0] > 50.0)
   {
      m_trade.Buy(Inp_LotSize, _Symbol);
      Print(">> THE SNIPER << LONG Ejecutado | TEMA Slope: ", DoubleToString(tema_slope, 2), " | MFI: ", DoubleToString(mfi[0], 2));
   }
   else if(tema_slope < -Inp_TrendMinSlope && close_price < ema_htf[0] && mfi[0] < 50.0)
   {
      m_trade.Sell(Inp_LotSize, _Symbol);
      Print(">> THE SNIPER << SHORT Ejecutado | TEMA Slope: ", DoubleToString(tema_slope, 2), " | MFI: ", DoubleToString(mfi[0], 2));
   }
}

//=================================================================
//  FUNCIÓN 5: THE SHIELD - GESTIÓN DE RIESGO AVANZADA
//=================================================================
void ManageDefense()
{
   if(PositionsTotal() == 0) return;
   
   // Extraer el valor actual del ATR para el trailing dinámico
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(handle_atr, 0, 0, 1, atr) <= 0) return;
   double current_atr = atr[0];
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double activation_dist = Inp_TrailingStartATR * current_atr;
   double step_dist       = Inp_TrailingStepATR * current_atr;
   double be_offset       = Inp_BreakevenOffsetPoints * point;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(m_position.SelectByTicket(ticket))
      {
         // Validar Símbolo y Magic Number estrictamente
         if(m_position.Symbol() == _Symbol && m_position.Magic() == Inp_Magic)
         {
            double open_price = m_position.PriceOpen();
            double current_sl = m_position.StopLoss();
            double tp         = m_position.TakeProfit();
            long   pos_type   = m_position.PositionType();
            double pnl        = m_position.Profit() + m_position.Swap() + m_position.Commission();
            
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            
            double new_sl = current_sl;
            bool modify_sl = false;
            
            // 1. BREAKEVEN PROTOCOL
            if(pnl >= Inp_BreakevenTriggerUSD)
            {
               if(pos_type == POSITION_TYPE_BUY)
               {
                  double be_level = NormalizeDouble(open_price + be_offset, _Digits);
                  if(current_sl < be_level) // Mover solo a favor
                  {
                     new_sl = be_level;
                     modify_sl = true;
                  }
               }
               else if(pos_type == POSITION_TYPE_SELL)
               {
                  double be_level = NormalizeDouble(open_price - be_offset, _Digits);
                  if(current_sl > be_level || current_sl == 0) // Mover solo a favor o si no hay SL
                  {
                     new_sl = be_level;
                     modify_sl = true;
                  }
               }
            }
            
            // 2. ATR DYNAMIC TRAILING
            if(pos_type == POSITION_TYPE_BUY)
            {
               if((bid - open_price) > activation_dist)
               {
                  double trail_level = NormalizeDouble(bid - step_dist, _Digits);
                  if(new_sl < trail_level) // Mover estrictamente a favor
                  {
                     new_sl = trail_level;
                     modify_sl = true;
                  }
               }
            }
            else if(pos_type == POSITION_TYPE_SELL)
            {
               if((open_price - ask) > activation_dist)
               {
                  double trail_level = NormalizeDouble(ask + step_dist, _Digits);
                  if(new_sl > trail_level || new_sl == 0) // Mover estrictamente a favor o si no hay SL
                  {
                     new_sl = trail_level;
                     modify_sl = true;
                  }
               }
            }
            
            // 3. EJECUTAR MODIFICACIÓN SI APLICA
            if(modify_sl)
            {
               if(m_trade.PositionModify(ticket, new_sl, tp))
               {
                  Print(">> THE SHIELD << Defensa actualizada para Ticket #", ticket, " | Nuevo SL: ", DoubleToString(new_sl, _Digits));
               }
            }
         }
      }
   }
}

//=================================================================
//  ESTRUCTURA PRINCIPAL (ON TICK)
//=================================================================
void OnTick()
{
   // 1. Ejecutamos tu protocolo de protección de fin de día SIEMPRE
   RunEODProtocol();
   
   // 2. THE SHIELD: Gestión de riesgo tick a tick (Breakeven & Trailing)
   ManageDefense();
   
   // 3. Solo evaluamos nuevas entradas si estamos en horario de caza Y en la apertura de una vela M15
   if(IsHuntingZone() && IsNewBar())
   {
      SniperEntry();
   }
}