//+------------------------------------------------------------------+
//|  ApexQuant v2.0 — BB + RSI(6) + MACD(5,13,1) CORREGIDO          |
//|                                                                  |
//|  CORRECCIONES vs v1:                                             |
//|  ✅ R:R invertido: TP > SL (antes TP 0.8 < SL 2.0)              |
//|  ✅ Trailing Stop dinámico basado en ATR                         |
//|  ✅ Filtro de tendencia HTF (MA50 en M5)                         |
//|  ✅ Cooldown aumentado (evita overtrading)                       |
//|  ✅ Filtro de spread máximo (evita entrar con spread alto)        |
//|  ✅ Filtro de sesión horaria configurable                        |
//|  ✅ Panel mejorado con estadísticas de R:R y drawdown            |
//+------------------------------------------------------------------+
#property copyright "ApexQuant v2.0"
#property version   "2.00"
#property strict
#include <Trade/Trade.mqh>

//=================================================================
//  GRUPOS DE PARÁMETROS
//=================================================================

input group "=== INDICADORES ==="
input int    Inp_BB_Period    = 20;     // Bollinger periodo
input double Inp_BB_Sigma     = 2.0;   // Bollinger desviación
input int    Inp_RSI_Period   = 6;     // RSI periodo
input double Inp_RSI_Buy      = 40.0;  // RSI máximo para BUY
input double Inp_RSI_Sell     = 60.0;  // RSI mínimo para SELL
input int    Inp_MACD_Fast    = 5;     // MACD EMA rápida
input int    Inp_MACD_Slow    = 13;    // MACD EMA lenta
input int    Inp_MACD_Signal  = 1;     // MACD señal
input int    Inp_ATR_Period   = 10;    // ATR para SL/TP

input group "=== GESTIÓN DE RIESGO (R:R CORREGIDO) ==="
input double Inp_TP_ATR       = 1.8;  // TP = 1.8×ATR  ← AUMENTADO
input double Inp_SL_ATR       = 1.0;  // SL = 1.0×ATR  ← REDUCIDO
// R:R resultante = 1.8:1 | Punto equilibrio = ~36% win rate
input double Inp_RiskPct      = 1.0;  // % balance por trade
input long   Inp_Magic        = 2222; // Número mágico

input group "=== TRAILING STOP ==="
input bool   Inp_Trailing     = true;   // Activar trailing stop
input double Inp_Trail_Start  = 1.0;    // Activar trailing a X×ATR de beneficio
input double Inp_Trail_Step   = 0.5;    // Paso del trailing en ATR

input group "=== FILTRO DE TENDENCIA HTF ==="
input bool   Inp_HTF_Filter   = true;        // Activar filtro tendencia M5
input int    Inp_HTF_MA       = 50;          // Período MA filtro (M5)
input ENUM_MA_METHOD Inp_HTF_Method = MODE_EMA; // Método MA filtro

input group "=== CONTROL ==="
input int    Inp_Cooldown     = 180;   // Segundos entre trades (3 min)
input int    Inp_MaxTrades    = 20;    // Max trades por día
input double Inp_MaxSpread    = 25.0;  // Spread máximo en puntos
input bool   Inp_Panel        = true;  // Mostrar panel

input group "=== FILTRO DE SESIÓN ==="
input bool   Inp_Session      = true;  // Activar filtro horario
input int    Inp_SesStart     = 7;     // Hora inicio (GMT) — apertura Londres
input int    Inp_SesEnd       = 20;    // Hora fin (GMT)   — cierre NY

//=================================================================
//  HANDLES
//=================================================================
int hBB, hRSI, hMACD, hATR, hHTF;

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade   trade;
datetime lastTrade    = 0;
datetime dayRef       = 0;
int      todayTrades  = 0;
int      wins         = 0;
int      losses       = 0;
double   totalProfit  = 0;
double   totalLoss    = 0;
double   peakBalance  = 0;
double   maxDD        = 0;

