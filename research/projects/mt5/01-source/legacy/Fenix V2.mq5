//+------------------------------------------------------------------+
//|  BB + RSI(6) + MACD(5,13,1) v2 - Filtro Tendencia H1            |
//|  Fuente: Foro MQL5 - estrategia probada por traders reales       |
//|                                                                  |
//|  MEJORA v2: Filtro de tendencia H1                               |
//|  - Solo BUY si H1 es alcista (precio > EMA50 en H1)             |
//|  - Solo SELL si H1 es bajista (precio < EMA50 en H1)            |
//|  - Elimina entradas contra la tendencia mayor                    |
//|  - Resultado esperado: menos trades, mayor winrate               |
//|                                                                  |
//|  LOGICA M1 (sin cambios):                                        |
//|  - BB(20,2): direccion del mercado                               |
//|  - RSI(6): momentum rapido                                       |
//|  - MACD(5,13,1): confirma fuerza                                 |
//|                                                                  |
//|  GESTION: TP corto (0.8 ATR) + SL largo (2.0 ATR)               |
//+------------------------------------------------------------------+
#property copyright "BB RSI MACD Fenix"
#property version   "2.00"
#property strict
#include <Trade/Trade.mqh>

input group "=== INDICADORES ==="
input int    Inp_BB_Period   = 20;   // Bollinger periodo
input double Inp_BB_Sigma    = 2.0;  // Bollinger desviacion
input int    Inp_RSI_Period  = 6;    // RSI periodo (corto = reactivo)
input double Inp_RSI_Buy     = 40.0; // RSI maximo para BUY
input double Inp_RSI_Sell    = 60.0; // RSI minimo para SELL
input int    Inp_MACD_Fast   = 5;    // MACD EMA rapida
input int    Inp_MACD_Slow   = 13;   // MACD EMA lenta
input int    Inp_MACD_Signal = 1;    // MACD señal
input int    Inp_ATR_Period  = 10;   // ATR para SL/TP
input int    Inp_H1_EMA     = 50;   // EMA en H1 para filtro de tendencia mayor

input group "=== GESTION (clave: TP corto SL largo) ==="
input double Inp_TP_ATR      = 0.8;  // TP corto = llega rapido y frecuente
input double Inp_SL_ATR      = 2.0;  // SL largo = aguanta ruido M1
input double Inp_RiskPct     = 1.0;  // % balance por trade
input long   Inp_Magic       = 1110;

input group "=== CONTROL ==="
input int    Inp_Cooldown    = 60;   // Segundos entre trades
input int    Inp_MaxTrades   = 40;   // Max trades por dia
input bool   Inp_Panel       = true;

//--- HANDLES
int hBB, hRSI, hMACD, hATR;
int hH1_EMA;  // EMA H1 para filtro de tendencia mayor

//--- ESTADO
CTrade trade;
datetime lastTrade   = 0;
datetime dayRef      = 0;
int      todayTrades = 0;
int      wins        = 0;
int      losses      = 0;

int OnInit() {
   trade.SetExpertMagicNumber(Inp_Magic);
   trade.SetDeviationInPoints(300);

   hBB     = iBands(_Symbol, PERIOD_M1, Inp_BB_Period, 0, Inp_BB_Sigma, PRICE_CLOSE);
   hRSI    = iRSI(_Symbol,   PERIOD_M1, Inp_RSI_Period, PRICE_CLOSE);
   hMACD   = iMACD(_Symbol,  PERIOD_M1, Inp_MACD_Fast, Inp_MACD_Slow, Inp_MACD_Signal, PRICE_CLOSE);
   hATR    = iATR(_Symbol,   PERIOD_M1, Inp_ATR_Period);
   hH1_EMA = iMA(_Symbol,    PERIOD_H1, Inp_H1_EMA, 0, MODE_EMA, PRICE_CLOSE);

   if(hBB==INVALID_HANDLE||hRSI==INVALID_HANDLE||
      hMACD==INVALID_HANDLE||hATR==INVALID_HANDLE||hH1_EMA==INVALID_HANDLE) {
      Print("Error creando indicadores"); return INIT_FAILED;
   }

   dayRef = TimeCurrent();
   Print("=== BB+RSI+MACD FENIX v2 | ",_Symbol," ===");
   Print("MEJORA v2: Filtro H1 EMA(",Inp_H1_EMA,") activo");
   Print("Solo BUY si H1 alcista | Solo SELL si H1 bajista");
   Print("TP:",Inp_TP_ATR,"x ATR  SL:",Inp_SL_ATR,"x ATR  Riesgo:",Inp_RiskPct,"%");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   IndicatorRelease(hBB);
   IndicatorRelease(hRSI);
   IndicatorRelease(hMACD);
   IndicatorRelease(hATR);
   IndicatorRelease(hH1_EMA);
   ObjectsDeleteAll(0, "BRM_");
}

double CalcLot(double slDist) {
   if(slDist <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double risk = AccountInfoDouble(ACCOUNT_BALANCE) * Inp_RiskPct / 100.0;
   double tv   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv<=0||ts<=0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot  = risk / (slDist * tv/ts);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step>0) lot = MathFloor(lot/step)*step;
   return MathMax(minL, MathMin(maxL, lot));
}

