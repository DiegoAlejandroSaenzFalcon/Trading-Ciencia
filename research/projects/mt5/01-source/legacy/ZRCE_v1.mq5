
//+===========================================================================+
//|              ZONE RECOVERY CONTINUAL ENGINE (ZRCE) v1.00                 |
//|         Motor Cuantitativo HFT de Recuperación Asimétrica por Zonas      |
//|                                                                           |
//|  Plataforma : MetaTrader 5 (MetaEditor 5)                                 |
//|  Bróker     : Pepperstone Razor (ECN/STP)                                 |
//|  Símbolo    : EURUSD                                                      |
//|  Capital    : $100 USD (micro-capital)                                    |
//|  Autor      : ZRCE Institutional Quant Engine                             |
//+===========================================================================+
//
// ╔══════════════════════════════════════════════════════════════════════════╗
// ║         AUDITORÍA DEL MÉTODO CIENTÍFICO - REQUERIMIENTO PREVIO          ║
// ╠══════════════════════════════════════════════════════════════════════════╣
// ║                                                                          ║
// ║  PREGUNTA DE INVESTIGACIÓN:                                              ║
// ║  ¿Puede un sistema de recuperación por zonas asimétrico operar de forma ║
// ║  sostenible con un capital de $100 en EURUSD bajo condiciones de         ║
// ║  microestructura ECN moderna?                                            ║
// ║                                                                          ║
// ║  ANÁLISIS DE TOXICIDAD DEL FLUJO DE ÓRDENES INSTITUCIONAL:              ║
// ║  La teoría VPIN (Volume-synchronized Probability of Informed Trading,   ║
// ║  Easley et al., 2012) demuestra que en entornos ECN, la toxicidad del   ║
// ║  flujo impacta directamente el riesgo de ejecución. Cuando participantes ║
// ║  informados (HFTs institucionales) operan unidireccionalmente, el spread ║
// ║  se amplía y el deslizamiento aumenta. Para un EA de micro-capital,     ║
// ║  esto puede erosionar >30% del objetivo de beneficio en un solo tick.   ║
// ║  SOLUCIÓN: El filtro de Tick Imbalance mide esta toxicidad en tiempo    ║
// ║  real y suspende entradas cuando el flujo es unidireccional > umbral.   ║
// ║                                                                          ║
// ║  REGÍMENES DE MERCADO Y EL EXPONENTE DE HURST:                          ║
// ║  H(t) < 0.5 = Anti-persistencia (Media Reversión) → ZONA FAVORABLE     ║
// ║  H(t) = 0.5 = Caminata Aleatoria (Ruido Browniano)                      ║
// ║  H(t) > 0.5 = Persistencia (Tendencia) → ZONA PELIGROSA                ║
// ║  Las estrategias de recuperación por zonas presuponen que el precio     ║
// ║  revierta. En régimen de tendencia (H>0.5), la rejilla NUNCA converge  ║
// ║  y conduce a Riesgo de Ruina determinístico. El filtro de Hurst es la   ║
// ║  defensa empírica primaria contra este escenario.                        ║
// ║                                                                          ║
// ║  LÍMITES MATEMÁTICOS DE LA RECUPERACIÓN ASIMÉTRICA CON $100:           ║
// ║  Secuencia de lotes: 0.01 → 0.01 → 0.02 → 0.04 → 0.08 → 0.16         ║
// ║  Margen requerido total (Pepperstone, leverage 500:1, EURUSD~1.08):    ║
// ║    Nivel 0: 0.01 * 100,000 * 1.08 / 500 = $2.16                        ║
// ║    Nivel 5: 0.16 * 100,000 * 1.08 / 500 = $34.56                       ║
// ║    SUMA (0-5): ~$50 → 50% del capital = margen libre peligrosamente bajo║
// ║  CONCLUSIÓN: Máximo 5-6 niveles son matemáticamente viables con $100.   ║
// ║  Este EA limita la rejilla a 8 niveles y fuerza cierre al 80% de margen ║
// ║  (adelantándose al Stop Out del bróker al 50%) como medida de seguridad.║
// ║                                                                          ║
// ║  DEFENSA EMPÍRICA COMBINADA:                                             ║
// ║  P(Ruina) ≈ 1 - [P(H<0.5) × P(Imbalance<umbral) × P(Spread<max)]      ║
// ║  Con los tres filtros activos, la probabilidad de entrar en un régimen  ║
// ║  de tendencia con flujo tóxico y spread alto se reduce sustancialmente,  ║
// ║  convirtiendo la estrategia en una apuesta favorable en expectativa.    ║
// ║                                                                          ║
// ╚══════════════════════════════════════════════════════════════════════════╝
//
// ╔══════════════════════════════════════════════════════════════════════════╗
// ║                    ARQUITECTURA DEL SISTEMA                              ║
// ╠══════════════════════════════════════════════════════════════════════════╣
// ║  CQuantEngine    → Matemáticas pesadas (Hurst R/S, Tick Imbalance, ATR)║
// ║  CTradeExecution → Comunicación bróker (Async, Backoff exponencial)     ║
// ║  CZoneRecovery   → Rejilla asimétrica (Magic compuesto, ATR dinámico)  ║
// ║  CRiskShield     → Protección capital (Spread, Margen, GhostTick, WE)  ║
// ║  CHUD            → Panel HUD español (CORNER_RIGHT_UPPER, 10% ancho)   ║
// ║  FSM             → Máquina de Estado: IDLE→PHASE1→RECOVERY→TRAILING    ║
// ╚══════════════════════════════════════════════════════════════════════════╝

#property copyright   "ZRCE Institutional Quant Engine v1.0"
#property version     "1.00"
#property description "Motor de Recuperación por Zonas - Arquitectura OOP Institucional"
#property strict

// ─── Bibliotecas estándar MQL5 ────────────────────────────────────────────
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+===========================================================================+
//|  SECCIÓN 1: ENUMERACIONES GLOBALES                                        |
//+===========================================================================+

/// @brief Estados de la Máquina de Estado Finito (FSM) del ZRCE
enum ENUM_FSM_STATE
{
   FSM_IDLE            = 0,  ///< Sin posiciones; esperando señal Phase 1
   FSM_PHASE1_ACTIVE   = 1,  ///< Operación primaria única activa
   FSM_ZONE_RECOVERY   = 2,  ///< Rejilla de recuperación asimétrica activa
   FSM_BASKET_TRAILING = 3,  ///< Trailing global de equidad sobre la cesta
   FSM_EMERGENCY_CLOSE = 4,  ///< Cierre forzado por nivel de margen crítico
   FSM_WEEKEND_BLOCK   = 5   ///< Bloqueo de fin de semana activo
};

// Constantes del sistema
#define ZRCE_MAX_LEVELS      8    // Máx. niveles de recuperación (limitado por capital $100)
#define ZRCE_RETRY_MAX       5    // Máx. reintentos con backoff exponencial
#define ZRCE_BACKOFF_BASE    200  // Base del backoff exponencial en milisegundos
#define ZRCE_GHOST_SECONDS   5    // Umbral de tick fantasma en segundos
#define ZRCE_TIMER_MS        500  // Intervalo del timer en milisegundos

//+===========================================================================+
//|  SECCIÓN 2: PARÁMETROS DE ENTRADA (ESPAÑOL, AGRUPADOS)                   |
//+===========================================================================+

// ─── Identificación del EA ────────────────────────────────────────────────
sinput string __grp0__         = "═══════ IDENTIFICACIÓN ═══════";
input  ulong  InpMagicBase     = 202401;    // Número mágico base
input  string InpEAComment     = "ZRCE_v1"; // Comentario de órdenes

// ─── Filtros de Régimen de Mercado ───────────────────────────────────────
sinput string __grp1__              = "═══════ FILTROS DE RÉGIMEN ═══════";
input  int    InpHurstPeriod        = 128;   // Período Exponente de Hurst (barras M1)
input  double InpHurstThreshold     = 0.50;  // Umbral Hurst (< = Media Reversión APTO)
input  int    InpTickImbalanceLook  = 50;    // Lookback Tick Imbalance (número de ticks)
input  double InpTickToxicThresh    = 0.65;  // Umbral de toxicidad de flujo (0.0-1.0)

// ─── Indicadores Técnicos ────────────────────────────────────────────────
sinput string __grp2__          = "═══════ INDICADORES TÉCNICOS ═══════";
input  int    InpATRPeriod      = 14;        // Período ATR (timeframe M5)
input  int    InpBBPeriod       = 20;        // Período Bandas de Bollinger (M5)
input  double InpBBDeviation    = 2.0;       // Desviaciones estándar de BB
input  double InpBBZScore       = 2.0;       // Z-Score mínimo para entrada Phase 1

// ─── Gestión de Riesgo ───────────────────────────────────────────────────
sinput string __grp3__              = "═══════ GESTIÓN DE RIESGO ═══════";
input  double InpMaxSpreadPts       = 15.0;  // Spread máximo permitido (puntos)
input  double InpMinMarginLevel     = 150.0; // Nivel de margen mínimo (%)
input  double InpEmergencyMarginLvl = 80.0;  // Nivel de margen de EMERGENCIA (%)
input  double InpATRMultiplier      = 1.5;   // Multiplicador ATR para objetivo USD
input  double InpBasketTrailPct     = 0.30;  // Porcentaje de retroceso desde pico (cesta)

// ─── Zona de Recuperación ────────────────────────────────────────────────
sinput string __grp4__               = "═══════ ZONA DE RECUPERACIÓN ═══════";
input  double InpPhase1Volume        = 0.01; // Volumen Phase 1 en lotes
input  double InpZoneATRMult         = 1.0;  // Multiplicador ATR para distancia de zona
input  double InpPendingOffsetPts    = 5.0;  // Offset de orden STOP pendiente (puntos)

// ─── Trailing Stop Individual (Phase 1) ──────────────────────────────────
sinput string __grp5__            = "═══════ TRAILING INDIVIDUAL ═══════";
input  double InpBEOffsetPts      = 10.0;   // Offset Break-Even (puntos)
input  double InpTrailATRMult     = 1.0;    // Multiplicador ATR para trailing stop

// ─── Horarios y Sesión ───────────────────────────────────────────────────
sinput string __grp6__              = "═══════ HORARIOS DE SESIÓN ═══════";
input  int    InpFridayBlockHour    = 15;   // Hora de bloqueo nuevas entradas (UTC, viernes)
input  int    InpFridayLiquidHour   = 21;   // Hora de liquidación forzada (UTC, viernes)
input  bool   InpLiquidateWeekend   = true; // Activar liquidación de fin de semana

