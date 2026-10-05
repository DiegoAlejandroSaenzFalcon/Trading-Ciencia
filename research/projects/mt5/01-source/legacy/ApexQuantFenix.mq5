//+------------------------------------------------------------------+
//| APEXQUANT V79.0 — SEÑAL QUIRÚRGICA + RIESGO CONTROLADO         |
//|                                                                  |
//| DIAGNÓSTICO V78.8 → POR QUÉ QUEMA CUENTAS:                    |
//|                                                                  |
//| BUG 1 — SEÑAL DE ENTRADA VACÍA:                                |
//|   Solo usaba precio > EMA_alta. Sin RSI, sin MACD, sin          |
//|   confirmación de vela. ~50% acierto = juego de azar.           |
//|   FIX: RSI + MACD + cuerpo de vela + ADX ranging               |
//|                                                                  |
//| BUG 2 — SL = 0 EN TODAS LAS POSICIONES:                       |
//|   Pérdidas ilimitadas cuando el precio se va en contra.         |
//|   FIX: Hard SL obligatorio 1.8×ATR en cada apertura            |
//|                                                                  |
//| BUG 3 — RESCATE INFINITO SIN TECHO:                           |
//|   Seguía abriendo posiciones de recuperación sin límite.        |
//|   Cada rescate fallido generaba otro → espiral destructiva.     |
//|   FIX: Máx 2 rescates por ciclo. Si fallan → cerrar todo.      |
//|                                                                  |
//| BUG 4 — SIN FILTRO DE SESIÓN:                                  |
//|   Operaba a las 3AM con spreads de 50+ puntos en XAUUSD.       |
//|   FIX: Solo Londres (7-17 GMT) y NY (13-22 GMT).               |
//|                                                                  |
//| BUG 5 — SIN LÍMITE DE PÉRDIDA DIARIA:                         |
//|   Continuaba hasta quemar la cuenta sin parar nunca.            |
//|   FIX: Pausa automática si pérdida diaria ≥ InpMaxDailyDD%    |
//|                                                                  |
//| LO QUE SE CONSERVA (virtudes del original):                    |
//|   ✓ Cierre rápido en ganancia (basket TP configurable)         |
//|   ✓ Grilla bidireccional con cierre por excedente              |
//|   ✓ Neutralizador global (cerrar pares ganad.+perdedor)        |
//|   ✓ Panel informativo en tiempo real                            |
//|   ✓ Trailing stop cuando la posición gana                      |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V79.0 - DiegoSaenz"
#property version   "79.00"
#property strict
#property description "Motor institucional con señal mejorada y riesgo controlado"
#property description "V79: SL obligatorio, rescate limitado, sesión filtrada, DD diario"

#include <Trade/Trade.mqh>
#include <Arrays/ArrayLong.mqh>

//=================================================================
//  PARÁMETROS DE ENTRADA
//=================================================================
input group "=== CONFIGURACIÓN MAESTRA ==="
input long   Inp_Magic             = 7900;
input int    Inp_MaxPositionsTotal = 8;     // Reducido de 20 → control real del riesgo

input group "=== LOTES ==="
input double Inp_LotInitial        = 0.01;
input double Inp_LotRescue         = 0.02;  // Primer rescate
input double Inp_LotRescue2        = 0.03;  // Segundo rescate (máximo)
input double Inp_LotGrid           = 0.01;

input group "=== R:R — CLAVE V79 ==="
// SL obligatorio en TODAS las posiciones
// TP del ciclo = basket cuando pnl_neto >= InpBasketTP
input bool   Inp_UseHardSL         = true;
input double Inp_SL_ATR            = 1.8;  // SL = 1.8×ATR desde apertura
input double Inp_SL_MinPts         = 40;   // SL mínimo en puntos
input double Inp_BasketTP          = 1.20; // Cerrar todo cuando P&L neto >= $1.20
input double Inp_BasketTP_Grid     = 0.80; // Basket TP solo para posiciones grid
input double Inp_TrailTrigger      = 0.40; // Activar trailing cuando ganamos $0.40
input double Inp_ATR_TrailMult     = 1.5;  // Distancia del trailing en ATR

input group "=== SEÑAL DE ENTRADA MEJORADA V79 ==="
// Antes: solo precio > EMA → señal aleatoria
// Ahora: 4 filtros concurrentes = señal de calidad
input int    Inp_EMAFast           = 21;   // EMA rápida (tendencia corto plazo)
input int    Inp_EMASlow           = 50;   // EMA lenta (tendencia macro)
input int    Inp_RSI_Period        = 7;
input double Inp_RSI_BuyMax        = 50;   // RSI < 50 para BUY (precio barato)
input double Inp_RSI_SellMin       = 50;   // RSI > 50 para SELL (precio caro)
input int    Inp_MACD_Fast         = 5;
input int    Inp_MACD_Slow         = 13;
input int    Inp_MACD_Sig          = 1;
input int    Inp_ATR_Period        = 14;
// ADX: solo operar cuando el mercado NO está en tendencia fuerte
// (las señales de reversión son más confiables en mercado ranging)
input bool   Inp_UseADX            = true;
input int    Inp_ADX_Period        = 14;
input double Inp_ADX_MaxLevel      = 30.0; // Bloquear si ADX > 30