//=================================================================
//  INICIALIZACIÓN
//=================================================================
int OnInit() {
   trade.SetExpertMagicNumber(Inp_Magic);
   trade.SetDeviationInPoints(300);

   hBB   = iBands(_Symbol,  PERIOD_M1, Inp_BB_Period, 0, Inp_BB_Sigma, PRICE_CLOSE);
   hRSI  = iRSI(_Symbol,    PERIOD_M1, Inp_RSI_Period, PRICE_CLOSE);
   hMACD = iMACD(_Symbol,   PERIOD_M1, Inp_MACD_Fast, Inp_MACD_Slow, Inp_MACD_Signal, PRICE_CLOSE);
   hATR  = iATR(_Symbol,    PERIOD_M1, Inp_ATR_Period);
   hHTF  = iMA(_Symbol,     PERIOD_M5, Inp_HTF_MA, 0, Inp_HTF_Method, PRICE_CLOSE);

   if(hBB==INVALID_HANDLE  || hRSI==INVALID_HANDLE ||
      hMACD==INVALID_HANDLE || hATR==INVALID_HANDLE || hHTF==INVALID_HANDLE) {
      Print("ERROR: Fallo creando indicadores"); return INIT_FAILED;
   }

   peakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dayRef      = TimeCurrent();

   Print("=== ApexQuant v2.0 | ",_Symbol," ===");
   Print("R:R configurado = ",DoubleToString(Inp_TP_ATR/Inp_SL_ATR,2),
         ":1  |  Equilibrio mínimo WR = ",
         DoubleToString(Inp_SL_ATR/(Inp_TP_ATR+Inp_SL_ATR)*100,1),"%");
   return INIT_SUCCEEDED;
}

//=================================================================
//  DESINICIALIZACIÓN
//=================================================================
void OnDeinit(const int reason) {
   IndicatorRelease(hBB);
   IndicatorRelease(hRSI);
   IndicatorRelease(hMACD);
   IndicatorRelease(hATR);
   IndicatorRelease(hHTF);
   ObjectsDeleteAll(0, "AQ_");
}

//=================================================================
//  CÁLCULO DE LOTE POR RIESGO
//=================================================================
double CalcLot(double slDist) {
   if(slDist <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * Inp_RiskPct / 100.0;
   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot  = risk / (slDist * tv / ts);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step > 0) lot = MathFloor(lot / step) * step;
   return MathMax(minL, MathMin(maxL, lot));
}

//=================================================================
//  VERIFICAR POSICIÓN ABIERTA
//=================================================================
bool HasPosition() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC) == Inp_Magic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
   }
   return false;
}

//=================================================================
//  TRAILING STOP DINÁMICO
//=================================================================
void ManageTrailing(double atr) {
   if(!Inp_Trailing) return;

   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)  continue;

      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL     = PositionGetDouble(POSITION_SL);
      double curTP     = PositionGetDouble(POSITION_TP);
      int    posType   = (int)PositionGetInteger(POSITION_TYPE);
      int    dg        = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      MqlTick tick;
      if(!SymbolInfoTick(_Symbol, tick)) continue;

      double trailStart = atr * Inp_Trail_Start;
      double trailStep  = atr * Inp_Trail_Step;

      if(posType == POSITION_TYPE_BUY) {
         double profit = tick.bid - openPrice;
         if(profit >= trailStart) {
            double newSL = NormalizeDouble(tick.bid - trailStep, dg);
            if(newSL > curSL + trailStep * 0.5) {
               trade.PositionModify(ticket, newSL, curTP);
            }
         }
      } else if(posType == POSITION_TYPE_SELL) {
         double profit = openPrice - tick.ask;
         if(profit >= trailStart) {
            double newSL = NormalizeDouble(tick.ask + trailStep, dg);
            if(newSL < curSL - trailStep * 0.5 || curSL == 0) {
               trade.PositionModify(ticket, newSL, curTP);
            }
         }
      }
   }
}