// ─── Panel HUD ───────────────────────────────────────────────────────────
sinput string __grp7__          = "═══════ PANEL DE CONTROL ═══════";
input  color  InpHUDTextColor   = clrWhite;      // Color de texto HUD
input  color  InpHUDAlertColor  = clrOrangeRed;  // Color de alerta HUD
input  int    InpHUDFontSize    = 8;             // Tamaño de fuente HUD


//+===========================================================================+
//|  SECCIÓN 3: CLASE CQuantEngine                                            |
//|  Responsabilidad: Cálculos matemáticos pesados, ejecutados SÓLO en nueva  |
//|  vela M1/M5 para prevenir sobrecarga térmica de CPU. Gestión agresiva de  |
//|  memoria con ArrayFree() y ZeroMemory().                                   |
//+===========================================================================+
class CQuantEngine
{
private:
   // ─── Handles de indicadores ──────────────────────────────────────────
   int      m_hATR;           ///< Handle indicador ATR en M5
   int      m_hBB;            ///< Handle indicador Bollinger Bands en M5

   // ─── Timestamps de última actualización (control de nueva vela) ───
   datetime m_lastM1Bar;
   datetime m_lastM5Bar;

   // ─── Valores calculados (públicos via getters) ────────────────────
   double   m_hurst;          ///< Exponente de Hurst [0, 1]
   double   m_tickImbalance;  ///< Toxicidad del flujo de ticks [0, 1]
   double   m_atrPts;         ///< ATR en puntos del símbolo
   double   m_atrUSD;         ///< ATR aproximado en USD para volumen base
   double   m_bbUpper;        ///< Banda BB superior
   double   m_bbLower;        ///< Banda BB inferior
   double   m_bbMid;          ///< Banda BB media (SMA)
   double   m_zScore;         ///< Z-Score del precio actual respecto a BB

   //--------------------------------------------------------------------
   //  MÉTODO PRIVADO: Hurst Exponent via Rescaled Range (R/S) Analysis
   //
   //  Matemática:
   //    1. Retornos log: r_i = ln(P_i / P_{i-1})
   //    2. Media: μ = (1/N) * Σ r_i
   //    3. Desviaciones acumuladas: X_t = Σ_{i=1}^{t} (r_i - μ)
   //    4. Rango: R = max(X_t) - min(X_t)
   //    5. Desviación estándar: S = sqrt((1/N) * Σ (r_i - μ)²)
   //    6. Exponente: H = log(R/S) / log(N)
   //
   //  Interpretación para este sistema:
   //    H < 0.5 → Anti-persistencia (favorable para media reversión)
   //    H > 0.5 → Persistencia (tendencia, PELIGROSO para zona recovery)
   //--------------------------------------------------------------------
   double CalculateHurstRS(int period)
   {
      // Validación mínima de datos
      if(period < 32)
      {
         Print("[ZRCE][QUANT][WARN] Período Hurst < 32. Retornando neutro (0.5)");
         return 0.5;
      }

      // ─── Paso 1: Obtener precios de cierre históricos en M1 ───────
      double closes[];
      ArraySetAsSeries(closes, true); // Índice 0 = barra más reciente
      if(CopyClose(_Symbol, PERIOD_M1, 1, period, closes) < period)
      {
         Print("[ZRCE][QUANT][WARN] CopyClose: datos insuficientes para Hurst");
         ArrayFree(closes);
         return 0.5;
      }

      int    n           = period - 1; // Número de retornos
      double meanReturn  = 0.0;
      double returns[];
      ArrayResize(returns, n);
      ZeroMemory(returns);

      // ─── Paso 2: Calcular retornos logarítmicos y media ──────────
      for(int i = 0; i < n; i++)
      {
         // closes[0]=más reciente, closes[period-1]=más antiguo
         // Retorno: ln(precio_t / precio_{t-1})
         if(closes[i+1] > 0.0)
            returns[i] = MathLog(closes[i] / closes[i+1]);
         meanReturn += returns[i];
      }
      meanReturn /= (double)n;

      // ─── Paso 3: Desviaciones acumuladas ─────────────────────────
      double cumDev[];
      ArrayResize(cumDev, n);
      ZeroMemory(cumDev);
      double runSum = 0.0;
      for(int i = 0; i < n; i++)
      {
         runSum   += (returns[i] - meanReturn);
         cumDev[i] = runSum;
      }

      // ─── Paso 4: Rango R = max(X) - min(X) ───────────────────────
      double R = cumDev[ArrayMaximum(cumDev, 0, n)]
               - cumDev[ArrayMinimum(cumDev, 0, n)];

      // ─── Paso 5: Desviación estándar S ───────────────────────────
      double var = 0.0;
      for(int i = 0; i < n; i++)
      {
         double d = returns[i] - meanReturn;
         var += d * d;
      }
      double S = MathSqrt(var / (double)n);

      // ─── Liberar memoria inmediatamente ──────────────────────────
      ArrayFree(closes);
      ArrayFree(returns);
      ArrayFree(cumDev);

      if(S <= 0.0 || R <= 0.0) return 0.5; // Protección división por cero

      // ─── Paso 6: H = log(R/S) / log(N) ──────────────────────────
      double H = MathLog(R / S) / MathLog((double)n);

      return MathMax(0.0, MathMin(1.0, H)); // Clamp [0, 1]
   }

   //--------------------------------------------------------------------
   //  MÉTODO PRIVADO: Tick Imbalance (Toxicidad del flujo de órdenes)
   //
   //  Matemática:
   //    Para cada tick: δ_t = sign(bid_t - bid_{t-1})
   //    Imbalance = |Σδ>0 - Σδ<0| / |Σδ≠0|
   //
   //  Interpretación:
   //    0.0 = Flujo perfectamente equilibrado (no tóxico)
   //    1.0 = Flujo completamente unidireccional (máxima toxicidad)
   //    > InpTickToxicThresh → Suspender Phase 1
   //--------------------------------------------------------------------
   double CalculateTickImbalance(int lookback)
   {
      MqlTick ticks[];
      int copied = CopyTicks(_Symbol, ticks, COPY_TICKS_TRADE, 0, lookback);
      if(copied < 2)
      {
         ArrayFree(ticks);
         return 0.0;
      }

      int buyTicks  = 0;
      int sellTicks = 0;

      for(int i = 1; i < copied; i++)
      {
         double delta = ticks[i].bid - ticks[i-1].bid;
         if(delta > 0.0)       buyTicks++;
         else if(delta < 0.0)  sellTicks++;
         // delta == 0: tick de spread sin movimiento direccional → ignorar
      }

      ArrayFree(ticks);

      int total = buyTicks + sellTicks;
      if(total == 0) return 0.0;

      return (double)MathAbs(buyTicks - sellTicks) / (double)total;
   }

public:
   //--- Constructor: inicializar a valores seguros/neutros
   CQuantEngine() : m_hATR(INVALID_HANDLE), m_hBB(INVALID_HANDLE),
                    m_lastM1Bar(0), m_lastM5Bar(0),
                    m_hurst(0.5), m_tickImbalance(0.0),
                    m_atrPts(0.0), m_atrUSD(0.0),
                    m_bbUpper(0.0), m_bbLower(0.0),
                    m_bbMid(0.0), m_zScore(0.0) {}

   //--- Destructor: liberar handles de indicadores
   ~CQuantEngine()
   {
      if(m_hATR != INVALID_HANDLE) { IndicatorRelease(m_hATR); m_hATR = INVALID_HANDLE; }
      if(m_hBB  != INVALID_HANDLE) { IndicatorRelease(m_hBB);  m_hBB  = INVALID_HANDLE; }
   }

   //--- Inicialización: crear handles de indicadores y esperar datos
   bool Init(int atrPeriod, int bbPeriod, double bbDev)
   {
      m_hATR = iATR(_Symbol, PERIOD_M5, atrPeriod);
      if(m_hATR == INVALID_HANDLE)
      {
         Print("[ZRCE][QUANT][FATAL] No se pudo crear handle ATR M5");
         return false;
      }

      // iBands buffers: 0=BASE_LINE(SMA), 1=UPPER_BAND, 2=LOWER_BAND
      m_hBB = iBands(_Symbol, PERIOD_M5, bbPeriod, 0, bbDev, PRICE_CLOSE);
      if(m_hBB == INVALID_HANDLE)
      {
         Print("[ZRCE][QUANT][FATAL] No se pudo crear handle Bollinger Bands M5");
         return false;
      }

      // Precalentamiento: esperar que el indicador tenga datos calculados
      int attempts = 0;
      while(BarsCalculated(m_hATR) < atrPeriod && attempts < 200)
      {
         Sleep(50); // Permitido SÓLO en OnInit()
         attempts++;
      }

      PrintFormat("[ZRCE][QUANT][OK] Inicializado. ATR_Handle=%d BB_Handle=%d",
                  m_hATR, m_hBB);
      return true;
   }

   //--------------------------------------------------------------------------
   //  Update(): Actualizar cálculos SÓLO en nueva vela M1/M5
   //  Razón: El Hurst R/S y CopyTicks son O(N) → costosos. Ejecutarlos en
   //  cada tick dispararía el uso de CPU en período de alta frecuencia.
   //--------------------------------------------------------------------------
   void Update(bool force = false)
   {
      datetime curM1 = iTime(_Symbol, PERIOD_M1, 0);
      datetime curM5 = iTime(_Symbol, PERIOD_M5, 0);
      bool newM5     = (curM5 != m_lastM5Bar) || force;
      bool newM1     = (curM1 != m_lastM1Bar) || force;

      // ─── Actualizar ATR y BB en nueva vela M5 ──────────────────────────
      if(newM5)
      {
         m_lastM5Bar = curM5;

         // Copiar ATR (1 barra confirmada, índice 1)
         double atrBuf[1];
         if(CopyBuffer(m_hATR, 0, 1, 1, atrBuf) == 1)
            m_atrPts = atrBuf[0];

         // Copiar bandas de Bollinger
         double bbMidBuf[1], bbUpBuf[1], bbLoBuf[1];
         if(CopyBuffer(m_hBB, 0, 1, 1, bbMidBuf) == 1 &&
            CopyBuffer(m_hBB, 1, 1, 1, bbUpBuf)  == 1 &&
            CopyBuffer(m_hBB, 2, 1, 1, bbLoBuf)  == 1)
         {
            m_bbMid   = bbMidBuf[0];
            m_bbUpper = bbUpBuf[0];
            m_bbLower = bbLoBuf[0];
         }

         // Z-Score del precio actual respecto a la banda BB
         // Z = (precio - media) / (banda_sup - media)
         double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double halfWidth = m_bbUpper - m_bbMid;
         if(halfWidth > 0.0)
            m_zScore = (bid - m_bbMid) / halfWidth;

         // ATR en USD aproximado (para volumen base InpPhase1Volume)
         double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
         double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
         if(tickSize > 0.0)
            m_atrUSD = (m_atrPts / tickSize) * tickValue * InpPhase1Volume;
      }

      // ─── Actualizar Hurst y Tick Imbalance en nueva vela M1 ───────────
      if(newM1)
      {
         m_lastM1Bar    = curM1;
         m_hurst        = CalculateHurstRS(InpHurstPeriod);
         m_tickImbalance = CalculateTickImbalance(InpTickImbalanceLook);

         PrintFormat("[ZRCE][QUANT] Hurst=%.4f | Imbalance=%.4f | ATR=%.5f | Z=%.4f",
                     m_hurst, m_tickImbalance, m_atrPts, m_zScore);
      }
   }