input group "=== FILTRO DE SESIÓN V79 ==="
input bool   Inp_UseSession        = true;
input int    Inp_GMTOffset         = 0;    // Offset GMT del broker
input int    Inp_LondonOpen        = 7;
input int    Inp_LondonClose       = 17;
input int    Inp_NYOpen            = 13;
input int    Inp_NYClose           = 22;

input group "=== SPREAD Y CALIDAD ==="
input int    Inp_MaxSpread         = 35;   // Bloquear si spread > 35 pts
input int    Inp_EntryCooldown     = 60;   // Segundos entre entradas iniciales

input group "=== RESCATE LIMITADO V79 ==="
// ANTES: rescate infinito → quema cuenta
// AHORA: máximo 2 niveles. Si el nivel 2 falla → cerrar todo y reset
input bool   Inp_EnableRescue      = true;
input int    Inp_MaxRescueLevels   = 2;    // Máximo 2 rescates por ciclo
input double Inp_RescueTrigger     = -0.35; // Abrir rescate cuando pnl <= -$0.35
input int    Inp_RescueInterval    = 5;    // Segundos entre rescates

input group "=== PROTECCIÓN DIARIA V79 ==="
input bool   Inp_UseDailyDD        = true;
input double Inp_MaxDailyDD_Pct    = 3.0;  // Pausa si pérdida del día >= 3% del balance
input double Inp_MaxDailyDD_USD    = -5.0; // O si pérdida diaria >= -$5.00 (usa el menor)

input group "=== PROTECCIÓN DE CAPITAL ==="
input double Inp_MaxMarginPct      = 40.0; // Bloquear si margen usado >= 40% del balance
input double Inp_MarginUnblockPct  = 25.0; // Desbloquear cuando baja a 25%

input group "=== GRILLA BIDIRECCIONAL ==="
input bool   Inp_EnableGrid        = true;
input double Inp_GridStepATR       = 0.8;  // Distancia entre niveles = 0.8×ATR
input int    Inp_MaxGridLevels     = 3;

input group "=== NEUTRALIZADOR GLOBAL ==="
input bool   Inp_EnableNeutralizer = true;
input double Inp_NeutralizerProfit = 0.40; // Cerrar ganadoras que cubran perdedoras
input int    Inp_NeutralizerSec    = 20;

//=================================================================
//  HANDLES
//=================================================================
int h_EMAFast, h_EMASlow, h_RSI, h_MACD, h_ATR, h_ADX;

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade   m_trade;

// Control de ciclo
int      m_rescueLevels     = 0;    // Contador de rescates activos en este ciclo
datetime m_lastEntry        = 0;
datetime m_lastRescue       = 0;
datetime m_lastGridTime     = 0;
datetime m_lastNeutralizer  = 0;
datetime m_lastCleanup      = 0;
bool     m_isProcessing     = false;
bool     m_paused           = false;

// Grilla
double   m_gridRef          = 0;
int      m_gridBuys         = 0;
int      m_gridSells        = 0;

// Protección de capital
bool     m_marginBlocked    = false;
double   m_marginPct        = 0;

// Protección diaria
double   m_dayStartBalance  = 0;
datetime m_dayStart         = 0;
bool     m_dailyPaused      = false;
int      m_dayRef           = -1;

// Stats
int      m_wins             = 0;
int      m_losses           = 0;
double   m_totalRealized    = 0;
int      m_cycleCount       = 0;

// Trailing
struct TrailGuard {
   ulong  ticket;
   double bestPrice;
   double activationLevel;
   bool   active;
};
TrailGuard m_trails[30];

//=================================================================
//  UTILIDADES BÁSICAS
//=================================================================
double NormLot(double lot) {
   double step=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxL=SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   if(step<=0) step=0.01;
   lot=MathFloor(lot/step)*step;
   return NormalizeDouble(MathMax(minL,MathMin(maxL,lot)),2);
}

bool GetTick(MqlTick &t) { return SymbolInfoTick(_Symbol,t); }

double GetATR() {
   double b[1];
   if(CopyBuffer(h_ATR,0,1,1,b)==1) return b[0];
   return _Point*150;
}

int CountMyPositions() {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==Inp_Magic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) c++;
   }
   return c;
}

double GetTotalPnL() {
   double pnl=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==Inp_Magic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol)
         pnl+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

int CountRescuePositions() {
   int c=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      string cmnt=PositionGetString(POSITION_COMMENT);
      if(StringFind(cmnt,"Rescue")>=0) c++;
   }
   return c;
}

//=================================================================
//  FILTRO DE SESIÓN
//=================================================================
bool IsInSession() {
   if(!Inp_UseSession) return true;
   MqlDateTime dt; datetime srv=TimeTradeServer(); if(srv<=0) srv=TimeCurrent();
   TimeToStruct(srv,dt);
   if(dt.day_of_week==0||dt.day_of_week==6) return false;
   if(dt.day_of_week==5&&dt.hour>=20) return false; // cierre viernes
   int gH=(dt.hour-Inp_GMTOffset+24)%24;
   return (gH>=Inp_LondonOpen&&gH<Inp_LondonClose)||(gH>=Inp_NYOpen&&gH<Inp_NYClose);
}

