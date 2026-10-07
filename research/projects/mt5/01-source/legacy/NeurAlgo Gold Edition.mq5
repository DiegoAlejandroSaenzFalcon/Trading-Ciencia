//+------------------------------------------------------------------+
//|   NeurAlgo Gold Edition - V1 (Complete Architecture)             |
//|   Autor: Diego Alejandro Saenz Falcon & Gem                      |
//|   Objetivo: Operativa Institucional en XAUUSD (Micro-Cuenta)     |
//+------------------------------------------------------------------+
#property copyright "NeurAlgo Dev Team"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

CTrade         m_trade;
CPositionInfo  m_position;

//=================================================================
//  PARÁMETROS DEL MOTOR (XAUUSD ADAPTED)
//=================================================================
input group "=== CONFIGURACION GENERAL ==="
input long   Inp_Magic            = 8888; // Magic distinto para Oro
input double Inp_LotBase          = 0.01;

input group "=== KILL ZONES (HORA SERVIDOR GMT+3) ==="
input int Inp_HourStart = 11;      
input int Inp_HourStop  = 21;      
input int Inp_HourKill  = 23;      
input int Inp_MinKill   = 50;      

input group "=== MODO ESCAPE (SOFT CLOSE) ==="
input double Inp_EscapeProfitUSD = 1.00;

input group "=== RADAR TEMA + VOLUMEN ==="
input int    Inp_TEMAPeriod       = 22;     
input double Inp_TrendMinSlope    = 0.20;   // ADAPTADO AL ORO (0.20 puntos absolutos)
input int    Inp_EMA_HTF          = 200;    
input int    Inp_MFIPeriod        = 14;
input int    Inp_MFILimit         = 50;     

input group "=== ESCUDO TICK A TICK (ATR) ==="
input int    Inp_ATRPeriod        = 14;
input double Inp_StopLossATR      = 2.9;    
input double Inp_TrailingStartATR = 3.0;    
input double Inp_TrailingStepATR  = 0.5;    
input double Inp_BreakevenTriggerUSD = 4.0; // Proteger en $4 de ganancia

//=================================================================
//  ESTRUCTURAS Y HANDLES
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
//  INICIALIZACION
//=================================================================
int OnInit()
{
   m_trade.SetExpertMagicNumber(Inp_Magic);
   
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
//  FILTROS DE TIEMPO
//=================================================================
bool IsNewBar()
{
   static datetime lastTime = 0;
   datetime currentTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentTime != lastTime) { lastTime = currentTime; return true; }
   return false;
}

bool IsHuntingZone()
{
   MqlDateTime dt; TimeCurrent(dt);
   if(dt.hour >= Inp_HourStart && dt.hour < Inp_HourStop) return true;
   return false;
}

//=================================================================
//  PROTOCOLOS DE CIERRE (SOFT & HARD)
//=================================================================
void RunEODProtocol()
{
   if(PositionsTotal() == 0) return; 
   MqlDateTime dt; TimeCurrent(dt);
   
   if(dt.hour >= Inp_HourStop)
   {
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(m_position.SelectByTicket(ticket) && m_position.Magic() == Inp_Magic)
         {
            double pnl = m_position.Profit() + m_position.Swap() + m_position.Commission();
            
            // FASE A: SOFT CLOSE
            if(pnl >= Inp_EscapeProfitUSD && dt.hour < Inp_HourKill)
            {
               m_trade.PositionClose(ticket);
               Print(">> ESCAPE << Asegurando ganancia antes del Swap.");
               continue;
            }
            // FASE B: HARD CLOSE
            if(dt.hour == Inp_HourKill && dt.min >= Inp_MinKill)
            {
               m_trade.PositionClose(ticket);
               Print(">> GUILLOTINA << Cerrando posición obligatoria.");
            }
         }
      }
   }
}