   // ─── Getters ────────────────────────────────────────────────────────────
   double GetHurst()         { return m_hurst; }
   double GetTickImbalance() { return m_tickImbalance; }
   double GetATR()           { return m_atrPts; }
   double GetATR_USD()       { return m_atrUSD; }
   double GetBBUpper()       { return m_bbUpper; }
   double GetBBLower()       { return m_bbLower; }
   double GetBBMid()         { return m_bbMid; }
   double GetZScore()        { return m_zScore; }
   bool   IsMeanReverting()  { return (m_hurst < InpHurstThreshold); }
   bool   IsFlowToxic()      { return (m_tickImbalance > InpTickToxicThresh); }

   //--- Señal de entrada Phase 1 (Media Reversión + BB Exhaustion)
   //    COMBINA: H < umbral (régimen) + Toxicidad baja + Z-Score > umbral BB
   bool HasPhase1Signal(ENUM_ORDER_TYPE &outDir)
   {
      if(!IsMeanReverting()) return false; // Filtro 1: Régimen de mercado
      if(IsFlowToxic())      return false; // Filtro 2: Toxicidad del flujo

      if(MathAbs(m_zScore) < InpBBZScore) return false; // Sin exhaustión suficiente

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      // SEÑAL COMPRA: Precio debajo de banda inferior → sobreventa extrema
      if(m_zScore < -InpBBZScore && bid < m_bbLower)
      {
         outDir = ORDER_TYPE_BUY;
         return true;
      }

      // SEÑAL VENTA: Precio encima de banda superior → sobrecompra extrema
      if(m_zScore > InpBBZScore && bid > m_bbUpper)
      {
         outDir = ORDER_TYPE_SELL;
         return true;
      }

      return false;
   }
};


//+===========================================================================+
//|  SECCIÓN 4: CLASE CTradeExecution                                         |
//|  Responsabilidad: TODA comunicación con el servidor del bróker.            |
//|  Usa OrderSendAsync SIEMPRE (excepto emergencia). OnTradeTransaction        |
//|  confirma la ejecución. Backoff exponencial para errores recuperables.     |
//+===========================================================================+
class CTradeExecution
{
private:
   //--- Estructura de solicitud pendiente de confirmación
   struct SPendingReq
   {
      ulong           reqId;     ///< ID interno de la solicitud
      MqlTradeRequest req;       ///< Solicitud original (para reintentos)
      int             retries;   ///< Contador de reintentos realizados
      ulong           nextMs;    ///< Timestamp en ms del próximo reintento
      bool            confirmed; ///< true cuando OnTradeTransaction confirma
   };

   SPendingReq m_queue[];      ///< Cola circular de solicitudes pendientes
   int         m_queueSz;      ///< Tamaño actual de la cola
   ulong       m_reqCounter;   ///< Contador monótono de IDs de solicitud

   //--- Enviar solicitud asíncrona y gestionar errores
   bool SendAsync(MqlTradeRequest &req, ulong &outReqId)
   {
      outReqId = ++m_reqCounter;
      MqlTradeResult res;
      ZeroMemory(res);

      if(!OrderSendAsync(req, res))
      {
         int err = GetLastError();
         PrintFormat("[ZRCE][EXEC][WARN] OrderSendAsync error=%d. Encolando para reintento.", err);

         // Solo reintentar en errores recuperables:
         // 10004=Requote, 10016=Invalid stops, 10018=Mkt closed, 10019=No money
         if(err == 10004 || err == 10016 || err == 10018 || err == 10019 ||
            err == TRADE_RETCODE_REQUOTE || err == TRADE_RETCODE_PRICE_CHANGED)
         {
            EnqueueRetry(req, outReqId);
         }
         return false;
      }

      // Log de código de respuesta inmediata del servidor
      if(res.retcode != TRADE_RETCODE_PLACED &&
         res.retcode != TRADE_RETCODE_DONE &&
         res.retcode != TRADE_RETCODE_DONE_PARTIAL)
      {
         PrintFormat("[ZRCE][EXEC][WARN] Respuesta servidor: %u | %s",
                     res.retcode, res.comment);
         if(res.retcode == TRADE_RETCODE_REQUOTE || res.retcode == TRADE_RETCODE_PRICE_CHANGED)
            EnqueueRetry(req, outReqId);
      }

      return true;
   }

   void EnqueueRetry(MqlTradeRequest &req, ulong reqId)
   {
      if(m_queueSz >= ArraySize(m_queue))
         ArrayResize(m_queue, m_queueSz + 16);

      m_queue[m_queueSz].req       = req;
      m_queue[m_queueSz].reqId     = reqId;
      m_queue[m_queueSz].retries   = 0;
      m_queue[m_queueSz].nextMs    = GetTickCount64() + ZRCE_BACKOFF_BASE;
      m_queue[m_queueSz].confirmed = false;
      m_queueSz++;
   }

public:
   CTradeExecution() : m_queueSz(0), m_reqCounter(0)
   {
      ArrayResize(m_queue, 32);
   }

   ~CTradeExecution()
   {
      ArrayFree(m_queue);
   }

   //--------------------------------------------------------------------------
   //  SendMarketOrder: Orden de mercado asíncrona
   //  Compatible con cuentas ECN (IOC filling, desviación explícita)
   //--------------------------------------------------------------------------
   bool SendMarketOrder(string sym, ENUM_ORDER_TYPE type, double vol,
                        double sl, double tp, ulong magic, string comment,
                        ulong &outReqId)
   {
      MqlTradeRequest req;
      ZeroMemory(req);

      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = sym;
      req.type         = type;
      req.volume       = vol;
      req.sl           = sl;
      req.tp           = tp;
      req.magic        = magic;
      req.comment      = comment;
      req.type_filling = ORDER_FILLING_IOC;  // Pepperstone ECN soporta IOC
      req.deviation    = 10;                  // Desviación máxima: 1.0 pip
      req.price        = (type == ORDER_TYPE_BUY) ?
                         SymbolInfoDouble(sym, SYMBOL_ASK) :
                         SymbolInfoDouble(sym, SYMBOL_BID);

      return SendAsync(req, outReqId);
   }

   //--------------------------------------------------------------------------
   //  SendStopOrder: Orden STOP pendiente (ancla server-side)
   //  Se usa para colocar el nivel de recuperación en el servidor del bróker,
   //  eliminando la necesidad de "órdenes virtuales" con latencia residencial.
   //--------------------------------------------------------------------------
   bool SendStopOrder(string sym, ENUM_ORDER_TYPE type, double vol,
                      double price, double sl, double tp, ulong magic,
                      string comment, ulong &outReqId)
   {
      MqlTradeRequest req;
      ZeroMemory(req);

      req.action       = TRADE_ACTION_PENDING;
      req.symbol       = sym;
      req.type         = type;  // ORDER_TYPE_BUY_STOP o ORDER_TYPE_SELL_STOP
      req.volume       = vol;
      req.price        = price;
      req.sl           = sl;
      req.tp           = tp;
      req.magic        = magic;
      req.comment      = comment;
      req.type_filling = ORDER_FILLING_RETURN;
      req.type_time    = ORDER_TIME_GTC;      // Good Till Cancelled

      return SendAsync(req, outReqId);
   }

   //--------------------------------------------------------------------------
   //  ModifyPendingOrder: Front-Running del STOP server-side
   //  Mueve la orden pendiente hacia el nivel ATR real a medida que el
   //  precio converge, sin moverla antes para evitar invalidaciones de precio.
   //--------------------------------------------------------------------------
   bool ModifyPendingOrder(ulong ticket, double newPrice, double newSL, double newTP)
   {
      MqlTradeRequest req;
      ZeroMemory(req);

      req.action = TRADE_ACTION_MODIFY;
      req.order  = ticket;
      req.price  = newPrice;
      req.sl     = newSL;
      req.tp     = newTP;

      ulong dummy;
      return SendAsync(req, dummy);
   }

   //--- Modificar SL/TP de posición abierta (para trailing stop individual)
   bool ModifyPosition(ulong ticket, double newSL, double newTP)
   {
      MqlTradeRequest req;
      ZeroMemory(req);

      req.action   = TRADE_ACTION_SLTP;
      req.position = ticket;
      req.sl       = newSL;
      req.tp       = newTP;

      ulong dummy;
      return SendAsync(req, dummy);
   }

   //--- Cerrar posición específica (parcial o total)
   bool ClosePosition(string sym, ulong ticket, double volume = 0.0)
   {
      if(!PositionSelectByTicket(ticket)) return false;

      double posVol = PositionGetDouble(POSITION_VOLUME);
      double closeVol = (volume <= 0.0 || volume >= posVol) ? posVol : volume;
      ENUM_ORDER_TYPE cType = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                               ORDER_TYPE_SELL : ORDER_TYPE_BUY;

      MqlTradeRequest req;
      ZeroMemory(req);

      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = sym;
      req.position     = ticket;
      req.type         = cType;
      req.volume       = closeVol;
      req.price        = (cType == ORDER_TYPE_SELL) ?
                         SymbolInfoDouble(sym, SYMBOL_BID) :
                         SymbolInfoDouble(sym, SYMBOL_ASK);
      req.deviation    = 10;
      req.type_filling = ORDER_FILLING_IOC;

      ulong dummy;
      return SendAsync(req, dummy);
   }