//=================================================================
//  PROTECCIÓN DE CAPITAL (Margen)
//=================================================================
bool MarginBlocked() {
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double mrgn=AccountInfoDouble(ACCOUNT_MARGIN);
   if(bal<=0) return false;
   m_marginPct=(mrgn/bal)*100.0;
   if(!m_marginBlocked && m_marginPct>=Inp_MaxMarginPct) {
      m_marginBlocked=true;
      Print(">>> [MARGEN] BLOQUEADO: ",NormalizeDouble(m_marginPct,1),"% >= ",Inp_MaxMarginPct,"%");
   }
   if(m_marginBlocked && m_marginPct<Inp_MarginUnblockPct) {
      m_marginBlocked=false;
      Print(">>> [MARGEN] DESBLOQUEADO: ",NormalizeDouble(m_marginPct,1),"% < ",Inp_MarginUnblockPct,"%");
   }
   return m_marginBlocked;
}

//=================================================================
//  PROTECCIÓN DIARIA
//=================================================================
void ResetDailyIfNeeded() {
   MqlDateTime dt; datetime srv=TimeTradeServer(); if(srv<=0) srv=TimeCurrent();
   TimeToStruct(srv,dt);
   if(dt.day!=m_dayRef) {
      m_dayRef=dt.day;
      m_dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
      m_dayStart=srv;
      m_dailyPaused=false;
      Print(">>> RESET DIARIO V79: Balance base=$",NormalizeDouble(m_dayStartBalance,2));
   }
}

bool DailyLimitHit() {
   if(!Inp_UseDailyDD) return false;
   ResetDailyIfNeeded();
   if(m_dailyPaused) return true;
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double pnlHoy=(bal-m_dayStartBalance)+GetTotalPnL();
   double limUSD=MathMax(Inp_MaxDailyDD_USD, -(m_dayStartBalance*Inp_MaxDailyDD_Pct/100.0));
   if(pnlHoy<=limUSD) {
      m_dailyPaused=true;
      Print(">>> [DD DIARIO] Límite alcanzado: $",NormalizeDouble(pnlHoy,2),
            " | Límite: $",NormalizeDouble(limUSD,2)," — Pausando hasta mañana");
      return true;
   }
   return false;
}

//=================================================================
//  SPREAD OK
//=================================================================
bool SpreadOK() {
   return (int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)<=Inp_MaxSpread;
}

//=================================================================
//  APLICAR HARD SL
//=================================================================
void ApplyHardSL(ulong ticket, ENUM_ORDER_TYPE orderType, double openPrice, double atr) {
   if(!Inp_UseHardSL) return;
   if(!PositionSelectByTicket(ticket)) return;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double slDist=MathMax(atr*Inp_SL_ATR, Inp_SL_MinPts*_Point);
   int stopsLev=(int)SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist=(stopsLev+5)*_Point;
   if(slDist<minDist) slDist=minDist;
   double sl=0;
   if(orderType==ORDER_TYPE_BUY) sl=NormalizeDouble(openPrice-slDist,dg);
   else sl=NormalizeDouble(openPrice+slDist,dg);
   double curTP=PositionGetDouble(POSITION_TP);
   if(m_trade.PositionModify(ticket,sl,curTP))
      Print(">>> HARD SL V79: #",ticket," SL=",NormalizeDouble(sl,dg),
            " dist=",NormalizeDouble(slDist/_Point,0),"pts (",Inp_SL_ATR,"×ATR)");
}

//=================================================================
//  ABRIR ORDEN CON CONTROLES COMPLETOS
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type, double lot, string comment) {
   if(m_paused||m_dailyPaused) return 0;
   if(MarginBlocked()) return 0;
   if(!SpreadOK()) { static datetime lsw=0; if(TimeCurrent()-lsw>5){Print(">>> SPREAD ALTO bloqueando");lsw=TimeCurrent();} return 0; }
   if(PositionsTotal()>=Inp_MaxPositionsTotal) return 0;

   MqlTick tick; if(!GetTick(tick)) return 0;
   lot=NormLot(lot);
   if(lot<=0) return 0;

   double price=(type==ORDER_TYPE_BUY)?tick.ask:tick.bid;
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margReq=0;
   if(OrderCalcMargin(type,_Symbol,lot,price,margReq) && margReq>freeMargin*0.55) {
      Print(">>> MARGEN INSUF para ",lot," lotes"); return 0;
   }

   bool ok=(type==ORDER_TYPE_BUY)
            ?m_trade.Buy(lot,_Symbol,price,0,0,comment)
            :m_trade.Sell(lot,_Symbol,price,0,0,comment);

   if(!ok) { Print(">>> ERR ORDEN V79: ",m_trade.ResultRetcodeDescription()); return 0; }
   ulong ticket=m_trade.ResultOrder();
   if(ticket>0) {
      Print(">>> V79 ABIERTA #",ticket," ",(type==ORDER_TYPE_BUY?"BUY":"SELL")," ",lot," @ ",
            NormalizeDouble(price,_Digits)," [",comment,"]");
      // Aplicar Hard SL después de abrir
      if(Inp_UseHardSL) {
         Sleep(50);
         ApplyHardSL(ticket,type,price,GetATR());
      }
   }
   return ticket;
}