bool HasPosition() {
   for(int i=PositionsTotal()-1;i>=0;i--) {
      ulong t=PositionGetTicket(i);
      if(PositionSelectByTicket(t) &&
         PositionGetInteger(POSITION_MAGIC)==Inp_Magic &&
         PositionGetString(POSITION_SYMBOL)==_Symbol) return true;
   }
   return false;
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& req,
                        const MqlTradeResult& res) {
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD) {
      if(HistoryDealSelect(trans.deal)) {
         if(HistoryDealGetInteger(trans.deal,DEAL_MAGIC)==Inp_Magic &&
            HistoryDealGetString(trans.deal,DEAL_SYMBOL)==_Symbol   &&
            HistoryDealGetInteger(trans.deal,DEAL_ENTRY)==DEAL_ENTRY_OUT) {
            double pf = HistoryDealGetDouble(trans.deal,DEAL_PROFIT);
            if(pf > 0) wins++; else losses++;
            int wr = (wins+losses>0) ? wins*100/(wins+losses) : 0;
            Print(pf>0?"WIN":"LOSS"," $",DoubleToString(pf,2),
                  " | W:",wins," L:",losses," WR:",wr,"%");
         }
      }
   }
}

void Lbl(string n, string txt, int x, int y, color c) {
   if(ObjectFind(0,n)<0) ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,10);
   ObjectSetString(0, n,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetString(0, n,OBJPROP_TEXT,txt);
}

void Panel(string estado, double rsi, double macdH) {
   if(!Inp_Panel) return;
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double pnl = eq - bal;
   int    wr  = (wins+losses>0) ? wins*100/(wins+losses) : 0;
   color  cp  = pnl>=0 ? clrLimeGreen : clrOrangeRed;
   color  ce  = macdH>0 ? clrLimeGreen : clrOrangeRed;

   Lbl("BRM_0","BB+RSI+MACD v2 [H1 filtro] | "+_Symbol, 10,15,clrCyan);
   Lbl("BRM_1","Balance: $"+DoubleToString(bal,2),    10,32,clrWhite);
   Lbl("BRM_2","P/L:     $"+DoubleToString(pnl,2),    10,49,cp);
   Lbl("BRM_3","W:"+IntegerToString(wins)+
               " L:"+IntegerToString(losses)+
               " WR:"+IntegerToString(wr)+"%",         10,66,clrYellow);
   Lbl("BRM_4","RSI:"+DoubleToString(rsi,1)+
               "  MACD:"+DoubleToString(macdH,4),      10,83,ce);
   Lbl("BRM_5","Estado: "+estado,                     10,100,clrWhite);
   Lbl("BRM_6","Trades hoy: "+IntegerToString(todayTrades)+
               "/"+IntegerToString(Inp_MaxTrades),     10,117,clrGray);
   Lbl("BRM_7",TimeToString(TimeCurrent(),TIME_SECONDS),10,134,clrGray);
   ChartRedraw(0);
}