   //--------------------------------------------------------------------------
   //  CloseAllBasket: Cierra toda la cesta de forma asíncrona
   //  Itera posiciones y órdenes pendientes pertenecientes a este EA.
   //  La identificación se realiza por el prefijo del número mágico.
   //--------------------------------------------------------------------------
   bool CloseAllBasket(string sym, ulong magicBase)
   {
      bool anySent = false;

      // Cerrar posiciones abiertas
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(PositionGetSymbol(i) != sym) continue;
         ulong posMagic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if((posMagic / 10000UL) != magicBase) continue;

         ulong ticket = PositionGetInteger(POSITION_TICKET);
         ClosePosition(sym, ticket);
         anySent = true;
      }

      // Cancelar órdenes pendientes de la cesta
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong ordTicket = OrderGetTicket(i);
         if(ordTicket == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != sym) continue;
         ulong ordMagic = (ulong)OrderGetInteger(ORDER_MAGIC);
         if((ordMagic / 10000UL) != magicBase) continue;

         MqlTradeRequest req;
         ZeroMemory(req);
         req.action = TRADE_ACTION_REMOVE;
         req.order  = ordTicket;
         ulong dummy;
         SendAsync(req, dummy);
      }

      return anySent;
   }

   //--------------------------------------------------------------------------
   //  EmergencyCloseAll: ÚNICA excepción a la regla asíncrona.
   //  Uso: margen en nivel crítico. Se usa CTrade síncrono con alta desviación.
   //  Justificación: el tiempo de respuesta del servidor NO puede esperarse
   //  cuando el bróker puede Stop Out en milisegundos.
   //--------------------------------------------------------------------------
   bool EmergencyCloseAll(string sym, ulong magicBase)
   {
      CTrade trade;
      trade.SetDeviationInPoints(100);
      trade.SetTypeFilling(ORDER_FILLING_IOC);

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         if(PositionGetSymbol(i) != sym) continue;
         ulong posMagic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if((posMagic / 10000UL) != magicBase) continue;

         ulong ticket = PositionGetInteger(POSITION_TICKET);
         if(!trade.PositionClose(ticket, 100))
            PrintFormat("[ZRCE][EXEC][EMERGENCY] Fallo cierre ticket=%llu: %u",
                        ticket, trade.ResultRetcode());
      }
      return true;
   }

   //--------------------------------------------------------------------------
   //  ProcessRetries: Motor de Backoff Exponencial
   //  LLAMAR DESDE OnTimer() O OnTick() — NUNCA usar Sleep().
   //  Intervalo de reintento: ZRCE_BACKOFF_BASE * 2^n milisegundos
   //  (200ms, 400ms, 800ms, 1600ms, 3200ms → abandono)
   //--------------------------------------------------------------------------
   void ProcessRetries()
   {
      ulong nowMs = GetTickCount64();

      for(int i = m_queueSz - 1; i >= 0; i--)
      {
         // Eliminar solicitudes ya confirmadas por OnTradeTransaction
         if(m_queue[i].confirmed)
         {
            m_queue[i] = m_queue[m_queueSz - 1];
            m_queueSz--;
            continue;
         }

         if(nowMs < m_queue[i].nextMs) continue; // Aún no es tiempo de reintentar

         // Agotar reintentos → abandonar
         if(m_queue[i].retries >= ZRCE_RETRY_MAX)
         {
            PrintFormat("[ZRCE][EXEC][ABANDON] Solicitud %llu abandonada tras %d reintentos.",
                        m_queue[i].reqId, m_queue[i].retries);
            m_queue[i] = m_queue[m_queueSz - 1];
            m_queueSz--;
            continue;
         }

         // Actualizar precio a mercado actual (el original puede ser stale)
         if(m_queue[i].req.action == TRADE_ACTION_DEAL)
         {
            m_queue[i].req.price = (m_queue[i].req.type == ORDER_TYPE_BUY) ?
                                    SymbolInfoDouble(m_queue[i].req.symbol, SYMBOL_ASK) :
                                    SymbolInfoDouble(m_queue[i].req.symbol, SYMBOL_BID);
         }

         MqlTradeResult res;
         ZeroMemory(res);
         if(OrderSendAsync(m_queue[i].req, res))
         {
            m_queue[i].retries++;
            // Backoff exponencial: 200 * 2^retries
            ulong backoff = (ulong)(ZRCE_BACKOFF_BASE * MathPow(2.0, m_queue[i].retries));
            m_queue[i].nextMs = nowMs + backoff;
            PrintFormat("[ZRCE][EXEC][RETRY] Solicitud %llu | Intento %d | Próx en %llums",
                        m_queue[i].reqId, m_queue[i].retries, backoff);
         }
      }
   }

   //--- Confirmar solicitud pendiente desde OnTradeTransaction()
   void OnTransaction(const MqlTradeTransaction &trans)
   {
      // Buscar en la cola y marcar como confirmada
      for(int i = 0; i < m_queueSz; i++)
      {
         if(m_queue[i].confirmed) continue;
         if(trans.order    == m_queue[i].req.order    ||
            trans.position == m_queue[i].req.position ||
            trans.deal     == m_queue[i].req.order)
         {
            m_queue[i].confirmed = true;
            PrintFormat("[ZRCE][EXEC][CONFIRM] Solicitud %llu confirmada via OnTradeTransaction",
                        m_queue[i].reqId);
            break;
         }
      }
   }
};


//+===========================================================================+
//|  SECCIÓN 5: CLASE CZoneRecovery                                           |
//|  Responsabilidad: Lógica de rejilla asimétrica, números mágicos           |
//|  compuestos [Base][AssetID][Nivel], distancias dinámicas ATR,             |
//|  gestión de órdenes STOP server-side, trailing de equidad en USD.         |
//+===========================================================================+
class CZoneRecovery
{
private:
   //--- Registro de un nivel de la rejilla de recuperación
   struct SZoneLevel
   {
      int               level;          ///< Nivel (0=Phase1, 1=Lock, 2..N=Recovery)
      ulong             posTicket;      ///< Ticket de la posición abierta
      ulong             pendTicket;     ///< Ticket de la orden STOP en servidor
      double            volume;         ///< Lotes de este nivel
      ENUM_POSITION_TYPE direction;     ///< BUY o SELL
      double            openPrice;      ///< Precio de apertura
   };

   SZoneLevel         m_lvl[];          ///< Array de niveles activos
   int                m_lvlCount;       ///< Niveles activos actualmente
   ulong              m_magicBase;      ///< Magic base del EA
   string             m_sym;            ///< Símbolo
   int                m_assetId;        ///< ID numérico del símbolo
   ENUM_POSITION_TYPE m_initDir;        ///< Dirección de Phase 1

   double             m_zoneDist;       ///< Distancia de zona en puntos (ATR * Mult)
   double             m_targetUSD;      ///< Objetivo monetario dinámico
   double             m_peakNetProfit;  ///< Pico del beneficio neto flotante
   bool               m_trailActive;    ///< Trailing de equidad activado

   //--- Hash simple del símbolo para el componente AssetID del magic
   int ComputeAssetID(string sym) const
   {
      int id = 0;
      for(int i = 0; i < StringLen(sym); i++)
         id = (id * 31 + (int)StringGetCharacter(sym, i)) % 99;
      return MathAbs(id) + 1; // Rango: 1-99
   }

   //--- Construir número mágico compuesto: Base * 10000 + AssetID * 100 + Nivel
   //    Ejemplo: Base=202401, AssetID=6(EURUSD), Nivel=3 → 2024010603
   ulong BuildMagic(int level) const
   {
      return m_magicBase * 10000UL + (ulong)m_assetId * 100UL + (ulong)level;
   }

   //--- Comprobar si un magic pertenece a esta instancia del EA
   bool IsMagicMine(ulong magic) const
   {
      return ((magic / 10000UL) == m_magicBase);
   }

   //--------------------------------------------------------------------------
   //  Cálculo de lotes por nivel (secuencia asimétrica)
   //  La secuencia garantiza que el TP global de la cesta cubra todas las
   //  pérdidas previas más el objetivo. Derivación:
   //
   //  Nivel 0 (Phase1): V₀ = InpPhase1Volume
   //  Nivel 1 (Lock):   V₁ = V₀ (neutralización 1:1)
   //  Nivel 2+:         Vₙ = V₀ * 2^(n-1)
   //  → 0.01, 0.01, 0.02, 0.04, 0.08, 0.16, 0.32, 0.64
   //--------------------------------------------------------------------------
   double LotForLevel(int level) const
   {
      double minLot = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_MAX);
      double stepLot = SymbolInfoDouble(m_sym, SYMBOL_VOLUME_STEP);

      double vol = (level <= 1) ? InpPhase1Volume :
                                  InpPhase1Volume * MathPow(2.0, level - 1);

      // Normalizar al paso de volumen del bróker
      vol = MathFloor(vol / stepLot) * stepLot;
      return MathMax(minLot, MathMin(maxLot, NormalizeDouble(vol, 2)));
   }