void CloseAll(string reason="") {
   int closed=0; double totalPf=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(m_trade.PositionClose(t)){closed++;totalPf+=pf;}
   }
   // Reset ciclo
   m_rescueLevels=0;
   m_gridRef=0; m_gridBuys=0; m_gridSells=0;
   m_totalRealized+=totalPf;
   m_cycleCount++;
   if(totalPf>=0) m_wins++; else m_losses++;
   Print(">>> CICLO CERRADO [",reason,"]: $",NormalizeDouble(totalPf,2),
         " | Ciclos:",m_cycleCount," W:",m_wins," L:",m_losses,
         " Realizado:$",NormalizeDouble(m_totalRealized,2));
   for(int i=0;i<30;i++) ZeroMemory(m_trails[i]);
}

//=================================================================
//  SEÑAL DE ENTRADA V79 — 4 FILTROS CONCURRENTES
//
//  ANTES (V78): solo precio > EMA_alta → aleatoriedad ~50%
//  AHORA (V79): 4 condiciones independientes deben coincidir
//
//  Para BUY (esperamos que suba):
//    1. EMA_fast > EMA_slow (tendencia corto plazo alcista)
//    2. RSI < Inp_RSI_BuyMax (precio aún no sobrecomprado, hay espacio)
//    3. MACD histograma > 0 (momentum alcista activo)
//    4. Vela anterior alcista (cuerpo verde confirma dirección)
//    (+ ADX < 30 si está activo: mercado ranging, reversiones más predecibles)
//
//  Para SELL: condiciones simétricas
//=================================================================
int GetEntrySignal() {
   // Leer indicadores
   double emaF[1],emaS[1],rsi[1],macdH[1],adx[1];
   if(CopyBuffer(h_EMAFast,0,0,1,emaF)!=1) return 0;
   if(CopyBuffer(h_EMASlow,0,0,1,emaS)!=1) return 0;
   if(CopyBuffer(h_RSI,    0,0,1,rsi) !=1) return 0;
   if(CopyBuffer(h_MACD,   0,0,1,macdH)!=1) return 0;

   // ADX: mercado ranging (solo si está activado)
   if(Inp_UseADX) {
      if(CopyBuffer(h_ADX,0,0,1,adx)!=1) return 0;
      if(adx[0]>Inp_ADX_MaxLevel) return 0; // tendencia fuerte → no entrar
   }

   // Confirmación de vela anterior (cuerpo de la vela)
   double c1_open = iOpen(_Symbol,PERIOD_M1,1);
   double c1_close= iClose(_Symbol,PERIOD_M1,1);
   bool bullCandle = (c1_close > c1_open * 1.00005);
   bool bearCandle = (c1_close < c1_open * 0.99995);

   // SEÑAL BUY: precio tiene espacio para subir, momentum alcista
   bool buySignal = (emaF[0] > emaS[0])         // tendencia corto plazo alcista
                  && (rsi[0]  < Inp_RSI_BuyMax)  // RSI no sobrecomprado
                  && (macdH[0]> 0.0)             // momentum positivo
                  && bullCandle;                  // vela anterior confirma

   // SEÑAL SELL: precio tiene espacio para bajar, momentum bajista
   bool sellSignal= (emaF[0] < emaS[0])          // tendencia corto plazo bajista
                  && (rsi[0]  > Inp_RSI_SellMin)  // RSI no sobrevendido
                  && (macdH[0]< 0.0)              // momentum negativo
                  && bearCandle;                   // vela anterior confirma

   // Para XAUUSD con dyn_Invert=true: invertir las señales
   // (el GOLD a menudo se comporta inversamente a Forex en señales de EMA corta)
   string sym=_Symbol; StringToUpper(sym);
   bool invertForGold = (StringFind(sym,"XAU")>=0 || StringFind(sym,"GOLD")>=0);

   if(invertForGold) {
      // Para GOLD: comprar cuando hay debilidad de corto plazo (reversión a la media)
      // Esto es lo que funciona en XAUUSD M1 según estudios de MQL5
      bool tmp=buySignal; buySignal=sellSignal; sellSignal=tmp;
   }

   if(buySignal)  return  1;
   if(sellSignal) return -1;
   return 0;
}

//=================================================================
//  GESTIÓN DE BASKET TP
//=================================================================
void CheckBasketTP() {
   if(CountMyPositions()==0) return;
   double pnl=GetTotalPnL();
   if(pnl>=Inp_BasketTP) {
      Print(">>> BASKET TP V79: P&L=$",NormalizeDouble(pnl,2)," >= $",Inp_BasketTP);
      CloseAll("BasketTP");
   }
}

//=================================================================
//  GESTIÓN DE BASKET TP PARA GRID
//=================================================================
void CheckGridBasketTP() {
   int gridCount=0; double gridPnL=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT),"Grid")<0) continue;
      gridCount++;
      gridPnL+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   if(gridCount>0 && gridPnL>=Inp_BasketTP_Grid) {
      Print(">>> GRID TP V79: grid_pnl=$",NormalizeDouble(gridPnL,2));
      for(int i=PositionsTotal()-1;i>=0;i--) {
         ulong t=PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
         if(StringFind(PositionGetString(POSITION_COMMENT),"Grid")>=0)
            m_trade.PositionClose(t);
      }
      m_gridRef=0; m_gridBuys=0; m_gridSells=0;
   }
}