//=================================================================
//  MOTOR TEMA Y SNIPER (FASE 3)
//=================================================================
void UpdateTEMA()
{
   double closePrice = iClose(_Symbol, PERIOD_CURRENT, 1);
   if(closePrice <= 0) return;
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

void SniperEntry()
{
   if(PositionsTotal() > 0) return; 
   
   double emaHTF[1], mfiBuf[1], atrBuf[1];
   if(CopyBuffer(h_EMA_HTF, 0, 0, 1, emaHTF) <= 0 || CopyBuffer(h_MFI, 0, 0, 1, mfiBuf) <= 0 || CopyBuffer(h_ATR, 0, 0, 1, atrBuf) <= 0) return;
   
   m_atr = atrBuf[0];
   MqlTick tk; SymbolInfoTick(_Symbol, tk);
   
   bool macroUp = (tk.bid > emaHTF[0]);
   bool volBuy = (mfiBuf[0] > Inp_MFILimit);
   bool volSell = (mfiBuf[0] < Inp_MFILimit);
   
   if(m_tc.direction == 1 && macroUp && volBuy) 
   {
      double sl = NormalizeDouble(tk.ask - (m_atr * Inp_StopLossATR), _Digits);
      m_trade.Buy(Inp_LotBase, _Symbol, tk.ask, sl, 0, "GOLD_SNIPER_BUY");
   }
   else if(m_tc.direction == -1 && !macroUp && volSell) 
   {
      double sl = NormalizeDouble(tk.bid + (m_atr * Inp_StopLossATR), _Digits);
      m_trade.Sell(Inp_LotBase, _Symbol, tk.bid, sl, 0, "GOLD_SNIPER_SELL");
   }
}

//=================================================================
//  ESCUDO DEFENSIVO (FASE 4) - TICK A TICK
//=================================================================
void ManageDefense()
{
   if(PositionsTotal() == 0 || m_atr <= 0) return;
   MqlTick tk; SymbolInfoTick(_Symbol, tk);
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(m_position.SelectByTicket(ticket) && m_position.Magic() == Inp_Magic)
      {
         double sl = m_position.StopLoss();
         double open = m_position.PriceOpen();
         double pnl = m_position.Profit() + m_position.Swap() + m_position.Commission();
         
         // BREAKEVEN
         if(pnl >= Inp_BreakevenTriggerUSD)
         {
            double beOffset = 20 * _Point; // 20 puntos de margen para el spread del Oro
            if(m_position.PositionType() == POSITION_TYPE_BUY && sl < open)
               m_trade.PositionModify(ticket, NormalizeDouble(open + beOffset, _Digits), 0);
            else if(m_position.PositionType() == POSITION_TYPE_SELL && (sl > open || sl == 0))
               m_trade.PositionModify(ticket, NormalizeDouble(open - beOffset, _Digits), 0);
         }
         
         // TRAILING STOP
         double actDist = m_atr * Inp_TrailingStartATR;
         double step = m_atr * Inp_TrailingStepATR;
         
         if(m_position.PositionType() == POSITION_TYPE_BUY && (tk.bid - open > actDist))
         {
            double newSL = NormalizeDouble(tk.bid - step, _Digits);
            if(newSL > sl) m_trade.PositionModify(ticket, newSL, 0);
         }
         else if(m_position.PositionType() == POSITION_TYPE_SELL && (open - tk.ask > actDist))
         {
            double newSL = NormalizeDouble(tk.ask + step, _Digits);
            if(newSL < sl || sl == 0) m_trade.PositionModify(ticket, newSL, 0);
         }
      }
   }
}

//=================================================================
//  NÚCLEO DE EJECUCIÓN (MAIN LOOP)
//=================================================================
void OnTick()
{
   // 1. Prioridad Máxima: Gestión de Cierres de Fin de Día
   RunEODProtocol();
   
   // 2. Prioridad de Defensa: Blindar ganancias tick a tick
   ManageDefense();
   
   // 3. Prioridad de Caza: Evaluar nuevas entradas solo al cierre de vela y en horario
   if(IsNewBar() && IsHuntingZone())
   {
      UpdateTEMA();
      SniperEntry();
   }
}
//+------------------------------------------------------------------+