//=================================================================
//  FILTRO DE SESIÓN HORARIA
//=================================================================
bool InSession() {
   if(!Inp_Session) return true;
   MqlDateTime dt;
   TimeToStruct(TimeGMT(), dt);
   return (dt.hour >= Inp_SesStart && dt.hour < Inp_SesEnd);
}

//=================================================================
//  REGISTRO DE OPERACIONES CERRADAS
//=================================================================
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) == Inp_Magic &&
            HistoryDealGetString(trans.deal, DEAL_SYMBOL) == _Symbol   &&
            HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_OUT) {

            double pf = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
            if(pf > 0) { wins++;   totalProfit += pf; }
            else        { losses++; totalLoss   += MathAbs(pf); }

            // Actualizar drawdown máximo
            double bal = AccountInfoDouble(ACCOUNT_BALANCE);
            if(bal > peakBalance) peakBalance = bal;
            double dd = (peakBalance - bal) / peakBalance * 100.0;
            if(dd > maxDD) maxDD = dd;

            int wr  = (wins+losses > 0) ? wins*100/(wins+losses) : 0;
            double avgWin  = (wins   > 0) ? totalProfit/wins   : 0;
            double avgLoss = (losses > 0) ? totalLoss/losses   : 0;
            double rr      = (avgLoss > 0) ? avgWin/avgLoss    : 0;

            Print(pf > 0 ? "✅ WIN " : "❌ LOSS",
                  " $", DoubleToString(pf,2),
                  " | W:",wins," L:",losses,
                  " WR:",wr,"%",
                  " | R:R real:",DoubleToString(rr,2),
                  " | MaxDD:",DoubleToString(maxDD,1),"%");
         }
      }
   }
}

//=================================================================
//  PANEL VISUAL MEJORADO
//=================================================================
void Lbl(string n, string txt, int x, int y, color c, int size=9) {
   if(ObjectFind(0,n) < 0) ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  size);
   ObjectSetString(0,  n, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, n, OBJPROP_COLOR, c);
   ObjectSetString(0,  n, OBJPROP_TEXT, txt);
}

void Panel(string estado, double rsi, double macdH, double rr) {
   if(!Inp_Panel) return;

   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnl  = eq - bal;
   int    wr   = (wins+losses > 0) ? wins*100/(wins+losses) : 0;
   color  cp   = pnl >= 0 ? clrLimeGreen : clrOrangeRed;
   color  cm   = macdH > 0 ? clrLimeGreen : clrOrangeRed;
   color  cwr  = wr >= 50 ? clrLimeGreen : clrOrangeRed;
   color  crr  = rr >= 1.0 ? clrLimeGreen : clrOrangeRed;

   // Fondo (rectángulo)
   string bg = "AQ_BG";
   if(ObjectFind(0,bg) < 0) ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 5);
   ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 5);
   ObjectSetInteger(0, bg, OBJPROP_XSIZE, 260);
   ObjectSetInteger(0, bg, OBJPROP_YSIZE, 195);
   ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'20,20,30');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_COLOR, C'60,60,80');
   ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);

   Lbl("AQ_T0", "⚡ ApexQuant v2.0 | "+_Symbol,       12, 12, clrCyan, 10);
   Lbl("AQ_L1", "─────────────────────────────",       12, 27, C'60,60,80');
   Lbl("AQ_T1", "Balance : $"+DoubleToString(bal,2),   12, 40, clrWhite);
   Lbl("AQ_T2", "P/L abierto: $"+DoubleToString(pnl,2),12,55, cp);
   Lbl("AQ_L2", "─────────────────────────────",       12, 68, C'60,60,80');
   Lbl("AQ_T3", "W:"+IntegerToString(wins)+
                " L:"+IntegerToString(losses)+
                " WR:"+IntegerToString(wr)+"%",         12, 80, cwr);
   Lbl("AQ_T4", "R:R real: "+DoubleToString(rr,2)+
                ":1  MaxDD:"+DoubleToString(maxDD,1)+"%",12,95,crr);
   Lbl("AQ_L3", "─────────────────────────────",       12,108, C'60,60,80');
   Lbl("AQ_T5", "RSI:"+DoubleToString(rsi,1)+
                "  MACD:"+DoubleToString(macdH,4),      12,120, cm);
   Lbl("AQ_T6", "Estado : "+estado,                    12,135, clrWhite);
   Lbl("AQ_T7", "Trades hoy: "+IntegerToString(todayTrades)+
                "/"+IntegerToString(Inp_MaxTrades),      12,150, clrGray);
   Lbl("AQ_T8", TimeToString(TimeCurrent(),TIME_SECONDS),12,165, clrGray);
   Lbl("AQ_T9", "R:R config: "+DoubleToString(Inp_TP_ATR,1)+
                ":"+DoubleToString(Inp_SL_ATR,1)+
                " (eq "+DoubleToString(Inp_SL_ATR/(Inp_TP_ATR+Inp_SL_ATR)*100,0)+"%)",
                                                        12,180, clrYellow);
   ChartRedraw(0);
}