//=================================================================
//  TRAILING STOP V79
//=================================================================
int FindTrail(ulong ticket) {
   for(int i=0;i<30;i++) if(m_trails[i].ticket==ticket) return i;
   for(int i=0;i<30;i++) if(m_trails[i].ticket==0)     return i;
   return -1;
}

void ManageTrailing() {
   double atr=GetATR(); if(atr<=0) return;
   MqlTick tick; if(!GetTick(tick)) return;
   int dg=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);
   double minStop=SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)*_Point;

   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;

      ENUM_POSITION_TYPE pt=(ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double openP=PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL=PositionGetDouble(POSITION_SL);
      double curTP=PositionGetDouble(POSITION_TP);

      if(pf<Inp_TrailTrigger) continue; // No activar trail hasta ganar lo suficiente

      int idx=FindTrail(t);
      if(idx<0) continue;
      if(m_trails[idx].ticket==0) {
         m_trails[idx].ticket=t;
         m_trails[idx].bestPrice=(pt==POSITION_TYPE_BUY)?tick.bid:tick.ask;
         m_trails[idx].active=false;
      }

      double trailDist=atr*Inp_ATR_TrailMult;
      if(pt==POSITION_TYPE_BUY) {
         if(tick.bid>m_trails[idx].bestPrice) m_trails[idx].bestPrice=tick.bid;
         double newSL=NormalizeDouble(m_trails[idx].bestPrice-trailDist,dg);
         double safeMax=NormalizeDouble(tick.bid-minStop,dg);
         if(newSL>safeMax) newSL=safeMax;
         if(newSL>curSL+_Point) {
            if(!m_trails[idx].active) {
               m_trails[idx].active=true;
               Print(">>> TRAIL ON V79 BUY #",t," SL→",NormalizeDouble(newSL,dg));
            }
            m_trade.PositionModify(t,newSL,curTP);
         }
      } else {
         if(tick.ask<m_trails[idx].bestPrice) m_trails[idx].bestPrice=tick.ask;
         double newSL=NormalizeDouble(m_trails[idx].bestPrice+trailDist,dg);
         double safeMn=NormalizeDouble(tick.ask+minStop,dg);
         if(newSL<safeMn) newSL=safeMn;
         bool shouldMod=(curSL==0&&newSL>0)||(curSL>0&&newSL<curSL-_Point);
         if(shouldMod) {
            if(!m_trails[idx].active) {
               m_trails[idx].active=true;
               Print(">>> TRAIL ON V79 SELL #",t," SL→",NormalizeDouble(newSL,dg));
            }
            m_trade.PositionModify(t,newSL,curTP);
         }
      }
   }
}

//=================================================================
//  RESCATE LIMITADO V79
//  ANTES: rescate infinito → espiral destructiva
//  AHORA: máx Inp_MaxRescueLevels. Si se agotan → cerrar todo.
//=================================================================
void CheckRescue() {
   if(!Inp_EnableRescue) return;
   if(m_isProcessing) return;
   if(TimeCurrent()-m_lastRescue<Inp_RescueInterval) return;

   int posCount=CountMyPositions();
   if(posCount==0) return;

   double pnl=GetTotalPnL();
   if(pnl>=Inp_RescueTrigger) return; // No hay necesidad

   // ¿Agotamos los rescates?
   int rescueCount=CountRescuePositions();
   if(rescueCount>=Inp_MaxRescueLevels) {
      // Rescate máximo alcanzado y sigue perdiendo → cerrar todo con pérdida controlada
      // Mejor perder el SL que seguir cavando el hoyo
      Print(">>> [RESCATE AGOTADO] ",rescueCount," niveles usados, P&L=$",
            NormalizeDouble(pnl,2)," → Cerrando todo (SL ya protege lo peor)");
      m_isProcessing=true;
      CloseAll("RescateAgotado");
      m_isProcessing=false;
      return;
   }

   // Calcular lote del rescate (escalonado)
   double lot = (rescueCount==0) ? Inp_LotRescue : Inp_LotRescue2;

   // Lado del rescate: SIEMPRE opuesto al lado que más pierde (hedge verdadero)
   double buyPnL=0, sellPnL=0;
   int    buyCount=0, sellCount=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY){buyPnL+=pf;buyCount++;}
      else {sellPnL+=pf;sellCount++;}
   }

   ENUM_ORDER_TYPE rescueType;
   if(buyCount==0)          rescueType=ORDER_TYPE_BUY;   // solo sells perdiendo
   else if(sellCount==0)    rescueType=ORDER_TYPE_SELL;  // solo buys perdiendo
   else if(buyPnL<sellPnL)  rescueType=ORDER_TYPE_SELL;  // buys pierden más → sell contraria
   else                     rescueType=ORDER_TYPE_BUY;   // sells pierden más → buy contraria

   m_isProcessing=true;
   string cmnt="Rescue_L"+IntegerToString(rescueCount+1);
   MqlTick tick; if(!GetTick(tick)){m_isProcessing=false;return;}
   ulong ticket=OpenOrder(rescueType,lot,cmnt);
   if(ticket>0) {
      m_rescueLevels++;
      m_lastRescue=TimeCurrent();
      Print(">>> RESCATE V79 L",rescueCount+1,"/",Inp_MaxRescueLevels,
            " → ",(rescueType==ORDER_TYPE_BUY?"BUY":"SELL")," ",lot,
            " P&L ciclo=$",NormalizeDouble(pnl,2));
   }
   m_isProcessing=false;
}