public:
   CZoneRecovery(ulong magicBase, string sym)
      : m_magicBase(magicBase), m_sym(sym),
        m_lvlCount(0), m_zoneDist(0.0),
        m_targetUSD(0.0), m_peakNetProfit(0.0),
        m_trailActive(false), m_initDir(POSITION_TYPE_BUY)
   {
      m_assetId = ComputeAssetID(sym);
      ArrayResize(m_lvl, ZRCE_MAX_LEVELS + 2);
      ZeroMemory(m_lvl);
      PrintFormat("[ZRCE][ZONE] Init: Símbolo=%s AssetID=%d MagicBase=%llu",
                  sym, m_assetId, magicBase);
   }

   ~CZoneRecovery()
   {
      ArrayFree(m_lvl);
   }

   //--------------------------------------------------------------------------
   //  DISASTER RECOVERY: Reconstruir FSM desde posiciones abiertas
   //  Se invoca en OnInit() tras un reinicio por corte de energía o error.
   //  Parsea los números mágicos para reconstruir el estado completo.
   //--------------------------------------------------------------------------
   bool ReconstructFromOpenPositions()
   {
      m_lvlCount = 0;
      ZeroMemory(m_lvl);

      // ─── Reconstruir posiciones abiertas ──────────────────────────────
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(PositionGetSymbol(i) != m_sym) continue;
         ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(!IsMagicMine(magic)) continue;

         int level = (int)(magic % 100UL);
         if(m_lvlCount >= ZRCE_MAX_LEVELS + 2) break;

         m_lvl[m_lvlCount].level      = level;
         m_lvl[m_lvlCount].posTicket  = PositionGetInteger(POSITION_TICKET);
         m_lvl[m_lvlCount].volume     = PositionGetDouble(POSITION_VOLUME);
         m_lvl[m_lvlCount].direction  = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         m_lvl[m_lvlCount].openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
         m_lvl[m_lvlCount].pendTicket = 0;
         m_lvlCount++;

         if(level == 0)
            m_initDir = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      }

      // ─── Asociar órdenes pendientes (STOPs de servidor) ─────────────
      for(int i = 0; i < OrdersTotal(); i++)
      {
         ulong ordTicket = OrderGetTicket(i);
         if(ordTicket == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != m_sym) continue;

         ulong ordMagic = (ulong)OrderGetInteger(ORDER_MAGIC);
         if(!IsMagicMine(ordMagic)) continue;

         int ordLevel = (int)(ordMagic % 100UL);
         for(int j = 0; j < m_lvlCount; j++)
         {
            if(m_lvl[j].level == ordLevel)
            {
               m_lvl[j].pendTicket = ordTicket;
               break;
            }
         }
      }

      if(m_lvlCount > 0)
      {
         PrintFormat("[ZRCE][ZONE][RECOVERY] %d nivel(es) reconstruido(s) exitosamente", m_lvlCount);
         return true;
      }
      return false;
   }

   //--- Abrir Phase 1 (operación primaria, nivel 0)
   bool OpenPhase1(CTradeExecution *exec, ENUM_ORDER_TYPE dir)
   {
      if(m_lvlCount > 0)
      {
         Print("[ZRCE][ZONE][WARN] OpenPhase1: ya hay niveles activos");
         return false;
      }

      ulong magic = BuildMagic(0);
      ulong reqId;

      if(!exec.SendMarketOrder(m_sym, dir, InpPhase1Volume,
                               0, 0, magic, InpEAComment + "_P1L0", reqId))
      {
         Print("[ZRCE][ZONE][ERR] Fallo al abrir Phase 1");
         return false;
      }

      m_initDir            = (dir == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      m_lvl[0].level       = 0;
      m_lvl[0].volume      = InpPhase1Volume;
      m_lvl[0].direction   = m_initDir;
      m_lvl[0].posTicket   = 0; // Se asignará en OnTradeTransaction
      m_lvl[0].pendTicket  = 0;
      m_lvlCount           = 1;
      m_trailActive        = false;
      m_peakNetProfit      = 0.0;

      PrintFormat("[ZRCE][ZONE] Phase 1 enviada: %s %.2f lots | Magic=%llu",
                  (dir==ORDER_TYPE_BUY) ? "BUY" : "SELL",
                  InpPhase1Volume, magic);
      return true;
   }

   //--- Actualizar ticket de la posición Level 0 desde OnTradeTransaction
   void UpdatePhase1Ticket(ulong ticket)
   {
      for(int i = 0; i < m_lvlCount; i++)
      {
         if(m_lvl[i].level == 0 && m_lvl[i].posTicket == 0)
         {
            m_lvl[i].posTicket = ticket;
            break;
         }
      }
   }

   //--------------------------------------------------------------------------
   //  ActivateLock: Nivel 1 - Hedge 1:1 para neutralizar drawdown inicial
   //  Secuencia OBLIGATORIA: Phase1 (0.01) → Lock (0.01 opuesto)
   //  Esto fija la pérdida flotante y permite analizar toxicidad antes de
   //  escalar el capital con lotes mayores.
   //--------------------------------------------------------------------------
   bool ActivateLock(CTradeExecution *exec)
   {
      if(m_lvlCount < 1) return false;

      ENUM_ORDER_TYPE lockDir = (m_initDir == POSITION_TYPE_BUY) ?
                                 ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      ulong magic = BuildMagic(1);
      ulong reqId;

      if(!exec.SendMarketOrder(m_sym, lockDir, InpPhase1Volume,
                               0, 0, magic, InpEAComment + "_LOCK1", reqId))
         return false;

      m_lvl[m_lvlCount].level     = 1;
      m_lvl[m_lvlCount].volume    = InpPhase1Volume;
      m_lvl[m_lvlCount].direction = (lockDir == ORDER_TYPE_BUY) ?
                                     POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      m_lvl[m_lvlCount].posTicket = 0;
      m_lvl[m_lvlCount].pendTicket= 0;
      m_lvlCount++;

      // Colocar inmediatamente la orden STOP de recuperación nivel 2 en servidor
      PlaceServerStopForNextLevel(exec, 2);

      PrintFormat("[ZRCE][ZONE] Lock neutro activado: %s %.2f | Magic=%llu",
                  (lockDir==ORDER_TYPE_BUY)?"BUY":"SELL", InpPhase1Volume, magic);
      return true;
   }

   //--------------------------------------------------------------------------
   //  PlaceServerStopForNextLevel: Ancla STOP en el servidor del bróker
   //  Calcula el precio de recuperación basado en ATR * multiplicador.
   //  La orden vive en el servidor → inmune a latencia/desconexiones.
   //--------------------------------------------------------------------------
   bool PlaceServerStopForNextLevel(CTradeExecution *exec, int nextLevel)
   {
      if(nextLevel > ZRCE_MAX_LEVELS || m_zoneDist <= 0.0) return false;

      double point = SymbolInfoDouble(m_sym, SYMBOL_POINT);
      double bid   = SymbolInfoDouble(m_sym, SYMBOL_BID);
      double ask   = SymbolInfoDouble(m_sym, SYMBOL_ASK);

      // La dirección del nivel de recuperación alterna respecto al inicial
      bool recIsBuy = (nextLevel % 2 == 0) ?
                      (m_initDir == POSITION_TYPE_BUY) :
                      (m_initDir != POSITION_TYPE_BUY);

      ENUM_ORDER_TYPE stopType = recIsBuy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;

      // Precio base: ATR alejado del mid precio actual + offset de seguridad
      double basePrice = recIsBuy ?
                         ask + (m_zoneDist + InpPendingOffsetPts) * point :
                         bid - (m_zoneDist + InpPendingOffsetPts) * point;

      // Normalizar al tick size del símbolo
      double tickSz = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_SIZE);
      basePrice = MathRound(basePrice / tickSz) * tickSz;

      double vol   = LotForLevel(nextLevel);
      ulong  magic = BuildMagic(nextLevel);
      ulong  reqId;

      exec.SendStopOrder(m_sym, stopType, vol, basePrice, 0, 0,
                         magic, InpEAComment + "_STP" + IntegerToString(nextLevel),
                         reqId);

      PrintFormat("[ZRCE][ZONE] STOP server-side: Niv=%d %s Px=%.5f Vol=%.2f Magic=%llu",
                  nextLevel, recIsBuy?"BUY_STOP":"SELL_STOP",
                  basePrice, vol, magic);
      return true;
   }

   //--------------------------------------------------------------------------
   //  UpdateServerStopAnchors: Front-Running del ancla STOP
   //  A medida que el precio se aproxima al nivel de recuperación, se mueve
   //  la orden STOP hacia el nivel ATR ideal, reduciendo el deslizamiento.
   //  Solo ejecutar cuando el spread es aceptable.
   //--------------------------------------------------------------------------
   void UpdateServerStopAnchors(CTradeExecution *exec)
   {
      if(m_zoneDist <= 0.0) return;

      double point  = SymbolInfoDouble(m_sym, SYMBOL_POINT);
      double bid    = SymbolInfoDouble(m_sym, SYMBOL_BID);
      double ask    = SymbolInfoDouble(m_sym, SYMBOL_ASK);
      double tickSz = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_SIZE);

      for(int i = 0; i < m_lvlCount; i++)
      {
         if(m_lvl[i].pendTicket == 0) continue;

         ulong pt = m_lvl[i].pendTicket;
         if(!OrderSelect(pt)) { m_lvl[i].pendTicket = 0; continue; }

         ENUM_ORDER_TYPE ordType  = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         double currStopPx        = OrderGetDouble(ORDER_PRICE_OPEN);

         // Calcular precio ideal sin offset (movernos hacia el nivel real)
         double idealPx;
         if(ordType == ORDER_TYPE_BUY_STOP)
            idealPx = ask + m_zoneDist * point;
         else
            idealPx = bid - m_zoneDist * point;

         idealPx = MathRound(idealPx / tickSz) * tickSz;

         // Solo modificar si el desplazamiento es >= 1 punto (evitar spam de órdenes)
         if(MathAbs(currStopPx - idealPx) >= point)
            exec.ModifyPendingOrder(pt, idealPx, 0, 0);
      }
   }

   //--------------------------------------------------------------------------
   //  ExecuteDirtyHedge: Hedge de emergencia cuando la orden STOP falla
   //  y el precio rompe la zona con spread excesivo.
   //  1. Ejecuta orden de mercado incondicional para proteger margen.
   //  2. Aumenta el objetivo USD para compensar el coste del spread/slippage.
   //--------------------------------------------------------------------------
   void ExecuteDirtyHedge(CTradeExecution *exec, int failedLevel)
   {
      bool hedgeIsBuy = (failedLevel % 2 == 0) ?
                        (m_initDir == POSITION_TYPE_BUY) :
                        (m_initDir != POSITION_TYPE_BUY);

      ENUM_ORDER_TYPE hedgeDir = hedgeIsBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      double vol = LotForLevel(failedLevel);

      ulong magic = BuildMagic(failedLevel);
      ulong reqId;
      exec.SendMarketOrder(m_sym, hedgeDir, vol, 0, 0, magic,
                           InpEAComment + "_DIRTY" + IntegerToString(failedLevel), reqId);

      // Compensar el coste del spread implícito en el Dirty Hedge
      double spreadPts = (double)SymbolInfoInteger(m_sym, SYMBOL_SPREAD);
      double tickVal   = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSz    = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_SIZE);
      double spreadCost = 0.0;
      if(tickSz > 0.0)
         spreadCost = (spreadPts * SymbolInfoDouble(m_sym, SYMBOL_POINT) / tickSz) * tickVal * vol;

      m_targetUSD += spreadCost; // Elevar objetivo para recuperar coste del hedge sucio

      PrintFormat("[ZRCE][ZONE] Dirty Hedge ejecutado: Niv=%d %s Vol=%.2f | Nuevo Target=%.4f$",
                  failedLevel, hedgeIsBuy?"BUY":"SELL", vol, m_targetUSD);

      m_lvl[m_lvlCount].level     = failedLevel;
      m_lvl[m_lvlCount].volume    = vol;
      m_lvl[m_lvlCount].direction = hedgeIsBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      m_lvl[m_lvlCount].posTicket = 0;
      m_lvlCount++;
   }

   //--- Actualizar objetivo dinámico en USD y distancia de zona (ATR-driven)
   void UpdateTargetUSD(double atrPts, double mult)
   {
      if(atrPts <= 0.0) return;

      double tickVal = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_VALUE);
      double tickSz  = SymbolInfoDouble(m_sym, SYMBOL_TRADE_TICK_SIZE);
      if(tickSz <= 0.0) return;

      // Target_USD = ATR_pts * Multiplicador * (TickValue/TickSize) * VolumenBase
      m_targetUSD  = (atrPts * mult) * (tickVal / tickSz) * InpPhase1Volume;
      m_zoneDist   = atrPts * InpZoneATRMult; // Distancia de zona en puntos

      m_targetUSD  = MathMax(m_targetUSD, 0.50); // Mínimo absoluto: $0.50
   }

   //--- Calcular P&L neto total de la cesta (posiciones + swaps)
   double GetTotalNetProfit() const
   {
      double total = 0.0;
      for(int i = 0; i < PositionsTotal(); i++)
      {
         if(PositionGetSymbol(i) != m_sym) continue;
         ulong pm = (ulong)PositionGetInteger(POSITION_MAGIC);
         if(!IsMagicMine(pm)) continue; // Necesitamos acceso al método privado
         total += PositionGetDouble(POSITION_PROFIT);
         total += PositionGetDouble(POSITION_SWAP);
      }
      return total;
   }

   //--- Verificar si se activa el trailing de equidad (P&L >= objetivo)
   bool CheckBasketTrailingTrigger()
   {
      double netPnL = GetTotalNetProfit();
      if(netPnL >= m_targetUSD && m_targetUSD > 0.0)
      {
         if(!m_trailActive)
         {
            m_trailActive    = true;
            m_peakNetProfit  = netPnL;
            PrintFormat("[ZRCE][ZONE] Trailing de cesta activado. Target=%.4f$ PnL=%.4f$",
                        m_targetUSD, netPnL);
         }
         else if(netPnL > m_peakNetProfit)
         {
            m_peakNetProfit = netPnL; // Actualizar pico
         }
      }
      return m_trailActive;
   }

   //--- ¿Debe cerrarse la cesta? (retroceso desde pico > InpBasketTrailPct)
   bool ShouldCloseBasket()
   {
      if(!m_trailActive) return false;

      double netPnL  = GetTotalNetProfit();
      if(netPnL > m_peakNetProfit) m_peakNetProfit = netPnL; // Nuevo pico

      double pullback   = m_peakNetProfit - netPnL;
      double threshold  = m_peakNetProfit * InpBasketTrailPct;

      if(threshold > 0.0 && pullback >= threshold)
      {
         PrintFormat("[ZRCE][ZONE] Cierre por trailing: Pico=%.4f$ Actual=%.4f$ Retroceso=%.1f%%",
                     m_peakNetProfit, netPnL, (pullback/m_peakNetProfit)*100.0);
         return true;
      }
      return false;
   }

   //--------------------------------------------------------------------------
   //  ManageSinglePositionTrail: ATR Trailing Stop + Break-Even (Phase 1 solo)
   //  Escenario 1 de la especificación: operación única, trailing en pips/puntos.
   //  Break-Even: SL se mueve a apertura cuando beneficio > InpBEOffsetPts.
   //  Trailing: SL se arrastra a ATR * Mult detrás del precio.
   //--------------------------------------------------------------------------
   void ManageSinglePositionTrail(CTradeExecution *exec, double atrPts)
   {
      if(m_lvlCount != 1 || m_lvl[0].posTicket == 0) return;

      ulong  ticket = m_lvl[0].posTicket;
      if(!PositionSelectByTicket(ticket)) return;

      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPx   = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double point    = SymbolInfoDouble(m_sym, SYMBOL_POINT);
      double bid      = SymbolInfoDouble(m_sym, SYMBOL_BID);
      double ask      = SymbolInfoDouble(m_sym, SYMBOL_ASK);
      double trailDist = atrPts * InpTrailATRMult;
      double newSL;

      if(pType == POSITION_TYPE_BUY)
      {
         // Break-Even: SL → apertura cuando beneficio > BE offset
         double beLvl = openPx + InpBEOffsetPts * point;
         if(bid >= beLvl && (currentSL < openPx || currentSL <= 0.0))
         {
            exec.ModifyPosition(ticket, openPx + point, 0); // SL = apertura + 1pt
            return;
         }
         // Trailing ATR: SL sigue al precio desde abajo
         newSL = NormalizeDouble(bid - trailDist, (int)SymbolInfoInteger(m_sym, SYMBOL_DIGITS));
         if(newSL > currentSL && newSL > 0.0)
            exec.ModifyPosition(ticket, newSL, 0);
      }
      else // POSITION_TYPE_SELL
      {
         double beLvl = openPx - InpBEOffsetPts * point;
         if(ask <= beLvl && (currentSL > openPx || currentSL <= 0.0))
         {
            exec.ModifyPosition(ticket, openPx - point, 0);
            return;
         }
         newSL = NormalizeDouble(ask + trailDist, (int)SymbolInfoInteger(m_sym, SYMBOL_DIGITS));
         if((newSL < currentSL || currentSL <= 0.0) && newSL > 0.0)
            exec.ModifyPosition(ticket, newSL, 0);
      }
   }

   // Getters
   int    GetLevelCount()    { return m_lvlCount; }
   double GetTargetUSD()     { return m_targetUSD; }
   double GetPeakNetProfit() { return m_peakNetProfit; }
   bool   IsTrailActive()    { return m_trailActive; }
   double GetZoneDist()      { return m_zoneDist; }
   bool   HasActiveBasket()  { return (m_lvlCount > 0); }

   void Reset()
   {
      m_lvlCount      = 0;
      m_trailActive   = false;
      m_peakNetProfit = 0.0;
      ZeroMemory(m_lvl);
   }
};