//=================================================================
//  TICK PRINCIPAL
//=================================================================
void OnTick() {

   //--- Reset diario ---
   MqlDateTime dt, dl;
   TimeToStruct(TimeCurrent(), dt);
   TimeToStruct(dayRef, dl);
   if(dt.day != dl.day) {
      todayTrades = 0;
      dayRef      = TimeCurrent();
      // No reseteamos wins/losses para mantener estadísticas históricas
   }

   //--- Leer indicadores M1 ---
   double bbM[], bbU[], bbL[];
   double rsiV[], macdH[], macdS[];
   double atrV[], htfMA[];
   ArraySetAsSeries(bbM,   true); ArraySetAsSeries(bbU,  true);
   ArraySetAsSeries(bbL,   true); ArraySetAsSeries(rsiV, true);
   ArraySetAsSeries(macdH, true); ArraySetAsSeries(macdS,true);
   ArraySetAsSeries(atrV,  true); ArraySetAsSeries(htfMA,true);

   if(CopyBuffer(hBB,   0, 0, 3, bbM)  < 2) return;
   if(CopyBuffer(hBB,   1, 0, 3, bbU)  < 2) return;
   if(CopyBuffer(hBB,   2, 0, 3, bbL)  < 2) return;
   if(CopyBuffer(hRSI,  0, 0, 3, rsiV) < 2) return;
   if(CopyBuffer(hMACD, 0, 0, 3, macdH)< 2) return;
   if(CopyBuffer(hMACD, 1, 0, 3, macdS)< 2) return;
   if(CopyBuffer(hATR,  0, 1, 2, atrV) < 1) return;
   if(CopyBuffer(hHTF,  0, 0, 3, htfMA)< 2) return;

   double rsi    = rsiV[0];
   double mHist  = macdH[0];
   double bbMid  = bbM[0];
   double atr    = atrV[0];
   double htfNow = htfMA[0];
   double htfPrv = htfMA[1];
   bool   htfUp  = htfNow > htfPrv;   // MA5 apunta arriba
   bool   htfDn  = htfNow < htfPrv;   // MA5 apunta abajo

   if(atr <= 0) { Panel("ATR=0", rsi, mHist, 0); return; }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double price = tick.last;

   // R:R real para panel
   double avgWin  = (wins   > 0) ? totalProfit/wins   : 0;
   double avgLoss = (losses > 0) ? totalLoss/losses   : 0;
   double rrReal  = (avgLoss > 0) ? avgWin/avgLoss    : 0;

   //--- Gestionar trailing de posiciones abiertas ---
   ManageTrailing(atr);

   //--- Guardianes ---
   if(todayTrades >= Inp_MaxTrades) { Panel("MAX TRADES",  rsi, mHist, rrReal); return; }
   if(HasPosition())                { Panel("EN POSICIÓN", rsi, mHist, rrReal); return; }
   if(TimeCurrent() - lastTrade < Inp_Cooldown) {
      int r = (int)(Inp_Cooldown - (TimeCurrent() - lastTrade));
      Panel("Cooldown "+IntegerToString(r)+"s", rsi, mHist, rrReal); return;
   }
   if(!InSession()) { Panel("Fuera de sesión", rsi, mHist, rrReal); return; }

   // Filtro spread
   double spreadPts = (tick.ask - tick.bid) / _Point;
   if(spreadPts > Inp_MaxSpread) {
      Panel("Spread alto "+DoubleToString(spreadPts,0)+"pts", rsi, mHist, rrReal); return;
   }

   //=============================================================
   //  SEÑALES CON FILTRO HTF
   //
   //  BUY:  precio < BB media  +  RSI < 40  +  MACD hist > 0
   //        + MA(50) M5 apuntando arriba (tendencia alcista HTF)
   //
   //  SELL: precio > BB media  +  RSI > 60  +  MACD hist < 0
   //        + MA(50) M5 apuntando abajo (tendencia bajista HTF)
   //=============================================================
   bool htfBuyOk  = (!Inp_HTF_Filter) || htfUp;
   bool htfSellOk = (!Inp_HTF_Filter) || htfDn;

   bool buy  = (price < bbMid) &&
               (rsi   < Inp_RSI_Buy) &&
               (mHist > 0) &&
               htfBuyOk;

   bool sell = (price > bbMid) &&
               (rsi   > Inp_RSI_Sell) &&
               (mHist < 0) &&
               htfSellOk;

   //--- Sin señal: mostrar estado detallado ---
   if(!buy && !sell) {
      string est = "Sin confluencia";
      if(price < bbMid && mHist > 0 && !htfBuyOk)  est = "BUY bloq. por HTF";
      else if(price < bbMid && mHist > 0)           est = "RSI falta BUY ("+DoubleToString(rsi,0)+")";
      else if(price > bbMid && mHist < 0 && !htfSellOk) est = "SELL bloq. por HTF";
      else if(price > bbMid && mHist < 0)           est = "RSI falta SELL ("+DoubleToString(rsi,0)+")";
      Panel(est, rsi, mHist, rrReal);
      return;
   }

   //=============================================================
   //  EJECUTAR ORDEN
   //  SL = 1.0 × ATR  |  TP = 1.8 × ATR  →  R:R = 1.8:1
   //=============================================================
   double slDist = atr * Inp_SL_ATR;
   double tpDist = atr * Inp_TP_ATR;
   double lot    = CalcLot(slDist);
   int    dg     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool   ok     = false;

   if(buy) {
      double sl = NormalizeDouble(tick.ask - slDist, dg);
      double tp = NormalizeDouble(tick.ask + tpDist, dg);
      ok = trade.Buy(lot, _Symbol, tick.ask, sl, tp, "AQ-BUY");
   } else {
      double sl = NormalizeDouble(tick.bid + slDist, dg);
      double tp = NormalizeDouble(tick.bid - tpDist, dg);
      ok = trade.Sell(lot, _Symbol, tick.bid, sl, tp, "AQ-SELL");
   }

   if(ok) {
      todayTrades++;
      lastTrade = TimeCurrent();
      double riskUSD = AccountInfoDouble(ACCOUNT_BALANCE) * Inp_RiskPct / 100.0;
      Print(">>> ", (buy ? "BUY" : "SELL"),
            " Lot:",   DoubleToString(lot,3),
            " RSI:",   DoubleToString(rsi,1),
            " MACD:",  DoubleToString(mHist,4),
            " TP:",    DoubleToString(tpDist,_Digits),
            " SL:",    DoubleToString(slDist,_Digits),
            " R:R:",   DoubleToString(Inp_TP_ATR/Inp_SL_ATR,2),
            " HTF↑:",  (htfUp?"SI":"NO"),
            " Riesgo:$",DoubleToString(riskUSD,2),
            " #",todayTrades);
      Panel(buy ? "✅ ENTRÓ BUY" : "✅ ENTRÓ SELL", rsi, mHist, rrReal);
   } else {
      Print("! Error orden: ", trade.ResultRetcodeDescription());
      Panel("ERROR ORDEN", rsi, mHist, rrReal);
   }
}
//+------------------------------------------------------------------+