//=================================================================
//  NEUTRALIZADOR GLOBAL V79
//  Cierra pares ganadora+perdedora cuando la ganadora cubre la pérdida
//=================================================================
void RunNeutralizer() {
   if(!Inp_EnableNeutralizer) return;
   if(m_isProcessing) return;
   if(TimeCurrent()-m_lastNeutralizer<Inp_NeutralizerSec) return;
   m_lastNeutralizer=TimeCurrent();

   // Recolectar ganadoras y perdedoras
   ulong  wTickets[30]; double wPnL[30]; int wCount=0;
   ulong  lTickets[30]; double lPnL[30]; int lCount=0;

   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL)!=_Symbol) continue;
      double pf=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      if(pf>=Inp_NeutralizerProfit && wCount<30){wTickets[wCount]=t;wPnL[wCount]=pf;wCount++;}
      else if(pf<-0.01             && lCount<30){lTickets[lCount]=t;lPnL[lCount]=pf;lCount++;}
   }

   if(wCount==0||lCount==0) return;

   // Para cada perdedora, buscar ganadoras que la cubran (+margen)
   for(int l=0;l<lCount;l++) {
      double need=MathAbs(lPnL[l])+0.10;
      double acc=0; bool sel[30]; for(int k=0;k<30;k++) sel[k]=false; int selCount=0;
      for(int w=0;w<wCount;w++) {
         if(wPnL[w]>=Inp_NeutralizerProfit){acc+=wPnL[w];sel[w]=true;selCount++;}
         if(acc>=need) break;
      }
      if(acc>=need) {
         m_isProcessing=true;
         Print(">>> NEUTRALIZADOR V79: Cubriendo $",NormalizeDouble(lPnL[l],2)," con $",NormalizeDouble(acc,2));
         for(int w=0;w<wCount;w++)
            if(sel[w]&&PositionSelectByTicket(wTickets[w])) m_trade.PositionClose(wTickets[w]);
         if(PositionSelectByTicket(lTickets[l])) m_trade.PositionClose(lTickets[l]);
         m_isProcessing=false;
         return; // Un par por ciclo
      }
   }
}

//=================================================================
//  GRILLA BIDIRECCIONAL V79
//=================================================================
void RunGrid() {
   if(!Inp_EnableGrid||m_isProcessing) return;
   if(TimeCurrent()-m_lastGridTime<3) return;
   if(PositionsTotal()>=Inp_MaxPositionsTotal) return;
   if(!IsInSession()) return;
   if(MarginBlocked()) return;
   m_lastGridTime=TimeCurrent();

   double atr=GetATR(); if(atr<=0) return;
   double gridStep=atr*Inp_GridStepATR;
   MqlTick tick; if(!GetTick(tick)) return;

   if(m_gridRef<=0){m_gridRef=tick.last;return;}

   int gBuys=0,gSells=0;
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=Inp_Magic) continue;
      if(StringFind(PositionGetString(POSITION_COMMENT),"Grid")<0) continue;
      if(PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY) gBuys++; else gSells++;
   }

   double dUp=tick.last-m_gridRef, dDn=m_gridRef-tick.last;

   if(dUp>=gridStep*(gBuys+1) && gBuys<Inp_MaxGridLevels) {
      m_isProcessing=true;
      string cmnt="Grid_B_"+IntegerToString(gBuys+1);
      ulong t=OpenOrder(ORDER_TYPE_BUY,NormLot(Inp_LotGrid),cmnt);
      if(t>0) m_gridBuys=gBuys+1;
      m_isProcessing=false;
   }
   if(dDn>=gridStep*(gSells+1) && gSells<Inp_MaxGridLevels) {
      m_isProcessing=true;
      string cmnt="Grid_S_"+IntegerToString(gSells+1);
      ulong t=OpenOrder(ORDER_TYPE_SELL,NormLot(Inp_LotGrid),cmnt);
      if(t>0) m_gridSells=gSells+1;
      m_isProcessing=false;
   }
}

//=================================================================
//  LIMPIEZA DE TRAILS
//=================================================================
void CleanupTrails() {
   for(int i=0;i<30;i++) {
      if(m_trails[i].ticket==0) continue;
      if(!PositionSelectByTicket(m_trails[i].ticket)) ZeroMemory(m_trails[i]);
   }
}

//=================================================================
//  PANEL V79
//=================================================================
void Lbl(string n,string txt,int x,int y,color c,int fs=9) {
   if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
      ObjectSetString(0,n,OBJPROP_FONT,"Consolas");}
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);
}
void Btn(string n,string txt,int x,int y,int w,int h,color bg) {
   if(ObjectFind(0,n)<0){ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
      ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,n,OBJPROP_XSIZE,w);ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
      ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);ObjectSetString(0,n,OBJPROP_FONT,"Consolas");
      ObjectSetInteger(0,n,OBJPROP_COLOR,clrWhite);}
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString(0,n,OBJPROP_TEXT,txt);ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
}