//+===========================================================================+
//|  SECCIÓN 6: CLASE CRiskShield                                             |
//|  Responsabilidad: Protección de capital en tiempo real. Monitoriza         |
//|  spread, margen, ghost ticks y restricciones de fin de semana.            |
//+===========================================================================+
class CRiskShield
{
private:
   double m_maxSpreadPts;
   double m_minMarginPct;
   double m_emergMarginPct;

public:
   CRiskShield(double maxSpread, double minMargin, double emergMargin)
      : m_maxSpreadPts(maxSpread),
        m_minMarginPct(minMargin),
        m_emergMarginPct(emergMargin) {}

   //--- Verificar spread actual (rechazar entrada si es demasiado alto)
   bool IsSpreadOK() const
   {
      long spreadPts = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      return ((double)spreadPts <= m_maxSpreadPts);
   }

   //--- Verificar nivel de margen mínimo para nuevas operaciones
   bool IsMarginOK() const
   {
      double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(ml == 0.0) return true; // 0 = sin margen usado = libre
      return (ml >= m_minMarginPct);
   }

   //--- Verificar nivel de emergencia (frente-correr el Stop Out del bróker)
   //    Pepperstone Stop Out = 50%. Actuamos al 80% → margen de reacción de 30%.
   bool IsEmergencyMargin() const
   {
      double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
      if(ml == 0.0) return false;
      return (ml <= m_emergMarginPct);
   }

   //--------------------------------------------------------------------------
   //  Ghost Tick Validation: Rechazar si el timestamp del símbolo difiere
   //  del tiempo del servidor en más de ZRCE_GHOST_SECONDS.
   //  Causa típica: feed de datos colgado o conexión intermitente.
   //--------------------------------------------------------------------------
   bool IsGhostTick() const
   {
      datetime serverTime = TimeCurrent();
      datetime symTime    = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
      return (MathAbs((long)serverTime - (long)symTime) > ZRCE_GHOST_SECONDS);
   }

   //--- Verificar bloqueo de fin de semana (Viernes InpFridayBlockHour+)
   bool IsWeekendBlock() const
   {
      if(!InpLiquidateWeekend) return false;
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.day_of_week == 5 && dt.hour >= InpFridayBlockHour) return true;
      if(dt.day_of_week == 6 || dt.day_of_week == 0)          return true;
      return false;
   }

   //--- Verificar si hay que liquidar por cierre del fin de semana
   bool ShouldLiquidateWeekend() const
   {
      if(!InpLiquidateWeekend) return false;
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      return (dt.day_of_week == 5 && dt.hour >= InpFridayLiquidHour);
   }

   //--- Obtener descripción de los bloqueos activos (para HUD)
   string GetBlockerString() const
   {
      string s = "";
      if(!IsSpreadOK())       s += "SPREAD|";
      if(!IsMarginOK())       s += "MARGEN|";
      if(IsEmergencyMargin()) s += "EMERGENCIA|";
      if(IsGhostTick())       s += "GHOST_TICK|";
      if(IsWeekendBlock())    s += "WEEKEND|";
      if(StringLen(s) == 0)   return "NINGUNO";
      StringReplace(s, "|", " ");
      StringTrimRight(s);   // Modifica s en su lugar (retorna int, no string — MQL5)
      return s;
   }
};


//+===========================================================================+
//|  SECCIÓN 7: CLASE CHUD                                                    |
//|  Responsabilidad: Panel de control visual en español.                      |
//|  Ancla: CORNER_RIGHT_UPPER | Ancho: 10% del chart en píxeles              |
//|  Modo oscuro con OBJ_RECTANGLE_LABEL (alpha via OBJPROP_BACK=true)        |
//|  Responsivo: OnChartEvent(CHARTEVENT_CHART_CHANGE) recalcula el ancho.    |
//+===========================================================================+
class CHUD
{
private:
   string   m_pfx;       ///< Prefijo único de objetos
   int      m_xOffset;   ///< Distancia X desde la esquina
   int      m_yOffset;   ///< Distancia Y desde la esquina
   int      m_width;     ///< Ancho del panel (10% del chart)
   int      m_lineH;     ///< Altura de cada línea en píxeles

   enum { NUM_LINES = 6 };  // MQL5: static const int no permite init en clase → usar enum

   string N(string suffix) { return m_pfx + suffix; }

   //--- Calcular ancho estrictamente como 10% del ancho del gráfico en píxeles
   int CalcWidth()
   {
      long w = ChartGetInteger(0, CHART_WIDTH_IN_PIXELS);
      return (int)(w * 0.10);
   }