void OnTick() {
   // Reset diario
   MqlDateTime dt, dl;
   TimeToStruct(TimeCurrent(), dt);
   TimeToStruct(dayRef, dl);
   if(dt.day != dl.day) {
      todayTrades=0; wins=0; losses=0; dayRef=TimeCurrent();
   }

   // Leer indicadores siempre para el panel
   double bbM[], bbU[], bbL[];
   double rsiV[], macdH[], macdS[];
   double atrV[];
   ArraySetAsSeries(bbM,true); ArraySetAsSeries(bbU,true); ArraySetAsSeries(bbL,true);
   ArraySetAsSeries(rsiV,true); ArraySetAsSeries(macdH,true);
   ArraySetAsSeries(macdS,true); ArraySetAsSeries(atrV,true);

   if(CopyBuffer(hBB,  0,0,2,bbM) <2) { Panel("ERR datos",0,0); return; }
   if(CopyBuffer(hBB,  1,0,2,bbU) <2) { Panel("ERR datos",0,0); return; }
   if(CopyBuffer(hBB,  2,0,2,bbL) <2) { Panel("ERR datos",0,0); return; }
   if(CopyBuffer(hRSI, 0,0,2,rsiV)<2) { Panel("ERR datos",0,0); return; }
   if(CopyBuffer(hMACD,0,0,2,macdH)<2){ Panel("ERR datos",0,0); return; }
   if(CopyBuffer(hMACD,1,0,2,macdS)<2){ Panel("ERR datos",0,0); return; }
   if(CopyBuffer(hATR, 0,1,1,atrV) <1){ Panel("ERR datos",0,0); return; }

   // --- FILTRO H1: leer EMA50 en H1 ---
   double h1ema[];
   ArraySetAsSeries(h1ema, true);
   if(CopyBuffer(hH1_EMA, 0, 0, 1, h1ema) < 1) { Panel("ERR H1",0,0); return; }
   double h1EmaVal = h1ema[0];

   // Precio actual vs EMA H1 = tendencia mayor
   MqlTick tickH1; SymbolInfoTick(_Symbol, tickH1);
   bool h1Alcista = (tickH1.last > h1EmaVal); // H1 alcista = permite solo BUY
   bool h1Bajista = (tickH1.last < h1EmaVal); // H1 bajista = permite solo SELL

   double rsi   = rsiV[0];
   double mHist = macdH[0];  // histograma = MACD - señal
   double mMid  = bbM[0];    // media BB = tendencia central
   double atr   = atrV[0];
   if(atr <= 0) { Panel("ATR=0",rsi,mHist); return; }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double price = tick.last;

   // Estado para panel aunque no opere
   string estado = "Buscando...";
   if(todayTrades >= Inp_MaxTrades) { Panel("MAX TRADES",rsi,mHist); return; }
   if(HasPosition())                { Panel("EN POSICION",rsi,mHist); return; }
   if(TimeCurrent()-lastTrade < Inp_Cooldown) {
      int r=(int)(Inp_Cooldown-(TimeCurrent()-lastTrade));
      Panel("Cooldown "+IntegerToString(r)+"s",rsi,mHist); return;
   }

   // =======================================================
   // SEÑAL BUY: fuerza alcista + H1 confirma tendencia
   // 1. H1 alcista (precio > EMA50 en H1) - NO operar contra tendencia mayor
   // 2. Precio debajo de la media BB (zona de valor en M1)
   // 3. RSI < 40 (momentum bajo = espacio para subir)
   // 4. Histograma MACD > 0 (fuerza alcista confirmada)
   // =======================================================
   bool buy  = h1Alcista       &&   // FILTRO H1: tendencia mayor alcista
               (price < mMid)  &&   // precio en zona de valor
               (rsi   < Inp_RSI_Buy) &&
               (mHist > 0);

   // =======================================================
   // SEÑAL SELL: fuerza bajista + H1 confirma tendencia
   // 1. H1 bajista (precio < EMA50 en H1) - NO operar contra tendencia mayor
   // 2. Precio encima de la media BB (zona de valor en M1)
   // 3. RSI > 60 (momentum alto = espacio para bajar)
   // 4. Histograma MACD < 0 (fuerza bajista confirmada)
   // =======================================================
   bool sell = h1Bajista       &&   // FILTRO H1: tendencia mayor bajista
               (price > mMid)  &&   // precio en zona de valor
               (rsi   > Inp_RSI_Sell) &&
               (mHist < 0);

   if(!buy && !sell) {
      string h1str = h1Alcista ? "H1:^ALCISTA" : h1Bajista ? "H1:vBAJISTA" : "H1:LATERAL";
      if(!h1Alcista && !h1Bajista)
         estado = h1str+" - esperando tendencia H1";
      else if(h1Alcista && price < mMid && mHist > 0)
         estado = h1str+" RSI falta BUY ("+DoubleToString(rsi,0)+")";
      else if(h1Bajista && price > mMid && mHist < 0)
         estado = h1str+" RSI falta SELL ("+DoubleToString(rsi,0)+")";
      else if(h1Alcista && mHist < 0)
         estado = h1str+" MACD bajista - esperando";
      else if(h1Bajista && mHist > 0)
         estado = h1str+" MACD alcista - esperando";
      else
         estado = h1str+" sin confluencia M1";
      Panel(estado, rsi, mHist);
      return;
   }

   // --- EJECUTAR ---
   double slDist = atr * Inp_SL_ATR;
   double tpDist = atr * Inp_TP_ATR;
   double lot    = CalcLot(slDist);
   int    dg     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   bool   ok     = false;

   if(buy) {
      double sl = NormalizeDouble(tick.ask - slDist, dg);
      double tp = NormalizeDouble(tick.ask + tpDist, dg);
      ok = trade.Buy(lot, _Symbol, tick.ask, sl, tp, "BRM-BUY");
   } else {
      double sl = NormalizeDouble(tick.bid + slDist, dg);
      double tp = NormalizeDouble(tick.bid - tpDist, dg);
      ok = trade.Sell(lot, _Symbol, tick.bid, sl, tp, "BRM-SELL");
   }

   if(ok) {
      todayTrades++;
      lastTrade = TimeCurrent();
      double riskUSD = AccountInfoDouble(ACCOUNT_BALANCE)*Inp_RiskPct/100.0;
      Print(">>> ",(buy?"BUY":"SELL"),
            " Lot:",DoubleToString(lot,3),
            " RSI:",DoubleToString(rsi,1),
            " MACD:",DoubleToString(mHist,4),
            " TP:",DoubleToString(tpDist,2),
            " SL:",DoubleToString(slDist,2),
            " Riesgo:$",DoubleToString(riskUSD,2),
            " #",todayTrades);
      Panel(buy?"ENTRO BUY":"ENTRO SELL", rsi, mHist);
   } else {
      Print("! Error: ",trade.ResultRetcodeDescription());
      Panel("ERROR ORDEN", rsi, mHist);
   }
}