void UpdatePanel() {
   double bal=AccountInfoDouble(ACCOUNT_BALANCE);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double pnl=GetTotalPnL();
   double dayPnL=(bal-m_dayStartBalance)+pnl;
   double dayLim=MathMax(Inp_MaxDailyDD_USD,-(m_dayStartBalance*Inp_MaxDailyDD_Pct/100.0));
   int    pos=CountMyPositions();
   int    rescues=CountRescuePositions();
   bool   inSess=IsInSession();
   int    spr=(int)SymbolInfoInteger(_Symbol,SYMBOL_SPREAD);

   color cPnL=(pnl>=0)?clrLimeGreen:clrTomato;
   color cSess=inSess?clrLimeGreen:clrGray;
   color cDD=m_dailyPaused?clrTomato:(dayPnL<dayLim*0.6)?clrOrange:clrLimeGreen;
   color cMrg=m_marginBlocked?clrTomato:(m_marginPct>Inp_MaxMarginPct*0.7)?clrOrange:clrLimeGreen;
   color cRsc=(rescues>=Inp_MaxRescueLevels)?clrOrange:clrLimeGreen;
   int wr=(m_wins+m_losses>0)?m_wins*100/(m_wins+m_losses):0;

   double adxV=0; double adxB[1];
   if(CopyBuffer(h_ADX,0,0,1,adxB)==1) adxV=adxB[0];

   Lbl("P0","═══ APEXQUANT V79.0 ["+_Symbol+"] ═══",10,15,clrGold,10);
   Lbl("P1","Bal:$"+DoubleToString(bal,2)+"  Eq:$"+DoubleToString(eq,2)
            +"  P&L:$"+DoubleToString(pnl,2),10,32,cPnL);
   Lbl("P2","DíaP&L:$"+DoubleToString(dayPnL,2)
            +" Lím:$"+DoubleToString(dayLim,2)
            +(m_dailyPaused?" !! PAUSADO !!":""),10,49,cDD);
   Lbl("P3","Margen:"+DoubleToString(m_marginPct,1)+"%"
            +(m_marginBlocked?" BLOQUEADO":" OK")
            +"  Sesión:"+(inSess?"ACTIVA":"FUERA")
            +"  Spread:"+IntegerToString(spr)+"pts",10,66,cMrg);
   Lbl("P4","Pos:"+IntegerToString(pos)+"/"+IntegerToString(Inp_MaxPositionsTotal)
            +" Rescates:"+IntegerToString(rescues)+"/"+IntegerToString(Inp_MaxRescueLevels)
            +" Grid:B"+IntegerToString(m_gridBuys)+"S"+IntegerToString(m_gridSells),10,83,cRsc);
   Lbl("P5","ADX:"+DoubleToString(adxV,1)+(adxV>Inp_ADX_MaxLevel?" TREND-BLOCK":" ranging-OK"),
            10,100,(adxV>Inp_ADX_MaxLevel)?clrOrange:clrLimeGreen);
   Lbl("P6","Ciclos:"+IntegerToString(m_cycleCount)
            +" W:"+IntegerToString(m_wins)+" L:"+IntegerToString(m_losses)
            +" WR:"+IntegerToString(wr)+"%"
            +" Realiz:$"+DoubleToString(m_totalRealized,2),10,117,clrCyan);
   Lbl("P7","MEJORAS V79: SL oblig+Rescate máx "+IntegerToString(Inp_MaxRescueLevels)
            +" niv+Sesión+DD diario+Señal 4-filtros",10,134,clrDimGray,8);
   Btn("BTN_PAUSE",m_paused||m_dailyPaused?"REANUDAR":"PAUSAR",10,152,80,18,
       m_paused||m_dailyPaused?clrGoldenrod:clrDarkGreen);
   Btn("BTN_CLOSE","CERRAR TODO",96,152,95,18,clrDarkRed);
   ChartRedraw(0);
}