   void CreateBackground()
   {
      string name = N("_BG");
      if(ObjectFind(0, name) >= 0) ObjectDelete(0, name);
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER,      CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE,   (int)m_xOffset);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE,   (int)m_yOffset);
      ObjectSetInteger(0, name, OBJPROP_XSIZE,       (int)m_width);
      ObjectSetInteger(0, name, OBJPROP_YSIZE,       (int)(m_lineH * (NUM_LINES + 1) + 8));
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR,     C'18,18,28');  // Negro azulado oscuro
      ObjectSetInteger(0, name, OBJPROP_COLOR,       C'50,60,90');  // Borde gris-azul sutil
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_BACK,        true);          // Semitransparente
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE,  false);
      ObjectSetInteger(0, name, OBJPROP_ZORDER,      0);
   }

   void SetOrUpdateLabel(string suffix, int yPos, string text, color clr)
   {
      string name = N(suffix);
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  InpHUDFontSize);
         ObjectSetString( 0, name, OBJPROP_FONT,      "Courier New");
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
         ObjectSetInteger(0, name, OBJPROP_BACK,      false);
         ObjectSetInteger(0, name, OBJPROP_ZORDER,    1);
      }
      ObjectSetString( 0, name, OBJPROP_TEXT,      text);
      ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, (int)(m_xOffset + 6));
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, (int)(m_yOffset + yPos));
   }

public:
   CHUD(string prefix) : m_pfx(prefix), m_xOffset(120), m_yOffset(20), m_lineH(20)
   {
      m_width = 150; // Placeholder hasta Init()
   }

   ~CHUD() { ObjectsDeleteAll(0, m_pfx); }

   bool Init()
   {
      m_width = CalcWidth();
      m_width = MathMax(m_width, 140); // Mínimo absoluto de legibilidad
      CreateBackground();
      SetOrUpdateLabel("_L0", 4,                        "┤ ZRCE v1.0 ├",       C'80,120,200');
      SetOrUpdateLabel("_L1", 4 + m_lineH,              "FSM: --",              clrWhite);
      SetOrUpdateLabel("_L2", 4 + m_lineH * 2,          "Filtros: --",          clrYellow);
      SetOrUpdateLabel("_L3", 4 + m_lineH * 3,          "Dist.Cierre: --",      clrWhite);
      SetOrUpdateLabel("_L4", 4 + m_lineH * 4,          "PnL Sesion: --",       clrWhite);
      SetOrUpdateLabel("_L5", 4 + m_lineH * 5,          "Equity: --",           clrWhite);
      ChartRedraw(0);
      return true;
   }

   void Update(ENUM_FSM_STATE state, string blockers,
               double distClose, double sessionPnL, double equity)
   {
      string stateStr;
      color  stateClr;
      switch(state)
      {
         case FSM_IDLE:            stateStr = "INACTIVO";        stateClr = clrGray;        break;
         case FSM_PHASE1_ACTIVE:   stateStr = "FASE 1 ACTIVA";   stateClr = clrLimeGreen;   break;
         case FSM_ZONE_RECOVERY:   stateStr = "RECUPERACION";    stateClr = clrOrange;      break;
         case FSM_BASKET_TRAILING: stateStr = "TRAIL CESTA";     stateClr = clrDodgerBlue;  break;
         case FSM_EMERGENCY_CLOSE: stateStr = "!!EMERGENCIA!!";  stateClr = clrRed;         break;
         case FSM_WEEKEND_BLOCK:   stateStr = "BLOQ WEEKEND";    stateClr = clrDimGray;     break;
         default:                  stateStr = "???";             stateClr = clrWhite;       break;
      }

      color pnlClr = (sessionPnL >= 0.0) ? clrLimeGreen : clrOrangeRed;
      string distStr = (distClose >= 0.0) ?
                       DoubleToString(distClose, 2) + "$" :
                       "(" + DoubleToString(-distClose, 2) + "$)";

      SetOrUpdateLabel("_L1", 4 + m_lineH,     "FSM: " + stateStr,                          stateClr);
      SetOrUpdateLabel("_L2", 4 + m_lineH * 2, "Filtros: " + blockers,                       clrYellow);
      SetOrUpdateLabel("_L3", 4 + m_lineH * 3, "Dist: " + distStr,                           clrWhite);
      SetOrUpdateLabel("_L4", 4 + m_lineH * 4, "PnL: " + DoubleToString(sessionPnL, 2) + "$",pnlClr);
      SetOrUpdateLabel("_L5", 4 + m_lineH * 5, "Eq: " + DoubleToString(equity, 2) + "$",    clrWhite);

      ChartRedraw(0);
   }

   //--- Recalcular ancho al evento de redimensión de ventana (OnChartEvent)
   void OnResize()
   {
      m_width = MathMax(CalcWidth(), 140);
      if(ObjectFind(0, N("_BG")) >= 0)
         ObjectSetInteger(0, N("_BG"), OBJPROP_XSIZE, m_width);

      // Reposicionar todas las etiquetas
      string labels[] = {"_L0","_L1","_L2","_L3","_L4","_L5"};
      for(int i = 0; i < ArraySize(labels); i++)
      {
         string nm = N(labels[i]);
         if(ObjectFind(0, nm) >= 0)
         ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, (int)(m_xOffset + 6));
      }
      ChartRedraw(0);
   }
};


//+===========================================================================+
//|  SECCIÓN 8: VARIABLES GLOBALES Y FSM                                      |
//+===========================================================================+

CQuantEngine*    g_quant   = NULL;
CTradeExecution* g_exec    = NULL;
CZoneRecovery*   g_zone    = NULL;
CRiskShield*     g_shield  = NULL;
CHUD*            g_hud     = NULL;

ENUM_FSM_STATE   g_fsmState            = FSM_IDLE;
double           g_sessionStartEquity  = 0.0;
datetime         g_lastPhase1Signal    = 0;    // Anti-spam de señales Phase 1

//--- Transición de estado con log
void TransitionFSM(ENUM_FSM_STATE newState)
{
   if(g_fsmState == newState) return;
   string names[] = {"IDLE","PHASE1","RECOVERY","TRAILING","EMERGENCY","WEEKEND"};
   PrintFormat("[ZRCE][FSM] %s → %s",
               names[(int)g_fsmState], names[(int)newState]);
   g_fsmState = newState;
}


//+===========================================================================+
//|  SECCIÓN 9: MANEJADORES DE ESTADO (OnState_*)                            |
//|  OnTick() delega aquí. NADA de lógica de trading en OnTick() directamente.|
//+===========================================================================+

//--- FSM_IDLE: Buscar señal de Phase 1 en régimen de media reversión
void OnState_Idle()
{
   if(g_shield.IsWeekendBlock())   { TransitionFSM(FSM_WEEKEND_BLOCK); return; }
   if(!g_shield.IsSpreadOK())      return;
   if(!g_shield.IsMarginOK())      return;

   // Anti-spam: mínimo 1 barra M5 entre señales (evitar sobre-operación)
   datetime curM5  = iTime(_Symbol, PERIOD_M5, 0);
   if(curM5 == g_lastPhase1Signal) return;

   ENUM_ORDER_TYPE signalDir;
   if(g_quant.HasPhase1Signal(signalDir))
   {
      PrintFormat("[ZRCE][STATE_IDLE] Señal Phase 1: %s | H=%.3f | Imb=%.3f | Z=%.3f",
                  (signalDir==ORDER_TYPE_BUY)?"COMPRA":"VENTA",
                  g_quant.GetHurst(), g_quant.GetTickImbalance(), g_quant.GetZScore());

      if(g_zone.OpenPhase1(g_exec, signalDir))
      {
         g_lastPhase1Signal = curM5;
         TransitionFSM(FSM_PHASE1_ACTIVE);
      }
   }
}

//--- FSM_PHASE1_ACTIVE: Gestionar operación individual con ATR trailing
void OnState_Phase1Active()
{
   // Si la posición fue cerrada externamente (SL, TP, cierre manual)
   if(!g_zone.HasActiveBasket())
   {
      Print("[ZRCE][STATE_P1] Posición cerrada externamente. Volviendo a IDLE.");
      g_zone.Reset();
      TransitionFSM(FSM_IDLE);
      return;
   }

   // Aplicar Trailing Stop ATR individual + Break-Even
   g_zone.ManageSinglePositionTrail(g_exec, g_quant.GetATR());

   // Verificar si el precio ha movido en contra > 1 ATR_USD → activar zona de recuperación
   double netPnL   = g_zone.GetTotalNetProfit();
   double atrUSD   = g_quant.GetATR_USD();

   if(netPnL < -(atrUSD) && atrUSD > 0.0)
   {
      PrintFormat("[ZRCE][STATE_P1] Activando Zona de Recuperación. PnL=%.4f ATR_USD=%.4f",
                  netPnL, atrUSD);
      g_zone.ActivateLock(g_exec);
      TransitionFSM(FSM_ZONE_RECOVERY);
      return;
   }

   // Si el beneficio supera el objetivo → iniciar trailing de cesta
   if(g_zone.CheckBasketTrailingTrigger())
      TransitionFSM(FSM_BASKET_TRAILING);
}

//--- FSM_ZONE_RECOVERY: Gestionar rejilla asimétrica de recuperación
void OnState_ZoneRecovery()
{
   if(!g_zone.HasActiveBasket())
   {
      Print("[ZRCE][STATE_REC] Cesta vaciada. Volviendo a IDLE.");
      g_zone.Reset();
      TransitionFSM(FSM_IDLE);
      return;
   }

   // Verificar si la cesta alcanzó su objetivo → trailing de equidad
   if(g_zone.CheckBasketTrailingTrigger())
   {
      TransitionFSM(FSM_BASKET_TRAILING);
      return;
   }

   // Front-Running: mover órdenes STOP hacia nivel ATR real (solo si spread OK)
   if(g_shield.IsSpreadOK())
   {
      g_zone.UpdateServerStopAnchors(g_exec);
   }
   else
   {
      // Spread alto + zona posiblemente rota: verificar si se necesita Dirty Hedge
      // (La lógica completa requiere conocer cuál nivel fue roto; aquí se deja
      //  como punto de extensión con log de alerta)
      Print("[ZRCE][STATE_REC][WARN] Spread alto durante recuperación - monitorizando...");
   }

   // Chequeo de margen durante recuperación
   if(IsEmergencyActive())
   {
      Print("[ZRCE][STATE_REC][EMERG] Margen crítico durante recuperación. Cerrando cesta.");
      g_exec.CloseAllBasket(_Symbol, InpMagicBase);
      g_zone.Reset();
      TransitionFSM(FSM_IDLE);
   }
}