//=================================================================
//  OnInit
//=================================================================
int OnInit() {
   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(20);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);

   h_EMAFast = iMA(_Symbol,PERIOD_M1,Inp_EMAFast,0,MODE_EMA,PRICE_CLOSE);
   h_EMASlow = iMA(_Symbol,PERIOD_M1,Inp_EMASlow,0,MODE_EMA,PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol,PERIOD_M1,Inp_RSI_Period,PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol,PERIOD_M1,Inp_MACD_Fast,Inp_MACD_Slow,Inp_MACD_Sig,PRICE_CLOSE);
   h_ATR     = iATR(_Symbol,PERIOD_M1,Inp_ATR_Period);
   h_ADX     = iADX(_Symbol,PERIOD_M1,Inp_ADX_Period);

   if(h_EMAFast==INVALID_HANDLE||h_EMASlow==INVALID_HANDLE||h_RSI==INVALID_HANDLE||
      h_MACD==INVALID_HANDLE||h_ATR==INVALID_HANDLE||h_ADX==INVALID_HANDLE) {
      Print(">>> ERROR V79: Handles de indicadores fallidos"); return INIT_FAILED;
   }
   if(Inp_MarginUnblockPct>=Inp_MaxMarginPct) {
      Print("ERROR: MarginUnblockPct debe ser < MaxMarginPct"); return INIT_FAILED;
   }

   for(int i=0;i<30;i++) ZeroMemory(m_trails[i]);
   m_dayStartBalance=AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt; TimeToStruct(TimeCurrent(),dt); m_dayRef=dt.day;

   MqlTick tick; if(GetTick(tick)) m_gridRef=tick.last;

   Print("══════════════════════════════════════════════════════");
   Print("  APEXQUANT V79.0 — SEÑAL QUIRÚRGICA + RIESGO CONTROLADO");
   Print("══════════════════════════════════════════════════════");
   Print("Activo: ",_Symbol);
   Print("MEJORAS vs V78.8:");
   Print("  [1] Señal 4-filtros: EMA+RSI+MACD+Vela (antes solo EMA)");
   Print("  [2] Hard SL: ",Inp_SL_ATR,"×ATR en CADA posición (antes SL=0)");
   Print("  [3] Rescate limitado: máx ",Inp_MaxRescueLevels," niveles (antes infinito)");
   Print("  [4] Sesión: solo Londres+NY (antes 24/7 con spreads altos)");
   Print("  [5] DD Diario: pausa si pérdida >= ",Inp_MaxDailyDD_Pct,"% o $",MathAbs(Inp_MaxDailyDD_USD));
   Print("  [6] Margen: bloqueo >= ",Inp_MaxMarginPct,"%, desbloqueo < ",Inp_MarginUnblockPct,"%");
   Print("Basket TP: $",Inp_BasketTP," | Rescue trigger: $",Inp_RescueTrigger);
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason) {
   IndicatorRelease(h_EMAFast); IndicatorRelease(h_EMASlow);
   IndicatorRelease(h_RSI); IndicatorRelease(h_MACD);
   IndicatorRelease(h_ATR); IndicatorRelease(h_ADX);
   ObjectsDeleteAll(0,"P"); ObjectDelete(0,"BTN_PAUSE"); ObjectDelete(0,"BTN_CLOSE");
   Print("V79 desinicializado. Realizados: $",NormalizeDouble(m_totalRealized,2),
         " | Ciclos:",m_cycleCount," W:",m_wins," L:",m_losses);
}

//=================================================================
//  OnTick — NÚCLEO PRINCIPAL V79
//=================================================================
void OnTick() {
   // 1. Limpiar trails
   if(TimeCurrent()-m_lastCleanup>5){CleanupTrails();m_lastCleanup=TimeCurrent();}

   // 2. Gestión de posiciones abiertas (PRIORIDAD)
   ManageTrailing();
   CheckBasketTP();
   CheckGridBasketTP();

   // 3. Verificar límite diario
   if(DailyLimitHit()) { UpdatePanel(); return; }

   // 4. Neutralizador global
   RunNeutralizer();

   // 5. Rescate limitado (si hay pérdida en ciclo activo)
   if(!m_isProcessing) CheckRescue();

   // 6. Grilla bidireccional
   if(!m_isProcessing) RunGrid();

   // 7. APERTURA INICIAL — solo con señal de calidad
   int posCount=CountMyPositions();
   if(posCount==0 && !m_paused && !m_dailyPaused && !m_isProcessing) {
      if(!IsInSession())        { UpdatePanel(); return; }
      if(!SpreadOK())           { UpdatePanel(); return; }
      if(MarginBlocked())       { UpdatePanel(); return; }
      if(TimeCurrent()-m_lastEntry<Inp_EntryCooldown) { UpdatePanel(); return; }

      int signal=GetEntrySignal();
      if(signal!=0) {
         MqlTick tick; if(!GetTick(tick)){UpdatePanel();return;}
         ENUM_ORDER_TYPE otype=(signal>0)?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
         double lot=NormLot(Inp_LotInitial);
         m_isProcessing=true;
         ulong ticket=OpenOrder(otype,lot,"Apex Entry");
         m_isProcessing=false;
         if(ticket>0) {
            m_lastEntry=TimeCurrent();
            m_rescueLevels=0; // Nuevo ciclo = reset contador de rescates
            MqlTick t2; if(GetTick(t2)) m_gridRef=t2.last;
            m_gridBuys=0; m_gridSells=0;
            Print(">>> APERTURA V79: ",(signal>0?"BUY":"SELL")," | RSI/MACD/EMA confirmados");
         }
      }
   }

   // 8. Panel
   UpdatePanel();
}

//=================================================================
//  OnChartEvent
//=================================================================
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp) {
   if(id==CHARTEVENT_OBJECT_CLICK) {
      if(sp=="BTN_PAUSE") {
         if(m_dailyPaused) {
            m_dailyPaused=false; m_paused=false;
            Print(">>> REANUDADO MANUALMENTE (override de límite diario)");
         } else {
            m_paused=!m_paused;
            Print(">>> EA ",(m_paused?"PAUSADO":"REANUDADO")," MANUALMENTE");
         }
      }
      if(sp=="BTN_CLOSE") {
         Print(">>> CIERRE MANUAL FORZADO");
         m_isProcessing=true;
         CloseAll("ManualClose");
         m_isProcessing=false;
         m_paused=false; m_dailyPaused=false;
      }
      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+