//--- FSM_BASKET_TRAILING: Trailing de equidad hasta cierre total
void OnState_BasketTrailing()
{
   if(!g_zone.HasActiveBasket())
   {
      g_zone.Reset();
      TransitionFSM(FSM_IDLE);
      return;
   }

   if(g_zone.ShouldCloseBasket())
   {
      PrintFormat("[ZRCE][STATE_TRAIL] Cerrando cesta. Pico=%.4f$ Actual=%.4f$",
                  g_zone.GetPeakNetProfit(), g_zone.GetTotalNetProfit());
      g_exec.CloseAllBasket(_Symbol, InpMagicBase);
      g_zone.Reset();
      TransitionFSM(FSM_IDLE);
   }
}

//--- Helper: ¿Margen en nivel de emergencia?
bool IsEmergencyActive()
{
   if(g_shield == NULL) return false;
   return g_shield.IsEmergencyMargin();
}


//+===========================================================================+
//|  SECCIÓN 10: FUNCIONES PRINCIPALES DEL EA                                 |
//+===========================================================================+

int OnInit()
{
   Print("╔═══════════════════════════════════════════════════╗");
   PrintFormat("║  ZRCE v1.0 | Símbolo: %s | Equidad: %.2f$     ║",
               _Symbol, AccountInfoDouble(ACCOUNT_EQUITY));
   Print("╚═══════════════════════════════════════════════════╝");

   // ─── Instanciar objetos del sistema ───────────────────────────────────
   g_quant  = new CQuantEngine();
   g_exec   = new CTradeExecution();
   g_zone   = new CZoneRecovery(InpMagicBase, _Symbol);
   g_shield = new CRiskShield(InpMaxSpreadPts, InpMinMarginLevel, InpEmergencyMarginLvl);
   g_hud    = new CHUD("ZRCE_HUD_");

   // ─── Inicializar motor cuantitativo ───────────────────────────────────
   if(!g_quant.Init(InpATRPeriod, InpBBPeriod, InpBBDeviation))
   {
      Print("[ZRCE][FATAL] CQuantEngine no se pudo inicializar");
      return INIT_FAILED;
   }

   // ─── Inicializar HUD ──────────────────────────────────────────────────
   g_hud.Init();

   // ─── DISASTER RECOVERY: Reconstruir estado desde posiciones existentes
   //     Si el EA reinicia tras un corte de luz, las posiciones abiertas
   //     codifican el estado completo en sus números mágicos compuestos.
   if(g_zone.ReconstructFromOpenPositions())
   {
      // Forzar primera actualización de cálculos (force=true)
      g_quant.Update(true);
      g_zone.UpdateTargetUSD(g_quant.GetATR(), InpATRMultiplier);

      int lvls = g_zone.GetLevelCount();
      if(lvls == 1)
         TransitionFSM(FSM_PHASE1_ACTIVE);
      else if(lvls > 1)
         TransitionFSM(FSM_ZONE_RECOVERY);

      PrintFormat("[ZRCE][RECOVERY] FSM reconstruido: %d nivel(es), Estado=%d",
                  lvls, (int)g_fsmState);
   }
   else
   {
      TransitionFSM(FSM_IDLE);
      Print("[ZRCE][OK] Sin posiciones previas. Estado: INACTIVO.");
   }

   g_sessionStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   // Timer de 500ms para procesar reintentos de órdenes (Backoff Exponencial)
   EventSetMillisecondTimer(ZRCE_TIMER_MS);

   Print("[ZRCE][OK] Inicialización completada exitosamente.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();

   // Liberar toda la memoria heap alocada
   if(g_quant  != NULL) { delete g_quant;  g_quant  = NULL; }
   if(g_exec   != NULL) { delete g_exec;   g_exec   = NULL; }
   if(g_zone   != NULL) { delete g_zone;   g_zone   = NULL; }
   if(g_shield != NULL) { delete g_shield; g_shield = NULL; }
   if(g_hud    != NULL) { delete g_hud;    g_hud    = NULL; }

   PrintFormat("[ZRCE] Motor apagado. Razón: %d", reason);
}

//+------------------------------------------------------------------+
//|  OnTick: Punto de entrada principal — SÓLO orquestación de la FSM |
//|  La lógica de trading reside en los objetos y OnState_*().        |
//|  Este método debe ser un conductor limpio, no un monolito.        |
//+------------------------------------------------------------------+
void OnTick()
{
   // ─── Capa 0: Guardianes de protección básica ──────────────────────────
   if(g_shield == NULL || g_quant == NULL ||
      g_exec   == NULL || g_zone  == NULL) return;

   // Rechazar tick fantasma (feed colgado / latencia de datos)
   if(g_shield.IsGhostTick()) return;

   // ─── Capa 1: Actualizar motor cuantitativo (solo en nueva vela) ───────
   g_quant.Update();

   // Mantener objetivo USD sincronizado con la volatilidad actual
   g_zone.UpdateTargetUSD(g_quant.GetATR(), InpATRMultiplier);

   // ─── Capa 2: Emergencias críticas (prioridad sobre todo lo demás) ─────
   if(g_shield.IsEmergencyMargin())
   {
      if(g_fsmState != FSM_EMERGENCY_CLOSE)
      {
         PrintFormat("[ZRCE][!!EMERGENCIA!!] Margen=%.1f%% <= %.1f%%. Cierre forzado.",
                     AccountInfoDouble(ACCOUNT_MARGIN_LEVEL), InpEmergencyMarginLvl);
         TransitionFSM(FSM_EMERGENCY_CLOSE);
         g_exec.EmergencyCloseAll(_Symbol, InpMagicBase);
         g_zone.Reset();
         TransitionFSM(FSM_IDLE);
      }
      return; // No procesar nada más en este tick
   }

   // ─── Capa 3: Liquidación de fin de semana ─────────────────────────────
   if(g_shield.ShouldLiquidateWeekend() && g_zone.HasActiveBasket())
   {
      Print("[ZRCE][WEEKEND] Liquidando cesta antes del cierre de fin de semana.");
      g_exec.CloseAllBasket(_Symbol, InpMagicBase);
      g_zone.Reset();
      TransitionFSM(FSM_WEEKEND_BLOCK);
      return;
   }

   // ─── Capa 4: Máquina de Estado Finito ─────────────────────────────────
   switch(g_fsmState)
   {
      case FSM_IDLE:            OnState_Idle();           break;
      case FSM_PHASE1_ACTIVE:   OnState_Phase1Active();   break;
      case FSM_ZONE_RECOVERY:   OnState_ZoneRecovery();   break;
      case FSM_BASKET_TRAILING: OnState_BasketTrailing();  break;
      case FSM_WEEKEND_BLOCK:
         if(!g_shield.IsWeekendBlock()) TransitionFSM(FSM_IDLE);
         break;
      default: break;
   }

   // ─── Capa 5: Actualizar HUD con telemetría en tiempo real ─────────────
   double sessionPnL = AccountInfoDouble(ACCOUNT_EQUITY) - g_sessionStartEquity;
   double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   // Distancia hasta el cierre global: objetivo - PnL actual
   double distClose  = g_zone.GetTargetUSD() - g_zone.GetTotalNetProfit();

   g_hud.Update(g_fsmState,
                g_shield.GetBlockerString(),
                distClose,
                sessionPnL,
                equity);
}

//+------------------------------------------------------------------+
//|  OnTimer: Motor de reintentos asíncronos (Backoff Exponencial)    |
//|  Llamado cada ZRCE_TIMER_MS ms por EventSetMillisecondTimer().    |
//|  NUNCA usa Sleep(). El temporizador es no bloqueante.             |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(g_exec != NULL)
      g_exec.ProcessRetries();
}

//+------------------------------------------------------------------+
//|  OnTradeTransaction: Confirmación asíncrona de órdenes            |
//|  MQL5 llama esta función cuando el servidor confirma o rechaza     |
//|  una orden enviada con OrderSendAsync().                           |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
   // Notificar al motor de ejecución para limpiar la cola de reintentos
   if(g_exec != NULL)
      g_exec.OnTransaction(trans);

   // Asignar ticket de posición al nivel 0 de la zona de recuperación
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      // Apertura de posición nueva: verificar por trans.type (ya es DEAL_ADD arriba)
      if(trans.position > 0 && g_zone != NULL)
      {
         // Verificar si el magic pertenece a Phase 1 (nivel 0)
         if(PositionSelectByTicket(trans.position))
         {
            ulong posMagic = (ulong)PositionGetInteger(POSITION_MAGIC);
            if((posMagic % 100UL) == 0 && (posMagic / 10000UL) == InpMagicBase)
               g_zone.UpdatePhase1Ticket(trans.position);
         }
      }

      PrintFormat("[ZRCE][TRANS] Deal confirmado: Ticket=%llu | Precio=%.5f | Vol=%.2f",
                  trans.deal, trans.price, trans.volume);
   }
   else if(trans.type == TRADE_TRANSACTION_ORDER_ADD)
   {
      PrintFormat("[ZRCE][TRANS] Orden pendiente confirmada: Ticket=%llu | Precio=%.5f",
                  trans.order, trans.price);
   }
   else if(trans.type == TRADE_TRANSACTION_REQUEST &&
           result.retcode != TRADE_RETCODE_PLACED  &&
           result.retcode != TRADE_RETCODE_DONE)
   {
      PrintFormat("[ZRCE][TRANS][WARN] Solicitud rechazada: retcode=%u | %s",
                  result.retcode, result.comment);
   }
}

//+------------------------------------------------------------------+
//|  OnChartEvent: Redimensionar HUD si cambia el tamaño del gráfico  |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam,
                  const double &dparam, const string &sparam)
{
   if(id == CHARTEVENT_CHART_CHANGE && g_hud != NULL)
      g_hud.OnResize();
}

//+===========================================================================+
//|  FIN DEL ARCHIVO — ZONE RECOVERY CONTINUAL ENGINE v1.0                   |
//|                                                                           |
//|  NOTAS DE COMPILACIÓN:                                                    |
//|  • Target: MetaEditor 5, compilar en modo "Release" para máxima velocidad.|
//|  • Símbolo recomendado: EURUSD en cuenta Pepperstone Razor (ECN).         |
//|  • TimeFrame del gráfico: M5 (el EA opera internamente en M1 y M5).       |
//|  • Verificar en el Strategy Tester con modo "Every tick based on real     |
//|    ticks" y comisiones Razor antes de despliegue en cuenta real.          |
//|                                                                           |
//|  ADVERTENCIA DE RIESGO:                                                   |
//|  Los sistemas de recuperación por zonas (Martingala asimétrica) conllevan |
//|  riesgo de ruina matemáticamente demostrable en capital finito. Los       |
//|  filtros de Hurst y Tick Imbalance reducen este riesgo pero no lo         |
//|  eliminan. Opera con capital que puedas permitirte perder totalmente.     |
//+===========================================================================+
