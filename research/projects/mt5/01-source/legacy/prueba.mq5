//+------------------------------------------------------------------+
//|   APEXQUANT - V7.7.1  "SMART ADAPTIVE ENGINE — BUGFIX"           |
//|                                                                  |
//| CORRECCIONES V7.7.1 (fixes críticos introducidos en V7.7):      |
//|                                                                  |
//| [FIX 1] MarginOK: umbral 0.60 → 0.95                           |
//|   Bug: Con apalancamiento bajo (100:1-30:1) en XAUUSD, el margen|
//|   de 0.01 lote superaba el 60% del margen libre de $100.        |
//|   Bloqueaba TODAS las aperturas en cuentas pequeñas.            |
//|                                                                  |
//| [FIX 2] CalcDynamicMaxPositions: piso margMin*2.0 → margMin     |
//|   Bug: Devolvía 0 cuando libre < 2x margen mínimo. En cuentas  |
//|   de $100 esto ocurría con frecuencia, bloqueando recovery/LBC. |
//|                                                                  |
//| [FIX 3] HasSufficientMarginForCycle: reescrita                  |
//|   Bug: Exigía margen para 3 niveles de recovery + buffer 1.3x.  |
//|   Con apalancamiento <200:1 en XAUUSD y $100, el requisito era  |
//|   $40-$300+, bloqueando cualquier entrada primaria.             |
//|   Fix: solo verifica primaria + 1 recovery con buffer del 10%.  |
//|                                                                  |
//| [FIX 4] RunCTEngine spread check — BUG CRÍTICO PRINCIPAL        |
//|   Bug: (curSpr / _Point) > maxSpr                               |
//|   SYMBOL_SPREAD devuelve puntos enteros. Para XAUUSD _Point=0.01|
//|   → 15pts / 0.01 = 1500 >> maxSpr=20. SIEMPRE TRUE.            |
//|   Resultado: CERO entradas primarias en XAUUSD.                 |
//|   Fix: curSpr > (int)maxSpr (comparación directa, sin división) |
//|                                                                  |
//| BASE: V7.6C (Volatility Storm Filter Engine)                    |
//|                                                                  |
//| NUEVO EN V7.7:                                                   |
//|                                                                  |
//| [1] TEMA + KALMAN REAL-TIME TREND ENGINE                        |
//|     Reemplaza EMA21/55 cruce como señal de tendencia primaria.  |
//|     TEMA (Triple EMA) tiene lag casi cero. El filtro Kalman     |
//|     suaviza ruido sin sacrificar velocidad. Slope tick-a-tick   |
//|     determina bullish/bearish en tiempo real.                   |
//|     Afecta: isBullish/isBearish, RunRecoveryEngine trend.       |
//|     No afecta: handles EMA (siguen vivos para MACD/ADX).       |
//|                                                                  |
//| [2] PRIMARY POSITION HEDGE (PPH)                                |
//|     Si la posicion primaria llega a -$0.50 flotante -> abre     |
//|     orden contraria del mismo lote instantaneamente.            |
//|     Detiene la sangria mientras el EA analiza el mercado.       |
//|     Nunca abre un segundo PPH si ya hay uno activo.             |
//|                                                                  |
//| [3] LIMITE DINAMICO DE POSICIONES (100% del saldo)             |
//|     El EA calcula cuantas posiciones puede abrir con el margen  |
//|     libre real. No hay limite fijo para recovery/hedge.         |
//|     Antes de abrir primaria: verifica que tiene margen para     |
//|     cubrir el ciclo completo de recuperacion estimado.          |
//|                                                                  |
//| [4] FILTRO DE SPREAD POR RANGO (MIN + MAX)                     |
//|     Inp_MinSpread = 10: bloquea si spread muy bajo (anomalia).  |
//|     Inp_MaxSpread = 20: bloquea si spread muy alto (rollover).  |
//|     Rango 10-20 = condiciones normales de mercado XAUUSD.       |
//|                                                                  |
//| [5] PARAMETROS INTUITIVOS PARA TODOS LOS USUARIOS              |
//|     Nombres de grupos y comentarios en lenguaje simple.         |
//|     Sin cambios en la logica. Solo los textos descriptivos.     |
//|                                                                  |
//| INVARIANTES INAMOVIBLES (heredados de V7.3F):                  |
//|   - SL = 0 en TODAS las ordenes (broker nunca cierra auto)     |
//|   - TP individual = 0                                           |
//|   - UNICO cierre: bloque neto > BlockTPTarget                  |
//|   - EquityGuard NO bloquea Recovery/LBC (fix V7.3F preservado) |
//|   - CalcRecoveryLot: INTOCABLE                                  |
//|   - DeactivateLBC:   INTOCABLE                                  |
//+------------------------------------------------------------------+
#property copyright "ApexQuant V7.7.1 - Smart Adaptive Engine BUGFIX"
#property version   "7.71"
#property strict
#property description "XAUUSD 24/7 | ApexQuant V7.7.1 | 4 bugs críticos corregidos | $100 compatible"

#define VERSION_STR   "APEXQUANT_V7.7.1"

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>

#define MAX_RECORDS   80

enum ENUM_CT_MODE { CT_ATR_DISTANCE=0, CT_FIXED_POINTS=1 };

//=================================================================
//  PARAMETROS — GRUPOS CON NOMBRES INTUITIVOS PARA TODOS LOS USUARIOS
//=================================================================

// *** V7.7 [TEMA+KALMAN] ***
input group "=== SENSOR DE TENDENCIA EN TIEMPO REAL (TEMA + Kalman) ==="
// Activa el motor de tendencia ultrarapido TEMA+Kalman
// Reemplaza el cruce lento de medias moviles como señal de entrada
input bool   Inp_UseTEMAKalman       = true;
// Periodo del TEMA: valores pequenos = mas rapido pero mas ruidoso
// Recomendado: 7-14. Default: 9
input int    Inp_TEMAPeriod          = 9;
// Ruido del proceso Kalman (que tan rapido sigue al mercado)
// Mas alto = mas rapido y reactivo. Rango: 0.01 - 0.20. Default: 0.05
input double Inp_KalmanQ             = 0.05;
// Ruido de medicion Kalman (cuanto suaviza el filtro)
// Mas alto = mas suavizado. Rango: 0.1 - 2.0. Default: 0.5
input double Inp_KalmanR             = 0.5;
// Inclinacion minima del TEMA para confirmar tendencia activa
// Valores muy pequeños = muy sensible, valores grandes = solo tendencias fuertes
// Rango: 0.00005 - 0.001. Default: 0.0001
input double Inp_TrendMinSlope       = 0.0001;

// *** V7.7 [PRIMARY POSITION HEDGE] ***
input group "=== PROTECCION DE LA PRIMERA OPERACION (Hedge automatico) ==="
// Activa el hedge automatico de la posicion primaria
// Si la primera operacion pierde mas del umbral, abre una contraria del mismo lote
input bool   Inp_UsePPH              = true;
// Perdida flotante de la operacion primaria que activa el hedge automatico
// Ejemplo: -0.50 = si la primera op pierde $0.50 -> abre cobertura contraria
// Rango recomendado: -0.30 a -1.00
input double Inp_PPHThreshold        = -0.50;

input group "=== [V7.6C] FILTRO DE TORMENTAS DE VOLATILIDAD (Solo primera operacion) ==="
// Activa el filtro de tormenta. Bloquea SOLO la primera entrada, nunca el rescate
input bool   Inp_UseStormFilter      = true;
// Barras M1 para calcular el ATR promedio de referencia
input int    Inp_StormATRWindow      = 26;
// Si ATR_actual > este multiplicador x ATR_promedio = tormenta (no abrir primera op)
// Valor recomendado: 2.0
input double Inp_StormATRMult        = 2.0;
// Si spread_actual > este multiplicador x spread_promedio = tormenta
// Valor recomendado: 2.5
input double Inp_StormSpreadMult     = 2.5;
// Ventana de barras para calcular el spread promedio de referencia
input int    Inp_StormSpreadWindow   = 20;
// Segundos que el filtro bloquea despues de detectar una tormenta
// Evita reentrar inmediatamente cuando el ATR baja momentaneamente
input int    Inp_StormCooldownSec    = 30;

input group "=== [V7.6B] COBERTURA DE EXPOSICION NETA (Hedge proporcional) ==="
// Activa la cobertura proporcional cuando el bloque pierde demasiado
input bool   Inp_UseNetHedge         = true;
// Nivel 1 de perdida del bloque para activar cobertura del 50% del volumen neto
// Ejemplo: -2.0 = cuando el bloque pierde $2, cubre el 50% de la exposicion
input double Inp_NetHedgeTrigger1USD = -2.0;
// Nivel 2 de perdida para cubrir el 100% restante (neutralizar la exposicion)
input double Inp_NetHedgeTrigger2USD = -3.0;
// Segundos minimos entre operaciones de cobertura (evita abrir muchas rapido)
input int    Inp_NetHedgeIntervalSec = 5;

input group "=== CONFIGURACION GENERAL DEL EA ==="
// Numero magico unico del EA. No cambiar si hay operaciones abiertas
input long   Inp_Magic               = 1122;
// Maximas posiciones primarias por ciclo (la primera operacion de cada ciclo)
// El rescate y recovery NO estan limitados por este numero - usan el margen real
input int    Inp_MaxPositionsTotal   = 8;
// Lote base para la primera operacion de cada ciclo
// 0.01 = micro lote (minimo). Para cuentas mayores puede subir a 0.02-0.05
input double Inp_LotBase             = 0.01;
// Lote maximo absoluto que el EA puede usar en cualquier operacion
input double Inp_LotMaximum          = 0.02;
// Porcentaje del saldo que arriesga en cada operacion (si lote dinamico activado)
// 0.01 = 1% del saldo. Recomendado: 0.005 a 0.02
input double Inp_RiskPerTradePct     = 0.01;
// true = calcula el lote automaticamente segun el saldo y el riesgo configurado
// false = usa siempre el lote base fijo
input bool   Inp_UseDynamicLot       = true;
// Saldo minimo en USD necesario para que el EA abra operaciones
input double Inp_CTMinBalanceUSD     = 5.0;
// Porcentaje minimo de margen libre requerido antes de abrir
// 0.02 = necesita al menos el 2% de equity como margen libre
input double Inp_MinFreeMarginPct    = 0.02;

input group "=== OBJETIVO DE GANANCIA Y CRITERIO DE CIERRE DEL BLOQUE ==="
// Ganancia total neta (USD) del bloque completo para cerrar TODAS las operaciones
// El EA NUNCA cierra en perdida. Solo cierra cuando el total supera este valor
// Recomendado: 0.30 a 2.00 segun el saldo de la cuenta
input double Inp_BlockTPTarget       = 0.50;
// Multiplicador ATR para calcular el objetivo de ganancias en sesion activa
input double Inp_TP_ATR              = 2.5;
// Multiplicador ATR para calcular el stop loss virtual en sesion (solo referencia)
input double Inp_SL_ATR              = 1.2;
// Multiplicador ATR para objetivo de ganancias fuera de sesion principal
input double Inp_OffSessionTP_ATR    = 2.2;
// Multiplicador ATR para stop loss virtual fuera de sesion
input double Inp_OffSessionSL_ATR    = 1.0;

input group "=== MOTOR DE RECUPERACION AUTOMATICA (Rescate matematico) ==="
// Perdida flotante del bloque que activa el motor de recuperacion
// Ejemplo: -0.50 = cuando el bloque pierde $0.50, empieza a abrir recuperaciones
input double Inp_RecoveryTriggerUSD  = -0.50;
// Distancia minima en ATR desde la peor posicion para abrir una recuperacion
// Evita abrir recuperaciones demasiado cerca. Rango: 0.3 a 1.0
input double Inp_RecoveryMinDistATR  = 0.5;
// Distancia de movimiento esperada (en ATR) para calcular el lote de recuperacion
// El EA calcula el lote para recuperar todo en este movimiento. Rango: 0.3 a 1.0
input double Inp_RecoveryMoveATR     = 0.5;
// Multiplicador minimo del lote respecto al lote de la peor posicion
// Garantiza que la recuperacion tenga un lote significativo. Rango: 1.5 a 3.0
input double Inp_RecoveryMinLotMult  = 2.0;
// Maximas recuperaciones en modo promediado clasico (sin tendencia confirmada)
// Cuando hay tendencia confirmada usa Inp_RecoveryMaxOrdersTrend
input int    Inp_RecoveryMaxOrders   = 3;
// Maximas recuperaciones en modo hedge de tendencia (el mercado ayuda)
// Puede ser mayor porque cada recuperacion gana con el mercado
input int    Inp_RecoveryMaxOrdersTrend = 9;
// Segundos minimos entre recuperaciones (evita abrir todas de golpe)
input int    Inp_RecoveryIntervalSec = 3;

input group "=== CONTINGENCIA BALANCE BAJO (Micro-grid de emergencia) ==="
// Maximos pares de operaciones en el micro-grid de contingencia
input int    Inp_LBCMaxPairs         = 4;
// Separacion de la cuadricula en ATR para el micro-grid
input double Inp_LBCGridATR          = 0.30;
// Ganancia minima en ATR para cosechar una operacion del micro-grid
input double Inp_LBCHarvestATR       = 0.15;
// Segundos entre operaciones del micro-grid
input int    Inp_LBCIntervalSec      = 8;
// Porcentaje del margen libre que puede usar el micro-grid
input double Inp_LBCMarginPct        = 0.55;

input group "=== MOTOR DE CONTRA-OPERACIONES (Gestion activa del bloque) ==="
// Modo de distancia para abrir contra-operaciones: ATR o puntos fijos
input ENUM_CT_MODE Inp_CTMode        = CT_ATR_DISTANCE;
// Distancia en ATR para abrir contra-operacion (si modo ATR)
input double Inp_CTDistanceATR       = 1.2;
// Distancia en puntos para abrir contra-operacion (si modo puntos fijos)
input int    Inp_CTFixedPoints       = 100;
// Segundos entre evaluaciones de contra-operaciones
input int    Inp_CTIntervalSec       = 10;
// Maximas operaciones en el mismo sentido dentro del bloque
input int    Inp_CTMaxSameDir        = 3;
// Segundos de espera despues de abrir la primera operacion (sesion activa)
input int    Inp_PrimaryCooldownSec  = 10;
// Segundos de espera despues de abrir la primera operacion (fuera de sesion)
input int    Inp_PrimaryCooldownOff  = 20;
// Spread maximo permitido para contra-operaciones en sesion activa (puntos)
// *** V7.7 [SPREAD RANGE]: Ahora el spread debe estar entre Inp_MinSpread y este valor ***
input double Inp_CTMaxSpreadPoints   = 25.0;
// Spread maximo permitido fuera de sesion (puntos)
input double Inp_CTMaxSpreadOff      = 25.0;

input group "=== HORARIO DE OPERACION (Sesiones del mercado) ==="
// Offset GMT del broker para calculo de sesiones (ver esquina inferior MT5)
input int    Inp_GMTOffset           = 0;
// Hora de apertura de sesion Londres (en GMT)
input int    Inp_LondonOpen          = 7;
// Hora de cierre de sesion Londres (en GMT)
input int    Inp_LondonClose         = 17;
// Hora de apertura de sesion Nueva York (en GMT)
input int    Inp_NYOpen              = 13;
// Hora de cierre de sesion Nueva York (en GMT)
input int    Inp_NYClose             = 22;
// Multiplicador de lote fuera de sesion principal. 1.0 = mismo lote que en sesion
input double Inp_OffSessionLotFactor = 1.0;

input group "=== CIERRE EN GRUPO (Basket TP) ==="
// Activa el cierre en grupo cuando el bloque supera el objetivo combinado
input bool   Inp_UseBasketTP         = true;
// Factor base para calcular el objetivo del basket
input double Inp_BasketTPFactor      = 0.60;
// Ratio de ganancias historicas para escalar el objetivo del basket
input double Inp_BasketTPRatio       = 1.5;
// Cada cuantos segundos verifica si se puede hacer basket close
input int    Inp_BasketCheckSec      = 3;

input group "=== COSECHA DE GANANCIAS PARCIALES (Harvest) ==="
// Ganancia minima en USD para cosechar una posicion ganadora del bloque
input double Inp_HarvestMinUSD       = 0.80;
// Multiplicador ATR para el minimo de cosecha (adapta el umbral al mercado)
input double Inp_HarvestATRMult      = 0.20;
// true = cosecha continuamente durante el ciclo cuando hay ganancias parciales
input bool   Inp_HarvestContinuous   = true;
// Segundos entre verificaciones de cosecha
input int    Inp_HarvestIntervalSec  = 3;

input group "=== CONTROL DE CICLO (Pausa entre bloques) ==="
// Activa el limite de perdida maxima por ciclo completo
input bool   Inp_UseCycleMaxLoss     = true;
// Perdida maxima del ciclo completo antes de forzar recuperacion agresiva
input double Inp_CycleMaxLossUSD     = -100.00;
// Segundos de pausa entre el cierre de un ciclo y el inicio del siguiente
input int    Inp_CyclePauseSec       = 30;

input group "=== FILTRO DE TENDENCIA ADX (Confirma fuerza de tendencia) ==="
// Activa el filtro ADX. Evita entrar cuando el mercado esta sin tendencia clara
input bool   Inp_UseADX              = true;
// Periodo del indicador ADX para medir la fuerza de la tendencia
input int    Inp_ADXPeriod           = 14;
// Nivel minimo de ADX para confirmar tendencia en sesion activa
// Por encima de este valor = tendencia fuerte. Rango: 20-40
input double Inp_ADXTrendLevel       = 30.0;
// Nivel minimo de ADX fuera de sesion (mas permisivo)
input double Inp_ADXTrendLevelOff    = 22.0;
// Activa filtro de temporalidad superior para confirmar la tendencia
input bool   Inp_UseHTF              = true;
// Marco temporal superior para confirmar la tendencia general
input ENUM_TIMEFRAMES Inp_HTFTF      = PERIOD_M5;

input group "=== PROTECCION DIARIA (Pausa automatica por perdida del dia) ==="
// Activa el limite de perdida diaria. Al alcanzarlo pausa nuevas primarias
// El recovery y posiciones abiertas SIGUEN funcionando aunque se active
input bool   Inp_UseDailyLimit       = true;
// Perdida maxima del dia en USD antes de pausar nuevas entradas primarias
// Recomendado: 2x a 5x el BlockTPTarget
input double Inp_DailyLossUSD        = -140.0;
// Perdida maxima del dia como porcentaje del saldo (el que sea menor aplica)
// 100 = sin limite por porcentaje (usa solo el limite en USD)
input double Inp_DailyLossPct        = 100.0;
// Numero de perdidas consecutivas para reducir el tamaño de lote temporalmente
input int    Inp_LossStreakMax        = 2;
// Factor de reduccion de lote al alcanzar la racha de perdidas
// 0.70 = reduce al 70% del lote normal
input double Inp_LossStreakReduce     = 0.70;

input group "=== PROTECCION DE EQUITY (Pausa por perdida flotante total) ==="
// Activa la proteccion de equity. Pausa nuevas primarias si la perdida flotante
// es demasiado grande. El recovery SIGUE funcionando (fix V7.3F intocable)
input bool   Inp_UseEquityGuard      = true;
// Perdida flotante total del bloque que activa la pausa de nuevas primarias
// Recomendado: 3x a 10x el BlockTPTarget
input double Inp_EmergencyLossUSD    = -3.0;
// Porcentaje maximo de drawdown del equity antes de pausar
// 100 = sin limite por porcentaje
input double Inp_MaxDrawdownPct      = 100;
// Segundos de cooldown despues de que el equity guard se desactiva
input int    Inp_EmergencyCooldown   = 10;

input group "=== INDICADORES TECNICOS (Base del analisis de mercado) ==="
// Periodo del ATR (Average True Range) para medir la volatilidad actual
input int    Inp_ATRPeriod           = 14;
// Periodo de la media movil rapida para detectar cambios de tendencia
input int    Inp_EMAFast             = 21;
// Periodo de la media movil lenta para confirmar la tendencia principal
input int    Inp_EMASlow             = 55;
// Periodo del RSI para medir la fuerza relativa del movimiento
input int    Inp_RSIPeriod           = 7;
// Parametros del MACD para confirmar el momentum del mercado
input int    Inp_MACDFast            = 12;
input int    Inp_MACDSlow            = 26;
input int    Inp_MACDSig             = 9;

input group "=== CONFIGURACION DE PANTALLA (Panel de informacion) ==="
// *** V7.7 [SPREAD RANGE]: Spread MINIMO para operar (puntos). Menor = anomalia ***
// Para XAUUSD Pepperstone Razor: rango normal es 3-15 puntos en sesion
// Bloquea si spread < Inp_MinSpread (mercado anomalo) o > Inp_MaxSpread (rollover)
input int    Inp_MinSpread           = 10;
// Spread MAXIMO permitido para abrir operaciones (puntos)
// Recomendado: 15-25 para XAUUSD. Default V7.7: 20
input int    Inp_MaxSpread           = 30;
// true = muestra el panel de informacion en el grafico
input bool   Inp_ShowDashboard       = true;
// Posicion horizontal del panel en la pantalla (pixeles desde la izquierda)
input int    Inp_DashX               = 12;
// Posicion vertical del panel en la pantalla (pixeles desde arriba)
input int    Inp_DashY               = 28;

input group "=== RESCATE UNIVERSAL (Incluye operaciones de otros EAs) ==="
// true = incluye TODAS las posiciones del simbolo en el calculo de PnL
// (sin importar el numero magico). Las cierra junto con las propias al alcanzar el objetivo
// false = solo gestiona las propias operaciones del EA
input bool   Inp_RescueAllTrades     = true;

input group "=== SENSOR 1: HORARIO DE TRADING (Ventana de operacion) ==="
// Activa el filtro de horario. Solo opera dentro de la ventana configurada
input bool   Inp_UseTimeFilter       = true;
// Su zona horaria GMT personal. Ejemplos: -5=EST(Nueva York), -3=BRT(Brasil), +1=CET(Europa)
input int    Inp_UserGMT             = -5;
// GMT del servidor de su broker (verificar en esquina inferior derecha de MT5)
input int    Inp_BrokerGMT           = 2;
// Hora de inicio de operacion en su horario LOCAL (formato HH:MM)
input string Inp_StartTime           = "07:30";
// Hora de fin de operacion en su horario LOCAL (formato HH:MM)
input string Inp_EndTime             = "15:00";

input group "=== SENSOR 3: TENDENCIA DE LARGO PLAZO (EMA 200) ==="
// Activa el filtro de tendencia institucional con la EMA de 200 periodos
// Solo abre BUY si el precio esta sobre la EMA200, SELL si esta debajo
input bool   Inp_UseTrendFilter200   = true;
// Periodo de la EMA institucional. 200 = tendencia de largo plazo
input int    Inp_EMA200Period        = 200;

input group "=== SENSOR 4: DETECTOR DE VOLATILIDAD EXTREMA ==="
// Activa el detector de tormenta de volatilidad (noticias, flash crash, etc.)
input bool   Inp_UseVolatFilter      = true;
// Periodo del ATR lento de referencia para detectar aceleracion de volatilidad
input int    Inp_ATRSlowPeriod       = 100;
// Si ATR_rapido / ATR_lento supera este valor = mercado en tormenta (no entrar)
// Recomendado: 2.0 a 3.0. Default: 2.5
input double Inp_ATRRatioMax         = 2.5;

input group "=== SENSOR 5: VERIFICACION DE MARGEN DISPONIBLE ==="
// Activa la verificacion de margen antes de abrir la primera operacion
// Asegura que hay margen suficiente para completar el ciclo de recuperacion
input bool   Inp_UseMarginGuard      = true;
// Numero minimo de niveles de recuperacion que el margen libre debe poder soportar
// antes de abrir una nueva primera operacion. Recomendado: 3 a 5
input int    Inp_MarginGuardLevels   = 3;

//=================================================================
//  ESTRUCTURAS
//=================================================================
struct PosRecord {
   ulong    ticket;
   int      posType;
   double   openPrice;
   double   volume;
   double   netProfit;
   datetime openTime;
   string   comment;
   bool     isPrimary;
   bool     isCounter;
   bool     isRecovery;
   bool     isLBC;
   double   peakProfit;
   double   kX, kP, kK;
   bool     kInit;
};

struct Portfolio {
   int    totalPos;
   int    buyCount, sellCount;
   double buyProfit, sellProfit;
   double totalProfit;
   double positiveSum, negativeSum;
   ulong  worstTicket;
   double worstProfit;
   int    ctCount;
   int    recoveryCount;
   int    lbcCount;
   double currentDD;
   double blockVWAP;
   int    blockDir;
   int    rescueCount;
   double rescueProfit;
   double buyVolume;
   double sellVolume;
};

struct MarketSnap {
   double bid, ask, atr, emaFast, emaSlow, rsi, macdMain, macdSig, adx, spread;
   int    htfTrend;
   bool   isBullish, isBearish;
   double atrSlow;
   double ema200;
};

struct LBCState {
   bool     active;
   int      buyCount;
   int      sellCount;
   double   lastBuyPrice;
   double   lastSellPrice;
   datetime lastOrderTime;
   double   harvestedTotal;
   int      harvestCount;
   int      maxOrdersCalc;
   datetime activatedTime;
};

struct SensorState {
   bool   timeOK;
   bool   spreadOK;
   bool   trendBull;
   bool   volatOK;
   bool   marginOK;
   bool   allOK;
   string blockReason;
   double atrRatio;
   int    brokerStartMin;
   int    brokerEndMin;
};

// *** V7.7 [TEMA+KALMAN] Estructura del motor de tendencia en tiempo real ***
struct TEMAKalman {
   double ema1, ema2, ema3;  // Triple EMA calculada tick a tick
   double tema;               // Valor TEMA actual (antes del filtro)
   double kX, kP;             // Estado del filtro de Kalman
   double prevTema;           // TEMA del tick anterior (para calcular slope)
   double slope;              // Inclinacion (positiva=alcista, negativa=bajista)
   int    direction;          // 1=alcista, -1=bajista, 0=lateral
   bool   initialized;        // true despues del primer tick
};

//=================================================================
//  HANDLES
//=================================================================
int h_ATR, h_EMAFast, h_EMASlow, h_RSI, h_MACD;
int h_ADX        = INVALID_HANDLE;
int h_HTFEMAFast = INVALID_HANDLE;
int h_HTFEMASlow = INVALID_HANDLE;
int h_ATRSlow    = INVALID_HANDLE;
int h_EMA200     = INVALID_HANDLE;

//=================================================================
//  ESTADO GLOBAL
//=================================================================
CTrade      m_trade;
PosRecord   m_rec[MAX_RECORDS];
Portfolio   m_port;
MarketSnap  m_mkt;
LBCState    m_lbc;
SensorState m_sensors;
// *** V7.7 [TEMA+KALMAN] Instancia global del motor de tendencia ***
TEMAKalman  m_tk;

double   m_initialBalance    = 0;
double   m_bestEquity        = 0;
bool     m_isPaused          = false;
bool     m_emergencyMode     = false;
bool     m_dailyLimitHit     = false;
bool     m_inSession         = false;
bool     m_recoveryActive    = false;
int      m_recoveryOrders    = 0;
bool     m_recoveryTrendHedge = false;

bool     m_netHedge1Applied   = false;
bool     m_netHedge2Applied   = false;
datetime m_lastNetHedgeTime   = 0;

bool     m_stormActive        = false;
datetime m_stormDetectedTime  = 0;
double   m_stormLastATRRatio  = 0.0;
double   m_stormLastSprRatio  = 0.0;

// *** V7.7 [PRIMARY POSITION HEDGE] Estado del hedge de la posicion primaria ***
ulong    m_pphHedgeTicket     = 0;  // Ticket del hedge PPH activo (0 = ninguno)
bool     m_pphActive          = false; // true = hay un PPH abierto actualmente

double   m_cycleWinsSum      = 0;
int      m_cycleWinsCount    = 0;
double   m_cycleLossSum      = 0;
bool     m_cycleInPause      = false;
datetime m_cycleResetTime    = 0;

int      m_consecutiveLosses = 0;
double   m_lotMultiplier     = 1.0;
double   m_dailyBalance      = 0;
datetime m_lastDailyReset    = 0;

int      m_lastPrimaryDir    = 0;
datetime m_lastPrimaryTime   = 0;
bool     m_lastPrimaryLost   = false;

double   m_lastCTBuyPrice    = 0;
double   m_lastCTSellPrice   = 0;
datetime m_lastCTTime        = 0;
datetime m_lastRecoveryTime  = 0;
datetime m_lastBasketCheck   = 0;
datetime m_lastHarvestTime   = 0;
datetime m_lastDashTime      = 0;
datetime m_lastCleanupTime   = 0;

double   m_totalPnL          = 0;
int      m_tradesOpened      = 0;
int      m_tradesClosed      = 0;
double   m_bestClosed        = 0;
double   m_worstClosed       = 0;
int      m_totalWins         = 0;
int      m_totalLosses       = 0;
double   m_sumWins           = 0;
double   m_sumLosses         = 0;

long     m_tickCount         = 0;
bool     m_isProcessing      = false;

double   m_losingPosOpenPrice = 0;
int      m_losingPosType      = -1;

//=================================================================
//  HELPERS
//=================================================================
double NormLot(double lot)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxL = MathMin(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), Inp_LotMaximum);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   return NormalizeDouble(MathMax(minL, MathMin(maxL, lot)), 2);
}

double NormPrice(double p) { return NormalizeDouble(p, _Digits); }
bool GetTick(MqlTick &t)   { return SymbolInfoTick(_Symbol, t); }

double GetATR()
{
   double b[1];
   if(CopyBuffer(h_ATR, 0, 1, 1, b) == 1) return b[0];
   return _Point * 200;
}

double GetTickVal()  { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); }
double GetTickSize() { return SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE); }

double DistToUSD(double dist, double lot)
{
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv <= 0 || ts <= 0 || dist <= 0 || lot <= 0) return 0;
   return NormalizeDouble((dist / ts) * tv * lot, 2);
}

// *** V7.7 [SPREAD RANGE]: SpreadOK ahora verifica rango minimo Y maximo ***
bool SpreadOK()
{
   int curSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   int maxSpr    = m_inSession ? Inp_MaxSpread : (int)Inp_CTMaxSpreadOff;
   // Bloquear si spread es menor al minimo (anomalia de datos) O mayor al maximo (rollover/noticia)
   if(curSpread < Inp_MinSpread) return false;
   return (curSpread <= maxSpr);
}

bool MarginOK(double lot, ENUM_ORDER_TYPE type)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   if(bal < Inp_CTMinBalanceUSD) return false;
   if(free < eq * Inp_MinFreeMarginPct) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   // FIX V7.7.1: Cambiado 0.60 -> 0.95. Con 0.60 bloqueaba cuentas de $100
   // (la orden de 0.01 lote usaba >60% del margen libre con apalancamientos bajos)
   if(OrderCalcMargin(type, _Symbol, lot, price, marg))
      if(marg > free * 0.95) return false;
   return true;
}

bool MarginOK_Hedge(double lot, ENUM_ORDER_TYPE type)
{
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free <= 0) return false;
   MqlTick t; if(!GetTick(t)) return false;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;
   double marg  = 0;
   if(OrderCalcMargin(type, _Symbol, lot, price, marg)) {
      if(marg <= 0) return false;
      return (marg <= free * 0.90);
   }
   return false;
}

double CalcMarginFor001()
{
   double marg = 0;
   MqlTick t; GetTick(t);
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, 0.01, t.ask, marg)) return 2.0;
   return (marg > 0) ? marg : 2.0;
}

double ProfitPerLotPerPoint()
{
   double tv = GetTickVal(), ts = GetTickSize();
   if(tv <= 0 || ts <= 0) return 1.0;
   return tv / ts;
}

// *** V7.7 [DYNAMIC POSITIONS]: Calcula el maximo de posiciones basado en margen real ***
int CalcDynamicMaxPositions()
{
   double free      = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margMin   = CalcMarginFor001();
   if(margMin <= 0 || free <= 0) return 50;
   // FIX V7.7.2: Cambiado margMin*2.0 -> margMin. Con 2.0 devolvía 0 en cuentas
   // pequeñas donde el margen libre era justo mayor que margMin pero menor que 2*margMin
   if(free < margMin) return 0;
   // Usa hasta el 92% del margen libre
   int dynMax = (int)(free * 0.92 / margMin);
   // Rango razonable: minimo 10, maximo 200
   return MathMax(10, MathMin(dynMax, 200));
}

// *** V7.7 [DYNAMIC POSITIONS]: Verifica si hay margen para al menos la primaria + 1 recovery ***
// FIX V7.7.3: Versión anterior exigía 3 niveles de recovery + buffer 1.3x.
// Con apalancamiento de 100:1 en XAUUSD y $100, eso bloqueaba TODO.
// Nueva lógica: solo verificar que hay margen para la primaria + el primer nivel de recovery.
// El EA recupera iterativamente con lo que tiene disponible en cada momento.
bool HasSufficientMarginForCycle()
{
   double lot   = CalcLot(0);
   double marg1 = 0;
   MqlTick tk; if(!GetTick(tk)) return true;
   // Si no se puede calcular el margen, dejar pasar (el broker rechazará si no hay)
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, tk.ask, marg1) || marg1 <= 0)
      return true;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   // Necesitamos al menos el margen de la primaria para poder abrirla
   if(free < marg1 * 1.05) {
      Print("[AQ V7.7] PREFLIGHT: margen insuf para primaria. Libre=$",
            NormalizeDouble(free,2), " Necesario=$", NormalizeDouble(marg1*1.05,2));
      return false;
   }
   // Verificar que queda margen para AL MENOS 1 nivel de recovery después de abrir
   double recLot = NormLot(lot * MathMin(Inp_RecoveryMinLotMult, 2.0));
   double marg2  = 0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, recLot, tk.ask, marg2) || marg2 <= 0)
      marg2 = marg1 * MathMin(Inp_RecoveryMinLotMult, 2.0);
   // Después de abrir la primaria, debe quedar margen para el primer recovery
   bool ok = (free - marg1 >= marg2 * 1.10);
   if(!ok)
      Print("[AQ V7.7] PREFLIGHT: libre después de primaria insuf para recovery. ",
            "Libre=$", NormalizeDouble(free,2),
            " Primaria=$", NormalizeDouble(marg1,2),
            " Rec1=$", NormalizeDouble(marg2,2),
            " Resta=$", NormalizeDouble(free-marg1,2));
   return ok;
}

//=================================================================
//  RECORDS
//=================================================================
int FindRec(ulong ticket)
{
   for(int i = 0; i < MAX_RECORDS; i++)
      if(m_rec[i].ticket == ticket) return i;
   return -1;
}

int FreeRec()
{
   for(int i = 0; i < MAX_RECORDS; i++)
      if(m_rec[i].ticket == 0) return i;
   return -1;
}

void InitRec(int idx, ulong ticket, int posType, double openPrice, double vol,
             string comment, bool isPrimary, bool isCounter,
             bool isRecovery = false, bool isLBC = false)
{
   if(idx < 0 || idx >= MAX_RECORDS) return;
   ZeroMemory(m_rec[idx]);
   m_rec[idx].ticket     = ticket;
   m_rec[idx].posType    = posType;
   m_rec[idx].openPrice  = openPrice;
   m_rec[idx].volume     = vol;
   m_rec[idx].openTime   = TimeCurrent();
   m_rec[idx].comment    = comment;
   m_rec[idx].isPrimary  = isPrimary;
   m_rec[idx].isCounter  = isCounter;
   m_rec[idx].isRecovery = isRecovery;
   m_rec[idx].isLBC      = isLBC;
   m_rec[idx].kP         = 1.0;
   m_rec[idx].kK         = 1.0;
}

void CleanupRecs()
{
   for(int i = 0; i < MAX_RECORDS; i++) {
      if(m_rec[i].ticket == 0) continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)) {
         double pnl = m_rec[i].netProfit;
         if(pnl != 0) {
            m_totalPnL += pnl; m_tradesClosed++;
            if(pnl > 0) { m_totalWins++;   m_sumWins   += pnl; }
            else         { m_totalLosses++; m_sumLosses += MathAbs(pnl); }
            if(pnl > m_bestClosed)  m_bestClosed  = pnl;
            if(pnl < m_worstClosed) m_worstClosed = pnl;
         }
         // *** V7.7 [PPH]: Si la posicion que se cierra era el PPH, resetear el estado ***
         if(m_rec[i].ticket == m_pphHedgeTicket) {
            m_pphHedgeTicket = 0;
            m_pphActive      = false;
         }
         ZeroMemory(m_rec[i]);
      }
   }
}

void SyncPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      if(FindRec(t) >= 0) continue;
      int idx = FreeRec(); if(idx < 0) continue;
      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      string comm = PositionGetString(POSITION_COMMENT);
      bool isPri  = (StringFind(comm, "Primary")   >= 0);
      bool isCT   = (StringFind(comm, "CT_")       >= 0);
      bool isRec  = (StringFind(comm, "REC_")      >= 0 || StringFind(comm, "PPH_") >= 0);
      bool isLBC  = (StringFind(comm, "LBC_")      >= 0);
      InitRec(idx, t, pt, op, vol, comm, isPri, isCT, isRec, isLBC);
      // Reconciliar PPH si se reinicia el EA con un PPH abierto
      if(StringFind(comm, "PPH_HEDGE") >= 0) {
         m_pphHedgeTicket = t;
         m_pphActive      = true;
      }
   }
}

//=================================================================
//  KALMAN (PRESERVADO)
//=================================================================
void KalmanUpdate(int idx, double meas)
{
   if(!m_rec[idx].kInit) {
      m_rec[idx].kX = meas; m_rec[idx].kP = 1.0;
      m_rec[idx].kK = 1.0;  m_rec[idx].kInit = true;
      return;
   }
   double pP = m_rec[idx].kP + 0.01;
   double K  = pP / (pP + 0.20);
   m_rec[idx].kX = m_rec[idx].kX + K * (meas - m_rec[idx].kX);
   m_rec[idx].kP = (1.0 - K) * pP;
   m_rec[idx].kK = K;
}

void UpdateKalman()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      int idx = FindRec(t); if(idx < 0) continue;
      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      m_rec[idx].netProfit = pf;
      if(pf > m_rec[idx].peakProfit) m_rec[idx].peakProfit = pf;
      KalmanUpdate(idx, pf);
   }
}

//=================================================================
//  *** V7.7 [TEMA+KALMAN]: Motor de tendencia en tiempo real ***
//
//  Calcula TEMA (Triple EMA) tick a tick sin indicadores externos.
//  Aplica filtro Kalman discreto para suavizar el TEMA sin sacrificar velocidad.
//  La inclinacion (slope) del TEMA-Kalman determina la direccion de la tendencia.
//
//  VENTAJA SOBRE EMA21/55: El TEMA tiene lag casi cero. El cruce de EMAs
//  puede tardar 5-10 barras en confirmar un cambio de tendencia.
//  El TEMA-Kalman lo detecta en 1-3 ticks.
//=================================================================
void UpdateTEMAKalman()
{
   if(!Inp_UseTEMAKalman) {
      // Fallback: usar la logica original de EMA21/55 + RSI + MACD
      m_mkt.isBullish = (m_mkt.emaFast > m_mkt.emaSlow && m_mkt.rsi > 52 && m_mkt.macdMain > m_mkt.macdSig);
      m_mkt.isBearish = (m_mkt.emaFast < m_mkt.emaSlow && m_mkt.rsi < 48 && m_mkt.macdMain < m_mkt.macdSig);
      m_tk.direction  = m_mkt.isBullish ? 1 : m_mkt.isBearish ? -1 : 0;
      m_tk.slope      = 0;
      return;
   }

   MqlTick tk; if(!GetTick(tk)) return;
   double price = (tk.bid + tk.ask) / 2.0;
   if(price <= 0) return;

   double alpha = 2.0 / (MathMax(Inp_TEMAPeriod, 2) + 1.0);

   if(!m_tk.initialized) {
      // Inicializacion: todos los estados al precio actual
      m_tk.ema1        = price;
      m_tk.ema2        = price;
      m_tk.ema3        = price;
      m_tk.tema        = price;
      m_tk.kX          = price;
      m_tk.kP          = 1.0;
      m_tk.prevTema    = price;
      m_tk.slope       = 0.0;
      m_tk.direction   = 0;
      m_tk.initialized = true;
      return;
   }

   // Paso 1: Calcular Triple EMA recursiva
   m_tk.ema1 = alpha * price     + (1.0 - alpha) * m_tk.ema1;
   m_tk.ema2 = alpha * m_tk.ema1 + (1.0 - alpha) * m_tk.ema2;
   m_tk.ema3 = alpha * m_tk.ema2 + (1.0 - alpha) * m_tk.ema3;
   double rawTEMA = 3.0 * m_tk.ema1 - 3.0 * m_tk.ema2 + m_tk.ema3;

   // Paso 2: Filtro de Kalman discreto sobre el TEMA crudo
   // Prediccion
   double kP_pred = MathMax(m_tk.kP + Inp_KalmanQ, 1e-9);
   // Ganancia de Kalman
   double K       = kP_pred / (kP_pred + MathMax(Inp_KalmanR, 1e-9));
   // Actualizacion del estado
   m_tk.kX        = m_tk.kX + K * (rawTEMA - m_tk.kX);
   m_tk.kP        = MathMax((1.0 - K) * kP_pred, 1e-9); // P nunca negativo
   m_tk.tema      = m_tk.kX; // TEMA filtrado = salida del Kalman

   // Paso 3: Calcular inclinacion (slope) para determinar direccion
   m_tk.slope    = m_tk.tema - m_tk.prevTema;
   m_tk.prevTema = m_tk.tema;

   // Paso 4: Clasificar la direccion de la tendencia
   double slopeThresh = MathMax(Inp_TrendMinSlope, 1e-9);
   if(m_tk.slope > slopeThresh)        m_tk.direction = 1;  // Alcista
   else if(m_tk.slope < -slopeThresh)  m_tk.direction = -1; // Bajista
   else                                 m_tk.direction = 0;  // Lateral

   // Paso 5: Actualizar isBullish/isBearish usando TEMA-Kalman + RSI como confirmacion
   // RSI como filtro de sobrecompra/sobreventa para evitar entrar en extremos
   m_mkt.isBullish = (m_tk.direction == 1  && m_mkt.rsi > 50 && m_mkt.rsi < 80);
   m_mkt.isBearish = (m_tk.direction == -1 && m_mkt.rsi < 50 && m_mkt.rsi > 20);
}

//=================================================================
//  SESION
//=================================================================
bool IsInMainSession()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_week == 0 || dt.day_of_week == 6) return false;
   int gmtHour = (dt.hour - Inp_GMTOffset + 24) % 24;
   return ((gmtHour >= Inp_LondonOpen  && gmtHour < Inp_LondonClose) ||
           (gmtHour >= Inp_NYOpen      && gmtHour < Inp_NYClose));
}

//=================================================================
//  ACTUALIZACION DE MERCADO
//=================================================================
void UpdateMarket()
{
   MqlTick t; if(!GetTick(t)) return;
   m_mkt.bid    = t.bid;
   m_mkt.ask    = t.ask;
   m_mkt.spread = (t.ask - t.bid) / _Point;
   m_mkt.atr    = GetATR();

   double f[1], s[1], r[1], m[1], sg[1];
   if(CopyBuffer(h_EMAFast, 0, 0, 1, f)  == 1) m_mkt.emaFast  = f[0];
   if(CopyBuffer(h_EMASlow, 0, 0, 1, s)  == 1) m_mkt.emaSlow  = s[0];
   if(CopyBuffer(h_RSI,     0, 0, 1, r)  == 1) m_mkt.rsi      = r[0];
   if(CopyBuffer(h_MACD,    0, 0, 1, m)  == 1) m_mkt.macdMain = m[0];
   if(CopyBuffer(h_MACD,    1, 0, 1, sg) == 1) m_mkt.macdSig  = sg[0];
   if(h_ADX != INVALID_HANDLE) {
      double adxB[1];
      if(CopyBuffer(h_ADX, 0, 0, 1, adxB) == 1) m_mkt.adx = adxB[0];
   }
   if(h_HTFEMAFast != INVALID_HANDLE && h_HTFEMASlow != INVALID_HANDLE) {
      double hf[1], hs[1];
      if(CopyBuffer(h_HTFEMAFast, 0, 0, 1, hf) == 1 &&
         CopyBuffer(h_HTFEMASlow, 0, 0, 1, hs) == 1) {
         m_mkt.htfTrend = (hf[0] > hs[0] * 1.0001) ? 1 : (hf[0] < hs[0] * 0.9999) ? -1 : 0;
      }
   }
   if(h_EMA200 != INVALID_HANDLE) {
      double e200[1];
      if(CopyBuffer(h_EMA200, 0, 1, 1, e200) == 1) m_mkt.ema200 = e200[0];
   }
   if(h_ATRSlow != INVALID_HANDLE) {
      double atrS[1];
      if(CopyBuffer(h_ATRSlow, 0, 1, 1, atrS) == 1) m_mkt.atrSlow = atrS[0];
   }

   // *** V7.7 [TEMA+KALMAN]: Actualizar el motor de tendencia en tiempo real ***
   // Esto reemplaza la señal de isBullish/isBearish basada en EMA21/55
   UpdateTEMAKalman();
}

//=================================================================
//  ACTUALIZACION DE PORTFOLIO
//=================================================================
void UpdatePortfolio()
{
   ZeroMemory(m_port);
   m_port.worstProfit   = 0;
   m_losingPosOpenPrice = 0;
   m_losingPosType      = -1;

   double vwapNumer = 0;
   double vwapDenom = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      long   magic = PositionGetInteger(POSITION_MAGIC);
      bool   isOwn = (magic == Inp_Magic);
      bool   isExt = (!isOwn && Inp_RescueAllTrades);

      if(!isOwn && !isExt) continue;

      int    pt   = (int)PositionGetInteger(POSITION_TYPE);
      double pf   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double op   = PositionGetDouble(POSITION_PRICE_OPEN);
      string comm = PositionGetString(POSITION_COMMENT);

      m_port.totalPos++;
      m_port.totalProfit += pf;
      if(pf >= 0) m_port.positiveSum += pf;
      else        m_port.negativeSum += MathAbs(pf);

      if(pt == POSITION_TYPE_BUY) { m_port.buyCount++;  m_port.buyProfit  += pf; m_port.buyVolume  += vol; }
      else                        { m_port.sellCount++; m_port.sellProfit += pf; m_port.sellVolume += vol; }

      vwapNumer += op * vol;
      vwapDenom += vol;
      m_port.blockDir += (pt == POSITION_TYPE_BUY) ? 1 : -1;

      if(pf < m_port.worstProfit) {
         m_port.worstProfit   = pf;
         m_port.worstTicket   = t;
         m_losingPosOpenPrice = op;
         m_losingPosType      = pt;
      }

      if(isOwn) {
         if(StringFind(comm, "CT_")  >= 0) m_port.ctCount++;
         if(StringFind(comm, "REC_") >= 0 || StringFind(comm, "PPH_") >= 0) m_port.recoveryCount++;
         if(StringFind(comm, "LBC_") >= 0) m_port.lbcCount++;
      }
      if(isExt) { m_port.rescueCount++; m_port.rescueProfit += pf; }
   }

   if(vwapDenom > 0) m_port.blockVWAP = vwapNumer / vwapDenom;

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq > m_bestEquity) m_bestEquity = eq;
   m_port.currentDD = (m_bestEquity > 0) ? (m_bestEquity - eq) / m_bestEquity : 0;
}

//=================================================================
//  SENSORES V7.5
//=================================================================
int ParseHH(string t) { return (int)StringToInteger(StringSubstr(t, 0, 2)); }
int ParseMM(string t) { return (int)StringToInteger(StringSubstr(t, 3, 2)); }

void CalcBrokerTimeWindow()
{
   int startUserMin = ParseHH(Inp_StartTime) * 60 + ParseMM(Inp_StartTime);
   int endUserMin   = ParseHH(Inp_EndTime)   * 60 + ParseMM(Inp_EndTime);
   int offsetMin    = (Inp_BrokerGMT - Inp_UserGMT) * 60;
   m_sensors.brokerStartMin = ((startUserMin + offsetMin) % 1440 + 1440) % 1440;
   m_sensors.brokerEndMin   = ((endUserMin   + offsetMin) % 1440 + 1440) % 1440;
}

bool IsInTradingWindow()
{
   if(!Inp_UseTimeFilter) return true;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int nowMin = dt.hour * 60 + dt.min;
   int s = m_sensors.brokerStartMin;
   int e = m_sensors.brokerEndMin;
   if(s <= e) return (nowMin >= s && nowMin < e);
   else        return (nowMin >= s || nowMin < e);
}

bool TrendFilter200OK(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseTrendFilter200) return true;
   if(m_mkt.ema200 <= 0) return true;
   MqlTick tk; if(!GetTick(tk)) return true;
   double mid = (tk.bid + tk.ask) / 2.0;
   if(type == ORDER_TYPE_BUY)  return (mid > m_mkt.ema200);
   if(type == ORDER_TYPE_SELL) return (mid < m_mkt.ema200);
   return true;
}

bool VolatilityOK()
{
   if(!Inp_UseVolatFilter) return true;
   if(m_mkt.atrSlow <= 0) return true;
   m_sensors.atrRatio = m_mkt.atr / m_mkt.atrSlow;
   return (m_sensors.atrRatio <= Inp_ATRRatioMax);
}

bool MarginGuardOK()
{
   if(!Inp_UseMarginGuard) return true;
   double lot    = CalcLot(0);
   double marg1  = 0;
   MqlTick tk; if(!GetTick(tk)) return true;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lot, tk.ask, marg1)) return true;
   if(marg1 <= 0) return true;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   return (free >= marg1 * (1.0 + Inp_MarginGuardLevels));
}

void UpdateSensors()
{
   m_sensors.blockReason = "";

   m_sensors.timeOK = IsInTradingWindow();
   if(!m_sensors.timeOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Fuera de ventana horaria";

   // *** V7.7 [SPREAD RANGE]: Sensor 2 ahora verifica rango minimo y maximo ***
   m_sensors.spreadOK = SpreadOK();
   if(!m_sensors.spreadOK && m_sensors.blockReason == "") {
      int curSpr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(curSpr < Inp_MinSpread)
         m_sensors.blockReason = "Spread: " + IntegerToString(curSpr) + " pts (min " + IntegerToString(Inp_MinSpread) + " requerido)";
      else
         m_sensors.blockReason = "Spread: " + IntegerToString(curSpr) + " pts (max " + IntegerToString(Inp_MaxSpread) + ")";
   }

   if(m_mkt.ema200 > 0) {
      MqlTick tk; GetTick(tk);
      double mid = (tk.bid + tk.ask) / 2.0;
      m_sensors.trendBull = (mid > m_mkt.ema200);
   } else {
      m_sensors.trendBull = true;
   }

   m_sensors.volatOK = VolatilityOK();
   if(!m_sensors.volatOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Tormenta ATR: ratio=" + DoubleToString(m_sensors.atrRatio, 1);

   m_sensors.marginOK = MarginGuardOK();
   if(!m_sensors.marginOK && m_sensors.blockReason == "")
      m_sensors.blockReason = "Margen insuf. para " + IntegerToString(Inp_MarginGuardLevels) + " niveles";

   m_sensors.allOK = (m_sensors.timeOK && m_sensors.spreadOK &&
                      m_sensors.volatOK && m_sensors.marginOK);
}

//=================================================================
//  ADX
//=================================================================
bool ADXAllowsEntry(ENUM_ORDER_TYPE type)
{
   if(!Inp_UseADX) return true;
   double adxLevel = m_inSession ? Inp_ADXTrendLevel : Inp_ADXTrendLevelOff;
   if(m_mkt.adx < adxLevel) return true;
   int htf = m_mkt.htfTrend;
   if(htf == 0) return false;
   return (type == ORDER_TYPE_BUY && htf == 1) || (type == ORDER_TYPE_SELL && htf == -1);
}

//=================================================================
//  CONTROL DIARIO
//=================================================================
void ResetDailyIfNeeded()
{
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   int sec = dt.hour * 3600 + dt.min * 60 + dt.sec;
   datetime midnight = TimeCurrent() - sec;
   if(m_lastDailyReset < midnight) {
      m_dailyBalance   = AccountInfoDouble(ACCOUNT_BALANCE);
      m_dailyLimitHit  = false;
      m_lastDailyReset = midnight;
   }
}

bool DailyLimitReached()
{
   if(!Inp_UseDailyLimit) return false;
   if(m_dailyLimitHit) return true;
   double eff = (AccountInfoDouble(ACCOUNT_BALANCE) - m_dailyBalance) + m_port.totalProfit;
   double lim = MathMin(MathAbs(Inp_DailyLossUSD), m_dailyBalance * MathAbs(Inp_DailyLossPct));
   if(eff <= -lim) {
      Print("[AQ V7.7] LIMITE DIARIO: pausa nuevas primarias, recovery y posiciones continuan");
      m_dailyLimitHit = true;
      m_isPaused      = true;
   }
   return m_dailyLimitHit;
}

void UpdateStreak(double pnl)
{
   if(pnl < -0.01) {
      m_consecutiveLosses++;
      if(m_consecutiveLosses >= Inp_LossStreakMax && m_lotMultiplier == 1.0)
         m_lotMultiplier = Inp_LossStreakReduce;
   } else if(pnl > 0.01) {
      m_lotMultiplier     = 1.0;
      m_consecutiveLosses = 0;
   }
}

double CalcExpectancy()
{
   int total = m_totalWins + m_totalLosses;
   if(total == 0) return 0;
   double wr  = (double)m_totalWins / total;
   double lr  = 1.0 - wr;
   double avgW = (m_totalWins  > 0) ? m_sumWins   / m_totalWins  : 0;
   double avgL = (m_totalLosses> 0) ? m_sumLosses / m_totalLosses: 0;
   return (wr * avgW) - (lr * avgL);
}

//=================================================================
//  CIERRE
//=================================================================
bool ClosePos(ulong ticket, string reason = "")
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

   if(m_trade.PositionClose(ticket)) {
      UpdateStreak(pf);
      if(pf > 0) { m_cycleWinsSum += pf; m_cycleWinsCount++; m_totalWins++;   m_sumWins   += pf; }
      else        { m_cycleLossSum += pf;                      m_totalLosses++; m_sumLosses += MathAbs(pf); }
      m_totalPnL += pf; m_tradesClosed++;
      if(pf > m_bestClosed)  m_bestClosed  = pf;
      if(pf < m_worstClosed) m_worstClosed = pf;

      int idx = FindRec(ticket);
      if(idx >= 0) {
         if(m_rec[idx].isPrimary) m_lastPrimaryLost = (pf < 0);
         if(m_rec[idx].isLBC) {
            string comm = m_rec[idx].comment;
            if(StringFind(comm, "LBC_B") >= 0 && m_lbc.buyCount > 0)  m_lbc.buyCount--;
            if(StringFind(comm, "LBC_S") >= 0 && m_lbc.sellCount > 0) m_lbc.sellCount--;
            if(pf > 0) { m_lbc.harvestedTotal += pf; m_lbc.harvestCount++; }
         }
         // *** V7.7 [PPH]: Resetear estado PPH si se cierra el hedge ***
         if(ticket == m_pphHedgeTicket) { m_pphHedgeTicket = 0; m_pphActive = false; }
         Print("[AQ V7.7] CERRADA #", ticket, " $", NormalizeDouble(pf,2),
               (reason != "" ? " [" + reason + "]" : ""));
         ZeroMemory(m_rec[idx]);
      }
      return true;
   }
   return false;
}

bool CloseRescuePos(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   if(m_trade.PositionClose(ticket)) {
      m_totalPnL += pf; m_tradesClosed++;
      Print("[AQ V7.7] RESCATE CERRADA #", ticket, " $", NormalizeDouble(pf,2), " [", reason, "]");
      return true;
   }
   return false;
}

bool CloseBlockIfPositive(string reason)
{
   if(m_port.totalProfit < Inp_BlockTPTarget) return false;

   Print("[AQ V7.7] CIERRE POSITIVO: PnL=$", NormalizeDouble(m_port.totalProfit,2),
         " >= $", Inp_BlockTPTarget, " [", reason, "] | Rescatadas:", m_port.rescueCount);
   m_isProcessing = true;

   for(int pass = 0; pass < 2; pass++) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(magic != Inp_Magic) continue;
         double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(pass == 0 && pf <  0) continue;
         if(pass == 1 && pf >= 0) continue;
         ClosePos(t, reason);
      }
   }

   if(Inp_RescueAllTrades) {
      for(int pass = 0; pass < 2; pass++) {
         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            long magic = PositionGetInteger(POSITION_MAGIC);
            if(magic == Inp_Magic) continue;
            double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            if(pass == 0 && pf <  0) continue;
            if(pass == 1 && pf >= 0) continue;
            CloseRescuePos(t, "RESCUE_" + reason);
         }
      }
   }

   m_isProcessing        = false;
   m_recoveryActive      = false;
   m_recoveryOrders      = 0;
   m_recoveryTrendHedge  = false;
   m_netHedge1Applied    = false;
   m_netHedge2Applied    = false;
   // *** V7.7 [PPH]: Resetear estado PPH al cerrar el bloque ***
   m_pphHedgeTicket      = 0;
   m_pphActive           = false;
   m_cycleResetTime      = TimeCurrent();
   m_cycleInPause        = true;
   m_lastCTBuyPrice      = m_lastCTSellPrice = 0;
   ZeroMemory(m_lbc);
   return true;
}

//=================================================================
//  LOTES (INTOCABLES)
//=================================================================
double CalcLot(int level = 0)
{
   double sessionFactor = m_inSession ? 1.0 : Inp_OffSessionLotFactor;
   if(!Inp_UseDynamicLot || m_mkt.atr <= 0)
      return NormLot(Inp_LotBase * m_lotMultiplier * sessionFactor);

   double bal     = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskUSD = bal * Inp_RiskPerTradePct;
   double slATR   = m_inSession ? Inp_SL_ATR : Inp_OffSessionSL_ATR;
   double slDist  = m_mkt.atr * slATR;
   double tv = GetTickVal(), ts = GetTickSize();
   double lot = Inp_LotBase;
   if(tv > 0 && ts > 0 && slDist > 0) {
      double pipV = tv / ts;
      if(pipV > 0) lot = riskUSD / (slDist * pipV);
   }
   return NormLot(MathMax(lot, Inp_LotBase) * m_lotMultiplier * sessionFactor);
}

// INTOCABLE: CalcRecoveryLot
double CalcRecoveryLot()
{
   double atr = m_mkt.atr;
   if(atr <= 0) return NormLot(Inp_LotBase * Inp_RecoveryMinLotMult);

   double blockLoss   = MathAbs(m_port.totalProfit);
   double totalNeeded = blockLoss + Inp_BlockTPTarget;
   double moveDist    = atr * Inp_RecoveryMoveATR;
   if(moveDist <= 0) moveDist = atr * 0.5;

   double tv = GetTickVal(), ts = GetTickSize();
   double profitPer1LotPerDist = 0;
   if(tv > 0 && ts > 0)
      profitPer1LotPerDist = (moveDist / ts) * tv;

   double calcLot = Inp_LotBase;
   if(profitPer1LotPerDist > 0)
      calcLot = totalNeeded / profitPer1LotPerDist;

   double loserLot = Inp_LotBase;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME);
      if(pf == m_port.worstProfit) { loserLot = vol; break; }
   }

   double minRecLot = loserLot * Inp_RecoveryMinLotMult;
   double finalLot  = MathMax(calcLot, minRecLot);

   Print("[AQ V7.7] REC LOT: necesito ganar $", NormalizeDouble(totalNeeded,2),
         " en ", NormalizeDouble(moveDist,_Digits), " pts | 1lot=$",
         NormalizeDouble(profitPer1LotPerDist,2),
         " | calc=", NormalizeDouble(calcLot,2),
         " | min=",  NormalizeDouble(minRecLot,2),
         " | final=",NormalizeDouble(NormLot(finalLot),2));

   return NormLot(finalLot);
}

//=================================================================
//  APERTURA — SL=0, TP=0 siempre
//  *** V7.7 [DYNAMIC POSITIONS]: Recovery usa limite dinamico por margen ***
//=================================================================
ulong OpenOrder(ENUM_ORDER_TYPE type, double lot, string comment, bool skipPosLimit = false)
{
   if((m_isPaused || m_emergencyMode) && !skipPosLimit) return 0;
   if(!SpreadOK()) return 0;

   // *** V7.7 [DYNAMIC POSITIONS]: Primarias = limite configurado; Recovery = limite por margen ***
   if(!skipPosLimit) {
      if(PositionsTotal() >= Inp_MaxPositionsTotal) return 0;
   } else {
      int dynMax = CalcDynamicMaxPositions();
      if(dynMax <= 0 || PositionsTotal() >= dynMax) return 0;
   }

   lot = NormLot(lot); if(lot <= 0) return 0;
   if(!MarginOK(lot, type)) return 0;

   MqlTick t; if(!GetTick(t)) return 0;
   double price = (type == ORDER_TYPE_BUY) ? t.ask : t.bid;

   bool ok = (type == ORDER_TYPE_BUY)
      ? m_trade.Buy( lot, _Symbol, price, 0, 0, comment)
      : m_trade.Sell(lot, _Symbol, price, 0, 0, comment);

   if(!ok) { Print("[AQ V7.7] ERR apertura: ", m_trade.ResultRetcodeDescription()); return 0; }

   ulong ticket = m_trade.ResultOrder();
   if(ticket > 0) {
      m_tradesOpened++;
      Print("[AQ V7.7] ABIERTA #", ticket, " ",
            (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot=", lot, " @ ", NormalizeDouble(price, _Digits),
            " SL=0 TP=0 [", comment, "]");
   }
   return ticket;
}

void ManagePositions() {}

//=================================================================
//  *** V7.7 [PRIMARY POSITION HEDGE]: Hedge automatico de la primera operacion ***
//
//  Si la posicion primaria alcanza -$0.50 flotante, abre una orden
//  contraria del mismo lote para detener la hemorragia.
//  Esta segunda operacion es para frenar la perdida mientras el EA
//  analiza el mercado y decide la estrategia de recuperacion optima.
//=================================================================
void RunPrimaryPositionHedge()
{
   if(!Inp_UsePPH || m_isPaused || m_isProcessing) return;
   if(m_port.totalPos == 0) {
      // No hay posiciones: resetear estado PPH
      if(m_pphActive && !PositionSelectByTicket(m_pphHedgeTicket)) {
         m_pphHedgeTicket = 0;
         m_pphActive      = false;
      }
      return;
   }

   // Verificar si el PPH ya activo sigue abierto
   if(m_pphActive) {
      if(!PositionSelectByTicket(m_pphHedgeTicket)) {
         m_pphHedgeTicket = 0;
         m_pphActive      = false;
      } else {
         return; // PPH ya activo y valido: no abrir otro
      }
   }

   // Buscar la posicion primaria y su PnL actual
   ulong  primaryTicket = 0;
   double primaryPnL    = 0;
   double primaryLot    = 0;
   int    primaryType   = -1;

   for(int i = 0; i < MAX_RECORDS; i++) {
      if(m_rec[i].ticket == 0 || !m_rec[i].isPrimary) continue;
      if(!PositionSelectByTicket(m_rec[i].ticket)) continue;
      primaryPnL    = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      primaryTicket = m_rec[i].ticket;
      primaryLot    = m_rec[i].volume;
      primaryType   = m_rec[i].posType;
      break; // Solo necesitamos la primera posicion primaria
   }

   if(primaryTicket == 0) return;  // No hay posicion primaria registrada
   if(primaryPnL > Inp_PPHThreshold) return; // No ha alcanzado el umbral de perdida

   // Abrir hedge en la direccion contraria al mismo lote
   ENUM_ORDER_TYPE hedgeType = (primaryType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   m_isProcessing = true;
   ulong ticket = OpenOrder(hedgeType, primaryLot, "PPH_HEDGE", true);
   m_isProcessing = false;

   if(ticket > 0) {
      m_pphHedgeTicket = ticket;
      m_pphActive      = true;

      int idx = FreeRec();
      if(idx >= 0) {
         MqlTick tk; GetTick(tk);
         int    pt = (hedgeType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (hedgeType == ORDER_TYPE_BUY) ? tk.ask : tk.bid;
         InitRec(idx, ticket, pt, op, primaryLot, "PPH_HEDGE", false, false, true, false);
      }

      Print("[AQ V7.7] PPH ACTIVADO: #", ticket, " ",
            (hedgeType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
            " Lot=", NormalizeDouble(primaryLot, 2),
            " | Primaria PnL=$", NormalizeDouble(primaryPnL, 2),
            " (umbral $", NormalizeDouble(Inp_PPHThreshold, 2), ")");
   }
}

//=================================================================
//  RECOVERY ENGINE — *** V7.7: usa TEMA-Kalman para bearTrend/bullTrend ***
//=================================================================
void RunRecoveryEngine()
{
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD) {
      if(m_recoveryActive) { m_recoveryActive = false; m_recoveryOrders = 0; m_recoveryTrendHedge = false; }
      return;
   }
   if(m_port.totalPos == 0) return;
   if(m_isProcessing)        return;

   if(CloseBlockIfPositive("Recovery_TP")) return;

   if(!m_recoveryActive) {
      m_recoveryActive     = true;
      m_recoveryOrders     = m_port.recoveryCount;
      m_recoveryTrendHedge = false;
      Print("[AQ V7.7] RECOVERY ACTIVADO | PnL=$", NormalizeDouble(m_port.totalProfit,2),
            " | TEMA dir=", m_tk.direction, " slope=", DoubleToString(m_tk.slope, 6));
   }

   int maxRec = m_recoveryTrendHedge ? Inp_RecoveryMaxOrdersTrend : Inp_RecoveryMaxOrders;
   if(m_recoveryOrders >= maxRec) return;
   if(TimeCurrent() - m_lastRecoveryTime < Inp_RecoveryIntervalSec) return;
   if(!SpreadOK()) return;

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   if(m_losingPosOpenPrice > 0 && m_losingPosType >= 0) {
      double distFromLoser = 0;
      if(m_losingPosType == POSITION_TYPE_SELL)
         distFromLoser = tk.bid - m_losingPosOpenPrice;
      else
         distFromLoser = m_losingPosOpenPrice - tk.ask;

      double minDist = atr * Inp_RecoveryMinDistATR;
      if(distFromLoser < minDist) {
         Print("[AQ V7.7] RECOVERY: esperando dist | actual=",
               NormalizeDouble(distFromLoser, _Digits), " / min=", NormalizeDouble(minDist, _Digits));
         return;
      }
   }

   // *** V7.7 [TEMA+KALMAN]: Deteccion de tendencia con TEMA-Kalman (mas rapida y precisa) ***
   // Reemplaza la logica lenta de EMA21/55 para detectar si hay tendencia confirmada
   double adxLevel  = m_inSession ? Inp_ADXTrendLevel : Inp_ADXTrendLevelOff;
   bool   temaStrong = (MathAbs(m_tk.slope) > Inp_TrendMinSlope * 2.0); // Tendencia fuerte en TEMA

   // Con TEMA+Kalman: la tendencia se confirma por la direccion Y la fuerza del slope
   // ADX sigue como filtro de amplificacion, pero TEMA es el sensor primario
   bool   bearTrend = (m_tk.direction == -1 && temaStrong && m_mkt.adx > adxLevel * 0.7);
   bool   bullTrend = (m_tk.direction == 1  && temaStrong && m_mkt.adx > adxLevel * 0.7);

   ENUM_ORDER_TYPE recType;

   if(m_port.buyProfit < m_port.sellProfit && bearTrend) {
      recType = ORDER_TYPE_SELL;
      m_recoveryTrendHedge = true;
   } else if(m_port.sellProfit < m_port.buyProfit && bullTrend) {
      recType = ORDER_TYPE_BUY;
      m_recoveryTrendHedge = true;
   } else {
      m_recoveryTrendHedge = false;
      if(m_port.buyProfit < m_port.sellProfit) {
         recType = ORDER_TYPE_BUY;
         if(m_lastCTBuyPrice > 0 && MathAbs(tk.ask - m_lastCTBuyPrice) < atr * 0.3) return;
      } else {
         recType = ORDER_TYPE_SELL;
         if(m_lastCTSellPrice > 0 && MathAbs(tk.bid - m_lastCTSellPrice) < atr * 0.3) return;
      }
   }

   double recLot = CalcRecoveryLot();

   if(!MarginOK(recLot, recType)) {
      recLot = NormLot(recLot * 0.5);
      if(!MarginOK(recLot, recType)) {
         recLot = NormLot(Inp_LotBase);
         if(!MarginOK(recLot, recType)) {
            Print("[AQ V7.7] RECOVERY: Sin margen -> Activando LBC");
            ActivateLBC();
            return;
         }
      }
   }

   string recMode = m_recoveryTrendHedge ? "HEDGE-TEMA" : "PROMEDIADO";
   string recComm = "REC_" + (recType == ORDER_TYPE_BUY ? "B" : "S") +
                    "_" + IntegerToString(m_recoveryOrders + 1);
   m_isProcessing = true;
   ulong ticket = OpenOrder(recType, recLot, recComm, true);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (recType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (recType == ORDER_TYPE_BUY) ? tk.ask : tk.bid;
         InitRec(idx, ticket, pt, op, recLot, recComm, false, false, true, false);
      }
      if(recType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = tk.ask;
      else                            m_lastCTSellPrice = tk.bid;
      m_recoveryOrders++;
      m_lastRecoveryTime = TimeCurrent();
      Print("[AQ V7.7] REC ABIERTO #", ticket, " [", recMode, "] ",
            (recType==ORDER_TYPE_BUY?"BUY":"SELL"),
            " Lot=", NormalizeDouble(recLot,2),
            " Orden=", m_recoveryOrders, "/", maxRec,
            " | TEMA slope=", DoubleToString(m_tk.slope, 6), " dir=", m_tk.direction);
   }
}

//=================================================================
//  LBC ENGINE (INTOCABLE)
//=================================================================
void ActivateLBC()
{
   if(m_lbc.active) return;
   m_lbc.active        = true;
   m_lbc.activatedTime = TimeCurrent();
   m_lbc.buyCount      = 0;
   m_lbc.sellCount     = 0;
   m_lbc.lastBuyPrice  = 0;
   m_lbc.lastSellPrice = 0;
   m_lbc.harvestedTotal= 0;
   m_lbc.harvestCount  = 0;

   double freeMarg   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double margPer001 = CalcMarginFor001();
   double usableMarg = freeMarg * Inp_LBCMarginPct;
   m_lbc.maxOrdersCalc = (int)MathFloor(usableMarg / (2.0 * MathMax(margPer001, 0.01)));
   m_lbc.maxOrdersCalc = MathMax(1, MathMin(m_lbc.maxOrdersCalc, Inp_LBCMaxPairs));

   Print("[AQ V7.7] LBC ACTIVADO | LibreMarg=$", NormalizeDouble(freeMarg,2),
         " | MargPor0.01=$", NormalizeDouble(margPer001,2),
         " | MaxPares=", m_lbc.maxOrdersCalc);
}

// INTOCABLE: DeactivateLBC
void DeactivateLBC()
{
   if(!m_lbc.active) return;
   Print("[AQ V7.7] LBC DESACTIVADO | Cosechado: $",
         NormalizeDouble(m_lbc.harvestedTotal,2), " en ", m_lbc.harvestCount, " cosechas");
   ZeroMemory(m_lbc);
}

void RunLBCEngine()
{
   if(!m_lbc.active) return;
   if(m_port.totalPos == 0) { DeactivateLBC(); return; }
   if(m_isProcessing)        return;
   if(m_port.totalProfit >= Inp_BlockTPTarget) return;
   if(m_port.totalProfit >= Inp_RecoveryTriggerUSD * 0.5) { DeactivateLBC(); return; }

   MqlTick tk; if(!GetTick(tk)) return;
   double atr = m_mkt.atr; if(atr <= 0) return;

   double harvestMin = DistToUSD(atr * Inp_LBCHarvestATR, 0.01);
   harvestMin = MathMax(harvestMin, 0.02);

   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      string comm = PositionGetString(POSITION_COMMENT);
      if(StringFind(comm, "LBC_") < 0) continue;
      double pf = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      if(pf >= harvestMin) {
         ClosePos(t, "LBC_Harvest");
         double freeMarg   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         double margPer001 = CalcMarginFor001();
         m_lbc.maxOrdersCalc = (int)MathFloor(
            (freeMarg * Inp_LBCMarginPct) / (2.0 * MathMax(margPer001,0.01)));
         m_lbc.maxOrdersCalc = MathMax(1, MathMin(m_lbc.maxOrdersCalc, Inp_LBCMaxPairs));
      }
   }

   if(TimeCurrent() - m_lbc.lastOrderTime < Inp_LBCIntervalSec) return;
   if(!SpreadOK()) return;

   int totalLBCPairs = MathMin(m_lbc.buyCount, m_lbc.sellCount);
   if(totalLBCPairs >= m_lbc.maxOrdersCalc) return;

   double sessionMult = m_inSession ? 1.2 : 1.0;
   double gridSpace   = atr * Inp_LBCGridATR * sessionMult;
   double lot001      = NormLot(Inp_LotBase);

   bool needBuy = false, needSell = false;

   if(m_lbc.buyCount == 0 && m_lbc.sellCount == 0) {
      needBuy = true; needSell = true;
   } else {
      if(m_lbc.buyCount <= m_lbc.sellCount) {
         if(m_lbc.lastBuyPrice <= 0 || MathAbs(tk.ask - m_lbc.lastBuyPrice) >= gridSpace)
            needBuy = true;
      }
      if(m_lbc.sellCount <= m_lbc.buyCount) {
         if(m_lbc.lastSellPrice <= 0 || MathAbs(tk.bid - m_lbc.lastSellPrice) >= gridSpace)
            needSell = true;
      }
   }

   if(needBuy && MarginOK(lot001, ORDER_TYPE_BUY)) {
      string commB = "LBC_B" + IntegerToString(m_lbc.buyCount + 1);
      m_isProcessing = true;
      ulong ticketB = OpenOrder(ORDER_TYPE_BUY, lot001, commB, true);
      m_isProcessing = false;
      if(ticketB > 0) {
         int idx = FreeRec();
         if(idx >= 0) InitRec(idx, ticketB, POSITION_TYPE_BUY, tk.ask, lot001, commB,
                              false, false, false, true);
         m_lbc.buyCount++;
         m_lbc.lastBuyPrice  = tk.ask;
         m_lbc.lastOrderTime = TimeCurrent();
         Print("[AQ V7.7] LBC BUY #", ticketB, " B=", m_lbc.buyCount, " S=", m_lbc.sellCount);
      }
   }

   if(needSell && MarginOK(lot001, ORDER_TYPE_SELL)) {
      string commS = "LBC_S" + IntegerToString(m_lbc.sellCount + 1);
      m_isProcessing = true;
      ulong ticketS = OpenOrder(ORDER_TYPE_SELL, lot001, commS, true);
      m_isProcessing = false;
      if(ticketS > 0) {
         int idx = FreeRec();
         if(idx >= 0) InitRec(idx, ticketS, POSITION_TYPE_SELL, tk.bid, lot001, commS,
                              false, false, false, true);
         m_lbc.sellCount++;
         m_lbc.lastSellPrice = tk.bid;
         m_lbc.lastOrderTime = TimeCurrent();
         Print("[AQ V7.7] LBC SELL #", ticketS, " B=", m_lbc.buyCount, " S=", m_lbc.sellCount);
      }
   }
}

//=================================================================
//  BASKET TP
//=================================================================
void RunBasketTP()
{
   if(!Inp_UseBasketTP) return;
   if(TimeCurrent() - m_lastBasketCheck < Inp_BasketCheckSec) return;
   m_lastBasketCheck = TimeCurrent();
   if(m_port.totalPos < 2) return;
   if(m_port.totalProfit < Inp_BlockTPTarget) return;
   double avgWin = (m_cycleWinsCount > 0) ? m_cycleWinsSum / m_cycleWinsCount : Inp_BasketTPFactor;
   double target = MathMax(Inp_BlockTPTarget, avgWin * Inp_BasketTPRatio);
   if(m_port.totalProfit >= target) CloseBlockIfPositive("BasketTP");
}

void CheckCycleMaxLoss()
{
   if(!Inp_UseCycleMaxLoss || m_port.totalPos == 0) return;
   if(m_port.totalProfit <= Inp_CycleMaxLossUSD) {
      Print("[AQ V7.7] CYCLE MAX LOSS: $", NormalizeDouble(m_port.totalProfit,2), " -> Forzando Recovery");
      if(!m_recoveryActive) { m_recoveryActive = true; m_recoveryOrders = 0; }
   }
}

//=================================================================
//  HARVEST
//=================================================================
void RunHarvest()
{
   if(!Inp_HarvestContinuous || m_isProcessing) return;
   if(TimeCurrent() - m_lastHarvestTime < Inp_HarvestIntervalSec) return;
   m_lastHarvestTime = TimeCurrent();
   if(m_port.totalProfit < Inp_BlockTPTarget) return;

   double atr = m_mkt.atr, tv = GetTickVal(), ts = GetTickSize();
   double sessMult = m_inSession ? 1.0 : 1.5;
   double hMin = Inp_HarvestMinUSD * sessMult;
   if(atr > 0 && tv > 0 && ts > 0) {
      double minL   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double atrUSD = (atr / ts) * tv * minL * Inp_HarvestATRMult * sessMult;
      hMin = MathMax(hMin, NormalizeDouble(atrUSD, 2));
   }

   int harvested = 0; double totalH = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)   continue;
      double pf  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      int    idx = FindRec(t);
      double kpf = (idx >= 0 && m_rec[idx].kInit) ? m_rec[idx].kX : pf;
      if(m_port.negativeSum > pf * 1.5 && pf > 0) continue;
      bool doH = (pf >= hMin * 3.0) ||
                 (kpf >= hMin && idx >= 0 && m_rec[idx].kInit && m_rec[idx].kK <= 0.30);
      if(doH && ClosePos(t, "Harvest")) { harvested++; totalH += pf; }
   }
   if(harvested > 0)
      Print("[AQ V7.7] HARVEST: ", harvested, " cerradas | $", NormalizeDouble(totalH,2));
}

//=================================================================
//  EQUITY GUARD (fix V7.3F preservado)
//=================================================================
bool CheckEquityGuard()
{
   if(!Inp_UseEquityGuard) return false;
   if(m_port.totalProfit <= Inp_EmergencyLossUSD && !m_emergencyMode) {
      Print("[AQ V7.7] ALERTA EQUITY: $", NormalizeDouble(m_port.totalProfit,2),
            " -> Pausa primarias. Recovery/LBC/PPH/Rescue siguen activos.");
      m_emergencyMode = true;
      m_isPaused      = true;
      return true;
   }
   if(m_port.currentDD >= Inp_MaxDrawdownPct)
      m_isPaused = true;
   else if(m_isPaused && !m_emergencyMode && !m_dailyLimitHit &&
           m_port.currentDD < Inp_MaxDrawdownPct * 0.5)
      m_isPaused = false;
   return false;
}

//=================================================================
//  CT ENGINE — V7.7: usa TEMA-Kalman, sensores, spread range
//=================================================================
bool ShouldOpenCT(ENUM_ORDER_TYPE &ctType, double &ctLot, int &ctLevel)
{
   if(m_port.totalPos == 0) return false;
   if(m_port.totalPos >= Inp_MaxPositionsTotal) return false;
   if(m_port.totalProfit >= 0 && m_port.negativeSum == 0) return false;
   if(m_recoveryActive) return false;
   if(m_lbc.active)     return false;
   if(m_mkt.atr <= 0)   return false;

   int  buyCount  = m_port.buyCount;
   int  sellCount = m_port.sellCount;
   bool buyLosing  = (m_port.buyProfit  < -0.05 && buyCount  > 0);
   bool sellLosing = (m_port.sellProfit < -0.05 && sellCount > 0);
   bool openBuy = false, openSell = false;

   if(buyLosing && !sellLosing) {
      if(sellCount >= Inp_CTMaxSameDir) return false;
      openSell = true;
   } else if(sellLosing && !buyLosing) {
      if(buyCount >= Inp_CTMaxSameDir) return false;
      openBuy = true;
   } else if(buyLosing && sellLosing) {
      if(m_mkt.htfTrend == 1  && buyCount  < Inp_CTMaxSameDir) openBuy  = true;
      else if(m_mkt.htfTrend == -1 && sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(m_port.buyProfit < m_port.sellProfit && sellCount < Inp_CTMaxSameDir) openSell = true;
      else if(buyCount < Inp_CTMaxSameDir) openBuy = true;
      else return false;
   } else return false;

   ENUM_ORDER_TYPE testType = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!ADXAllowsEntry(testType)) return false;

   double ctDist = (Inp_CTMode == CT_ATR_DISTANCE)
      ? m_mkt.atr * Inp_CTDistanceATR
      : Inp_CTFixedPoints * _Point;
   MqlTick t; if(!GetTick(t)) return false;
   if(ctDist > 0) {
      if(openBuy  && m_lastCTBuyPrice  > 0 && MathAbs(t.ask - m_lastCTBuyPrice)  < ctDist) return false;
      if(openSell && m_lastCTSellPrice > 0 && MathAbs(t.bid - m_lastCTSellPrice) < ctDist) return false;
   }
   ctLevel = openBuy ? buyCount : sellCount;
   ctLot   = CalcLot(ctLevel);
   ctType  = openBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   return true;
}

void RunCTEngine()
{
   if(m_isProcessing || m_isPaused || m_emergencyMode || m_cycleInPause) return;
   if(TimeCurrent() - m_lastCTTime < Inp_CTIntervalSec) return;
   m_lastCTTime = TimeCurrent();

   MqlTick ts; if(!GetTick(ts)) return;
   double maxSpr = m_inSession ? (double)Inp_MaxSpread : Inp_CTMaxSpreadOff;
   int    curSpr = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   // FIX V7.7.4 CRÍTICO: SYMBOL_SPREAD ya devuelve puntos directamente.
   // La expresión (curSpr / _Point) convertía ej. 15pts en 1500, siempre > maxSpr=20.
   // Eso bloqueaba el 100% de las entradas en XAUUSD. Corrección: comparar directo.
   if(curSpr < Inp_MinSpread || curSpr > (int)maxSpr) return;

   if(m_port.totalPos == 0) {
      // ── ENTRADA PRIMARIA — Sensores + TEMA-Kalman + verificacion de margen preflight ──
      if(!m_sensors.allOK) {
         static datetime lastSensorLog = 0;
         if(TimeCurrent() - lastSensorLog >= 60) {
            Print("[AQ V7.7] ENTRADA BLOQUEADA: ", m_sensors.blockReason);
            lastSensorLog = TimeCurrent();
         }
         return;
      }

      if(m_stormActive) {
         static datetime lastStormLog = 0;
         if(TimeCurrent() - lastStormLog >= 30) {
            Print("[AQ V7.7C] PRIMARY BLOQUEADA por TORMENTA | ATRratio=",
                  NormalizeDouble(m_stormLastATRRatio,2));
            lastStormLog = TimeCurrent();
         }
         return;
      }

      // *** V7.7 [DYNAMIC POSITIONS]: Pre-flight de margen antes de abrir la primaria ***
      if(!HasSufficientMarginForCycle()) {
         static datetime lastMarginLog = 0;
         if(TimeCurrent() - lastMarginLog >= 120) {
            Print("[AQ V7.7] ENTRADA BLOQUEADA: margen insuficiente para ciclo completo");
            lastMarginLog = TimeCurrent();
         }
         return;
      }

      int cooldown = m_inSession ? Inp_PrimaryCooldownSec : Inp_PrimaryCooldownOff;
      if(TimeCurrent() - m_lastPrimaryTime < cooldown) return;

      // *** V7.7 [TEMA+KALMAN]: Usa TEMA-Kalman como señal primaria de entrada ***
      ENUM_ORDER_TYPE initType;
      if(m_mkt.isBullish)      initType = ORDER_TYPE_BUY;
      else if(m_mkt.isBearish) initType = ORDER_TYPE_SELL;
      else if(m_tk.direction == 1)  initType = ORDER_TYPE_BUY;
      else if(m_tk.direction == -1) initType = ORDER_TYPE_SELL;
      else if(m_mkt.emaFast > m_mkt.emaSlow) initType = ORDER_TYPE_BUY;
      else                                     initType = ORDER_TYPE_SELL;

      if(m_lastPrimaryLost && m_lastPrimaryDir != 0) {
         ENUM_ORDER_TYPE alt = (m_lastPrimaryDir == 1) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
         if(initType != alt) { initType = alt; m_lastPrimaryLost = false; }
      }
      if(!ADXAllowsEntry(initType)) return;

      if(!TrendFilter200OK(initType)) {
         static datetime lastTrendLog = 0;
         if(TimeCurrent() - lastTrendLog >= 60) {
            string dir = (initType == ORDER_TYPE_BUY) ? "BUY" : "SELL";
            Print("[AQ V7.7] ENTRADA BLOQUEADA por EMA200: ", dir,
                  " vs EMA200=", DoubleToString(m_mkt.ema200, _Digits));
            lastTrendLog = TimeCurrent();
         }
         return;
      }

      if(!m_inSession) {
         bool clearSignal = (m_mkt.isBullish && initType == ORDER_TYPE_BUY) ||
                            (m_mkt.isBearish && initType == ORDER_TYPE_SELL);
         if(!clearSignal) return;
      }

      double lot = CalcLot(0);
      m_isProcessing = true;
      ulong ticket = OpenOrder(initType, lot, "Primary_Entry");
      if(ticket > 0) {
         int idx = FreeRec();
         if(idx >= 0) {
            int    pt = (initType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
            double op = (initType == ORDER_TYPE_BUY) ? ts.ask : ts.bid;
            InitRec(idx, ticket, pt, op, lot, "Primary_Entry", true, false, false, false);
         }
         m_lastPrimaryDir     = (initType == ORDER_TYPE_BUY) ? 1 : -1;
         m_lastPrimaryTime    = TimeCurrent();
         if(initType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = ts.ask;
         else                             m_lastCTSellPrice = ts.bid;
         m_recoveryActive     = false;
         m_recoveryOrders     = 0;
         m_recoveryTrendHedge = false;
         m_pphHedgeTicket     = 0; // Reset PPH al abrir nueva primaria
         m_pphActive          = false;
         DeactivateLBC();
         Print("[AQ V7.7] PRIMARIA #", ticket, " | TEMA dir=", m_tk.direction,
               " slope=", DoubleToString(m_tk.slope, 6),
               " | DynMax=", CalcDynamicMaxPositions());
      }
      m_isProcessing = false;
      return;
   }

   // Ciclo activo: CT normal
   ENUM_ORDER_TYPE ctType; double ctLot; int ctLevel;
   if(!ShouldOpenCT(ctType, ctLot, ctLevel)) return;
   if(!MarginOK(ctLot, ctType)) return;

   string ctComm = "CT_" + (ctType == ORDER_TYPE_BUY ? "B" : "S") +
                   "_L" + IntegerToString(ctLevel + 1);
   m_isProcessing = true;
   ulong ticket = OpenOrder(ctType, ctLot, ctComm);
   m_isProcessing = false;

   if(ticket > 0) {
      int idx = FreeRec();
      if(idx >= 0) {
         int    pt = (ctType == ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
         double op = (ctType == ORDER_TYPE_BUY) ? ts.ask : ts.bid;
         InitRec(idx, ticket, pt, op, ctLot, ctComm, false, true, false, false);
      }
      if(ctType == ORDER_TYPE_BUY)  m_lastCTBuyPrice  = ts.ask;
      else                           m_lastCTSellPrice = ts.bid;
   }
}

//=================================================================
//  V7.6B: NET EXPOSURE HEDGE ENGINE (PRESERVADO)
//=================================================================
void RunNetExposureHedge()
{
   if(!Inp_UseNetHedge || m_port.totalPos == 0 || m_isProcessing) return;

   double netVol = NormalizeDouble(m_port.buyVolume - m_port.sellVolume, 2);
   if(MathAbs(netVol) < 0.005) return;

   double loss = m_port.totalProfit;
   if(loss > Inp_NetHedgeTrigger1USD) return;
   if(TimeCurrent() - m_lastNetHedgeTime < Inp_NetHedgeIntervalSec) return;
   if(!SpreadOK()) return;

   ENUM_ORDER_TYPE hedgeType = (netVol > 0) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;

   if(loss <= Inp_NetHedgeTrigger2USD && !m_netHedge2Applied) {
      double pctAlreadyCovered = m_netHedge1Applied ? 0.50 : 0.0;
      double pctToAdd          = 1.0 - pctAlreadyCovered;
      double hedgeLot          = NormLot(MathAbs(netVol) * pctToAdd);

      if(hedgeLot > 0 && MarginOK_Hedge(hedgeLot, hedgeType)) {
         string comm = "NET_HEDGE_L2";
         m_isProcessing = true;
         ulong ticket = OpenOrder(hedgeType, hedgeLot, comm, true);
         m_isProcessing = false;

         if(ticket > 0) {
            m_netHedge2Applied = true;
            if(!m_netHedge1Applied) m_netHedge1Applied = true;
            m_lastNetHedgeTime = TimeCurrent();
            MqlTick tk; GetTick(tk);
            int idx = FreeRec();
            if(idx >= 0) {
               int    pt = (hedgeType==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
               double op = (hedgeType==ORDER_TYPE_BUY) ? tk.ask : tk.bid;
               InitRec(idx, ticket, pt, op, hedgeLot, comm, false, false, true, false);
            }
            Print("[AQ V7.7] NET HEDGE L2 (100%) ABIERTO: ",
                  (hedgeType==ORDER_TYPE_BUY?"BUY":"SELL"), " ", hedgeLot,
                  " | PnL=$", NormalizeDouble(loss,2));
         }
      }
      return;
   }

   if(loss <= Inp_NetHedgeTrigger1USD && !m_netHedge1Applied) {
      double hedgeLot = NormLot(MathAbs(netVol) * 0.50);

      if(hedgeLot > 0 && MarginOK_Hedge(hedgeLot, hedgeType)) {
         string comm = "NET_HEDGE_L1";
         m_isProcessing = true;
         ulong ticket = OpenOrder(hedgeType, hedgeLot, comm, true);
         m_isProcessing = false;

         if(ticket > 0) {
            m_netHedge1Applied = true;
            m_lastNetHedgeTime = TimeCurrent();
            MqlTick tk; GetTick(tk);
            int idx = FreeRec();
            if(idx >= 0) {
               int    pt = (hedgeType==ORDER_TYPE_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
               double op = (hedgeType==ORDER_TYPE_BUY) ? tk.ask : tk.bid;
               InitRec(idx, ticket, pt, op, hedgeLot, comm, false, false, true, false);
            }
            Print("[AQ V7.7] NET HEDGE L1 (50%) ABIERTO: ",
                  (hedgeType==ORDER_TYPE_BUY?"BUY":"SELL"), " ", hedgeLot,
                  " | PnL=$", NormalizeDouble(loss,2));
         }
      }
   }
}

//=================================================================
//  V7.6C: VOLATILITY STORM FILTER (PRESERVADO)
//=================================================================
double CalcAvgATR(int windowBars)
{
   if(windowBars <= 0 || h_ATR == INVALID_HANDLE) return 0;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(h_ATR, 0, 1, windowBars, buf) < windowBars) return 0;
   double sum = 0;
   for(int i = 0; i < windowBars; i++) sum += buf[i];
   return (sum / windowBars);
}

double CalcAvgSpread(int windowBars)
{
   if(windowBars <= 0) return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, windowBars, rates) < windowBars)
      return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double sumSpread = 0;
   for(int i = 0; i < windowBars; i++)
      sumSpread += (rates[i].high - rates[i].low) / _Point;
   return (sumSpread / windowBars);
}

bool IsVolatilityStormActive()
{
   if(!Inp_UseStormFilter) return false;
   double atrNow = m_mkt.atr;
   if(atrNow <= 0) return false;

   double atrAvg  = CalcAvgATR(Inp_StormATRWindow);
   bool   atrStorm = false;
   if(atrAvg > 0) {
      m_stormLastATRRatio = atrNow / atrAvg;
      atrStorm = (m_stormLastATRRatio >= Inp_StormATRMult);
   }

   double sprNow  = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double sprAvg  = CalcAvgSpread(Inp_StormSpreadWindow);
   bool   sprStorm = false;
   if(sprAvg > 0) {
      m_stormLastSprRatio = sprNow / sprAvg;
      double sprNorm = sprNow / (double)MathMax(Inp_MaxSpread, 1);
      sprStorm = (sprNorm > Inp_StormSpreadMult * 0.5);
   }

   bool stormNow = (atrStorm || sprStorm);

   if(stormNow && !m_stormActive) {
      m_stormActive       = true;
      m_stormDetectedTime = TimeCurrent();
      Print("[AQ V7.7C] TORMENTA DETECTADA | ATR ratio=",
            NormalizeDouble(m_stormLastATRRatio, 2),
            " | SPR ratio=", NormalizeDouble(m_stormLastSprRatio, 2));
   }

   if(m_stormActive) {
      if(TimeCurrent() - m_stormDetectedTime >= Inp_StormCooldownSec) {
         if(!stormNow) {
            m_stormActive = false;
            Print("[AQ V7.7C] TORMENTA DESPEJADA");
         } else m_stormDetectedTime = TimeCurrent();
      }
      return true;
   }
   return false;
}

void RunVolatilityStormFilter() { IsVolatilityStormActive(); }

//=================================================================
//  DASHBOARD DARK MODE — V7.7: agrega TEMA-Kalman + PPH + spread range + dynmax
//=================================================================
void AQLbl(string n, string txt, int x, int y, color c, int fs = 9, bool bold = false)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTED,   false);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     c);
   ObjectSetInteger(0, n, OBJPROP_FONTSIZE,  fs);
   ObjectSetString(0,  n, OBJPROP_FONT,      bold ? "Consolas Bold" : "Consolas");
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
}

void AQBtn(string n, string txt, int x, int y, int w, int h, color bg, color fg = clrWhite)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_FONTSIZE,   8);
      ObjectSetString(0,  n, OBJPROP_FONT,       "Consolas");
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,     w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,     h);
   ObjectSetString(0,  n, OBJPROP_TEXT,      txt);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,   bg);
   ObjectSetInteger(0, n, OBJPROP_COLOR,     fg);
}

void AQPanel(string n, int x, int y, int w, int h)
{
   if(ObjectFind(0, n) < 0) {
      ObjectCreate(0, n, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, n, OBJPROP_CORNER,     CORNER_LEFT_UPPER);
      ObjectSetInteger(0, n, OBJPROP_BACK,       false);
      ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, n, OBJPROP_SELECTED,   false);
      ObjectSetInteger(0, n, OBJPROP_HIDDEN,     true);
   }
   ObjectSetInteger(0, n, OBJPROP_XDISTANCE,   x);
   ObjectSetInteger(0, n, OBJPROP_YDISTANCE,   y);
   ObjectSetInteger(0, n, OBJPROP_XSIZE,       w);
   ObjectSetInteger(0, n, OBJPROP_YSIZE,       h);
   ObjectSetInteger(0, n, OBJPROP_BGCOLOR,     C'8,8,12');
   ObjectSetInteger(0, n, OBJPROP_COLOR,       C'70,70,70');
   ObjectSetInteger(0, n, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, n, OBJPROP_WIDTH,       1);
}

void DeleteDash()
{
   string old73[] = {"D73_BG","D73_T0","D73_T1",
      "D73_L1","D73_L2","D73_L3","D73_L4","D73_L5","D73_L6","D73_L7",
      "D73_L8","D73_L9","D73_L10","D73_L11","D73_L12","D73_L13","D73_L14","D73_L15",
      "D73_B1","D73_B2"};
   for(int i = 0; i < ArraySize(old73); i++) ObjectDelete(0, old73[i]);

   string aq75[] = {
      "AQ75_BG","AQ75_HDR","AQ75_SEP1","AQ75_STATE","AQ75_REASON",
      "AQ75_SEP2","AQ75_SENS_HDR",
      "AQ75_S1","AQ75_S2","AQ75_S3","AQ75_S4","AQ75_S5",
      "AQ75_SEP3","AQ75_RESCUE",
      "AQ75_SEP4","AQ75_ACC",
      "AQ75_SEP5","AQ75_PNL","AQ75_POS","AQ75_VWAP",
      "AQ75_REC","AQ75_NH","AQ75_SF","AQ75_SEP6","AQ75_HIST",
      "AQ75_SEP7","AQ75_DIAG",
      "AQ75_B1","AQ75_B2"};
   for(int i = 0; i < ArraySize(aq75); i++) ObjectDelete(0, aq75[i]);

   // *** V7.7: Limpiar objetos nuevos del dashboard ***
   string aq77[] = {
      "AQ77_SEP_TK","AQ77_TEMA","AQ77_PPH","AQ77_DYN"};
   for(int i = 0; i < ArraySize(aq77); i++) ObjectDelete(0, aq77[i]);
}

string SensorPill(string label, bool ok, string okTxt, string failTxt)
{
   return label + ":" + (ok ? okTxt : failTxt);
}

void UpdateDash()
{
   if(!Inp_ShowDashboard) return;
   if(TimeCurrent() - m_lastDashTime < 1) return;
   m_lastDashTime = TimeCurrent();

   color cBG     = C'8,8,12';
   color cBorder = C'70,70,70';
   color cWhite  = C'230,230,230';
   color cGray   = C'120,120,130';
   color cGreen  = C'0,220,80';
   color cRed    = C'220,50,50';
   color cOra    = C'220,150,30';
   color cYel    = C'200,200,50';
   color cCyan   = C'50,190,220';
   color cPurple = C'160,80,220';
   color cTEMA   = C'0,190,255'; // Azul celeste para TEMA-Kalman

   int x0  = Inp_DashX;
   int y0  = Inp_DashY;
   int lh  = 16;
   int pad = 8;
   int w   = 580;
   // *** V7.7: +4 filas para TEMA-Kalman, PPH, DynMax ***
   int h   = 35 * lh + 60;

   AQPanel("AQ75_BG", x0 - pad, y0 - pad, w, h);

   int x = x0, y = y0;

   AQLbl("AQ75_HDR",
         "[ " + VERSION_STR + " ]  " + _Symbol + "  |  SMART ADAPTIVE ENGINE",
         x, y, cGreen, 10, true);
   y += lh + 2;

   AQLbl("AQ75_SEP1",
         "────────────────────────────────────────────────────────────────────",
         x, y, cBorder, 8);
   y += lh - 4;

   string stateStr;
   color  stateC;
   if(m_emergencyMode)      { stateStr = "[ ALERTA EQUITY  -  RECOVERY ACTIVO ]";          stateC = cRed; }
   else if(m_dailyLimitHit) { stateStr = "[ LIMITE DIARIO  -  GESTION CONTINUA ]";         stateC = cOra; }
   else if(m_lbc.active)    { stateStr = "[ MODO LBC ACTIVO  -  MICRO-GRID ]";             stateC = cOra; }
   else if(m_recoveryActive){ stateStr = "[ RESCATANDO OPERACIONES ]";                      stateC = cYel; }
   else if(m_cycleInPause)  { stateStr = "[ PAUSA ENTRE CICLOS ]";                         stateC = cGray; }
   else if(m_isPaused)      { stateStr = "[ ROBOT EN PAUSA  -  RECOVERY OPERA ]";          stateC = cYel; }
   else if(m_port.rescueCount > 0) {
      stateStr = "[ RESCATE ACTIVO  -  " + IntegerToString(m_port.rescueCount) + " POS EXTERNAS ]";
      stateC   = cPurple;
   } else if(!m_sensors.allOK) { stateStr = "[ BUSCANDO CONDICIONES ]"; stateC = cGray; }
   else                         { stateStr = "[ BUSCANDO ENTRADA ]";     stateC = cGreen; }
   AQLbl("AQ75_STATE", stateStr, x, y, stateC, 10, true);
   y += lh + 2;

   string diagStr = "";
   if(!m_sensors.allOK && m_port.totalPos == 0)
      diagStr = "  Diagnostico: " + m_sensors.blockReason;
   else if(m_port.totalPos > 0 && m_port.totalProfit < 0)
      diagStr = "  Gestionando bloque en perdida | Recovery opera sin restriccion de sensores";
   AQLbl("AQ75_REASON", diagStr, x, y, cGray, 8);
   y += lh - 2;

   // ── TEMA-KALMAN (V7.7) ──────────────────────────────────
   AQLbl("AQ77_SEP_TK",
         "── TEMA-KALMAN TREND ENGINE (Tiempo Real) ──────────────────────────",
         x, y, C'30,60,90', 8);
   y += lh - 3;

   string temaDir   = (m_tk.direction == 1) ? "▲ ALCISTA" : (m_tk.direction == -1) ? "▼ BAJISTA" : "— LATERAL";
   color  temaDirC  = (m_tk.direction == 1) ? cGreen : (m_tk.direction == -1) ? cRed : cGray;
   string temaTxt   = "Tendencia: " + temaDir +
                      "   TEMA: " + (m_tk.tema > 0 ? DoubleToString(m_tk.tema, _Digits) : "Cargando...") +
                      "   Slope: " + DoubleToString(m_tk.slope * 1e5, 2) + "e-5" +
                      "   Periodo: " + IntegerToString(Inp_TEMAPeriod) +
                      "   KalmanQ=" + DoubleToString(Inp_KalmanQ, 3);
   AQLbl("AQ77_TEMA", temaTxt, x, y, temaDirC, 9);
   y += lh - 1;

   // ── SENSORES ──────────────────────────────────────────────
   AQLbl("AQ75_SEP2",
         "── SENSORES DE ENTRADA (5 filtros institucionales) ─────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   int curSpr   = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   string trendStr = m_sensors.trendBull ? "BULL" : "BEAR";
   color  trendC   = m_sensors.trendBull ? cGreen : cOra;

   AQLbl("AQ75_S1",
         SensorPill("TIME", m_sensors.timeOK, "  OK  ", "  WAIT"),
         x, y, m_sensors.timeOK ? cGreen : cRed, 9);

   // *** V7.7 [SPREAD RANGE]: Sensor 2 muestra MIN y MAX ***
   color sprC = m_sensors.spreadOK ? cGreen : cRed;
   string sprTxt;
   if(curSpr < Inp_MinSpread)
      sprTxt = "SPR:  MUY BAJO(" + IntegerToString(curSpr) + " < " + IntegerToString(Inp_MinSpread) + ")";
   else if(curSpr > Inp_MaxSpread)
      sprTxt = "SPR:  ALTO(" + IntegerToString(curSpr) + " > " + IntegerToString(Inp_MaxSpread) + ")";
   else
      sprTxt = "SPR:  OK(" + IntegerToString(curSpr) + " pts [" + IntegerToString(Inp_MinSpread) + "-" + IntegerToString(Inp_MaxSpread) + "])";
   AQLbl("AQ75_S2", sprTxt, x + 100, y, sprC, 9);

   AQLbl("AQ75_S3",
         "TEND200:  " + trendStr + (m_mkt.ema200 > 0 ? "  (" + DoubleToString(m_mkt.ema200,1) + ")" : "  (cargando)"),
         x + 280, y, trendC, 9);

   string ratioStr = (m_mkt.atrSlow > 0) ? DoubleToString(m_sensors.atrRatio, 2) : "N/A";
   AQLbl("AQ75_S4",
         SensorPill("VOLAT", m_sensors.volatOK, "  OK("+ratioStr+")", "  STORM("+ratioStr+")"),
         x + 430, y, m_sensors.volatOK ? cGreen : cRed, 9);

   y += lh - 1;
   AQLbl("AQ75_S5",
         SensorPill("MARGEN", m_sensors.marginOK,
                    "  OK  (>"+IntegerToString(Inp_MarginGuardLevels)+" niveles libre)",
                    "  BAJO (<"+IntegerToString(Inp_MarginGuardLevels)+" niveles)"),
         x, y, m_sensors.marginOK ? cGreen : cOra, 9);
   y += lh;

   // ── RESCATE UNIVERSAL ──────────────────────────────────────
   AQLbl("AQ75_SEP3",
         "── RESCATE UNIVERSAL ────────────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   string rescueMode   = Inp_RescueAllTrades ? "ACTIVO" : "INACTIVO";
   color  rescueC      = Inp_RescueAllTrades ? (m_port.rescueCount > 0 ? cPurple : cGreen) : cGray;
   string rescueDetail = Inp_RescueAllTrades
      ? (m_port.rescueCount > 0
         ? " | " + IntegerToString(m_port.rescueCount) + " pos externas | PnL externo: $" + DoubleToString(m_port.rescueProfit, 2)
         : " | Sin posiciones externas en " + _Symbol)
      : " | Solo gestiona magic=" + IntegerToString(Inp_Magic);
   AQLbl("AQ75_RESCUE", "MODO RESCATE: " + rescueMode + rescueDetail, x, y, rescueC, 9);
   y += lh;

   // ── CUENTA ────────────────────────────────────────────────
   AQLbl("AQ75_SEP4",
         "── CUENTA ───────────────────────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   double bal  = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double ddPct = m_port.currentDD * 100.0;
   color  ddC   = (ddPct > 10.0) ? cRed : (ddPct > 5.0) ? cOra : cGreen;
   int    dynMax = CalcDynamicMaxPositions();

   AQLbl("AQ75_ACC",
         "Saldo: $" + DoubleToString(bal,2) +
         "   Equity: $" + DoubleToString(eq,2) +
         "   LibreMarg: $" + DoubleToString(free,2) +
         "   DD: " + DoubleToString(ddPct,1) + "%",
         x, y, cCyan, 9);
   y += lh - 1;

   // *** V7.7 [DYNAMIC POSITIONS]: Mostrar limite dinamico calculado ***
   AQLbl("AQ77_DYN",
         "Max posiciones dinamico (por margen): " + IntegerToString(dynMax) +
         "   Margen/0.01: $" + DoubleToString(CalcMarginFor001(), 2) +
         "   PrefligthCiclo: " + (HasSufficientMarginForCycle() ? "OK" : "INSUF"),
         x, y, cCyan, 9);
   y += lh;

   // ── BLOQUE ACTIVO ─────────────────────────────────────────
   AQLbl("AQ75_SEP5",
         "── BLOQUE ACTIVO ────────────────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   double pnl   = m_port.totalProfit;
   double falta = MathMax(0, Inp_BlockTPTarget - pnl);
   color  pnlC  = (pnl >= 0) ? cGreen : cRed;
   AQLbl("AQ75_PNL",
         "PnL BLOQUE: " + (pnl >= 0 ? "+" : "") + DoubleToString(pnl,2) +
         "   Target: +$" + DoubleToString(Inp_BlockTPTarget,2) +
         "   Falta: $" + DoubleToString(falta,2),
         x, y, pnlC, 9);
   y += lh - 1;

   AQLbl("AQ75_POS",
         "Pos: " + IntegerToString(m_port.totalPos) +
         "   BUY: " + IntegerToString(m_port.buyCount) + " ($" + DoubleToString(m_port.buyProfit,2) + ")" +
         "   SELL: " + IntegerToString(m_port.sellCount) + " ($" + DoubleToString(m_port.sellProfit,2) + ")" +
         "   CT:" + IntegerToString(m_port.ctCount) +
         " REC:" + IntegerToString(m_port.recoveryCount) +
         " LBC:" + IntegerToString(m_port.lbcCount),
         x, y, cCyan, 9);
   y += lh - 1;

   string dirStr  = (m_port.blockDir > 0) ? "LARGO" : (m_port.blockDir < 0) ? "CORTO" : "NEUTRO";
   string vwapStr = (m_port.blockVWAP > 0)
      ? "VWAP: " + DoubleToString(m_port.blockVWAP, _Digits) + "   Sesgo: " + dirStr
      : "Sin posiciones abiertas";
   AQLbl("AQ75_VWAP", vwapStr, x, y, cGray, 9);
   y += lh - 1;

   // Recovery + LBC
   string recStr = m_recoveryActive
      ? "RECOVERY: ACTIVO (" + IntegerToString(m_recoveryOrders) + "/" + IntegerToString(Inp_RecoveryMaxOrders) + ")"
      : "RECOVERY: en espera";
   color recC = m_recoveryActive ? cYel : cGray;
   string lbcStr = m_lbc.active
      ? "   LBC: ACTIVO B=" + IntegerToString(m_lbc.buyCount) + " S=" + IntegerToString(m_lbc.sellCount) +
        " Cos=$" + DoubleToString(m_lbc.harvestedTotal,2)
      : "   LBC: en espera";
   AQLbl("AQ75_REC", recStr + lbcStr, x, y, recC, 9);
   y += lh - 1;

   // *** V7.7 [PPH]: Estado del Primary Position Hedge ***
   string pphStr;
   color  pphC;
   if(m_pphActive && m_pphHedgeTicket > 0) {
      pphStr = "PPH HEDGE ACTIVO: #" + IntegerToString((int)m_pphHedgeTicket) +
               " | Umbral: $" + DoubleToString(Inp_PPHThreshold,2) +
               " | La primaria fue protegida con cobertura contraria";
      pphC   = cYel;
   } else {
      pphStr = "PPH HEDGE: en espera | Activa si primaria <= $" + DoubleToString(Inp_PPHThreshold,2);
      pphC   = cGray;
   }
   AQLbl("AQ77_PPH", pphStr, x, y, pphC, 9);
   y += lh - 1;

   // Net Hedge
   double netV76 = m_port.buyVolume - m_port.sellVolume;
   string nhStr;
   color  nhC;
   if(m_netHedge2Applied)      { nhStr = "NET HEDGE L2 (100%) ACTIVO | NetVol: " + DoubleToString(netV76,2); nhC = cRed; }
   else if(m_netHedge1Applied) { nhStr = "NET HEDGE L1 (50%) ACTIVO | L2 en $" + DoubleToString(Inp_NetHedgeTrigger2USD,2); nhC = cOra; }
   else                         { nhStr = "NET HEDGE: espera | L1@$" + DoubleToString(Inp_NetHedgeTrigger1USD,2) + " L2@$" + DoubleToString(Inp_NetHedgeTrigger2USD,2) + " NetVol=" + DoubleToString(netV76,2); nhC = cGray; }
   AQLbl("AQ75_NH", nhStr, x, y, nhC, 9);
   y += lh - 1;

   // Storm Filter
   string sfStr;
   color  sfC;
   if(m_stormActive) {
      int remaining = Inp_StormCooldownSec - (int)(TimeCurrent() - m_stormDetectedTime);
      sfStr = "STORM FILTER: ACTIVO - PRIMARY BLOQUEADA | ATR=" + DoubleToString(m_stormLastATRRatio,2) + "x  Libre en: " + IntegerToString(MathMax(0,remaining)) + "s";
      sfC   = cRed;
   } else {
      sfStr = "STORM FILTER: OK | ATR=" + DoubleToString(m_stormLastATRRatio,2) + "x  SPR=" + DoubleToString(m_stormLastSprRatio,2) + "x";
      sfC   = cGray;
   }
   AQLbl("AQ75_SF", sfStr, x, y, sfC, 9);
   y += lh;

   // ── HISTORIAL ─────────────────────────────────────────────
   AQLbl("AQ75_SEP6",
         "── HISTORIAL ────────────────────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   int    totalT  = m_totalWins + m_totalLosses;
   double wrPct   = (totalT > 0) ? (double)m_totalWins / totalT * 100.0 : 0;
   double expect  = CalcExpectancy();
   color  expC    = (expect >= 0) ? cGreen : cOra;
   AQLbl("AQ75_HIST",
         "Win: " + DoubleToString(wrPct,1) + "% (" + IntegerToString(m_totalWins) + "/" + IntegerToString(totalT) + ")" +
         "   Expect: $" + DoubleToString(expect,3) +
         "   PnL cerrado: $" + DoubleToString(m_totalPnL,2) +
         "   Ticks: " + IntegerToString((int)m_tickCount),
         x, y, expC, 9);
   y += lh;

   // ── GMT ───────────────────────────────────────────────────
   AQLbl("AQ75_SEP7",
         "── INFORMACION GMT Y MERCADO ────────────────────────────────────────",
         x, y, C'50,50,80', 8);
   y += lh - 3;

   MqlDateTime dtNow; TimeToStruct(TimeCurrent(), dtNow);
   string brokerTime = StringFormat("%02d:%02d", dtNow.hour, dtNow.min);
   int sm = m_sensors.brokerStartMin;
   int em = m_sensors.brokerEndMin;
   string winStr = StringFormat("%02d:%02d-%02d:%02d broker", sm/60, sm%60, em/60, em%60);
   AQLbl("AQ75_DIAG",
         "Broker: " + brokerTime +
         "   Ventana: " + winStr +
         "   UserGMT:" + IntegerToString(Inp_UserGMT) +
         "   BrokerGMT:" + IntegerToString(Inp_BrokerGMT) +
         "   ATR: " + DoubleToString(m_mkt.atr,2) +
         "   Spread RANGO: " + IntegerToString(Inp_MinSpread) + "-" + IntegerToString(Inp_MaxSpread) + "pts",
         x, y, cGray, 8);
   y += lh + 4;

   // ── BOTONES ───────────────────────────────────────────────
   string pauseTxt = m_isPaused ? ">> REANUDAR TODO <<" : "|| PAUSAR PRIMARIAS";
   color  pauseBG  = m_isPaused ? C'180,130,0' : C'0,90,40';
   AQBtn("AQ75_B1", pauseTxt,               x,       y, 180, 22, pauseBG);
   AQBtn("AQ75_B2", "CERRAR TODAS (MANUAL)", x + 190, y, 180, 22, C'150,20,20');

   ChartRedraw(0);
}

//=================================================================
//  FILLING MODE (PRESERVADO)
//=================================================================
ENUM_ORDER_TYPE_FILLING DetectFillingMode()
{
   if((bool)MQLInfoInteger(MQL_TESTER)) return ORDER_FILLING_RETURN;
   long filling = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//=================================================================
//  OnInit — V7.7
//=================================================================
int OnInit()
{
   Print("=============================================================");
   Print("  " + VERSION_STR + " - SMART ADAPTIVE ENGINE");
   Print("  SL=0 en TODAS las ordenes - broker nunca cierra automaticamente");
   Print("  Fix V7.3F: Recovery opera incluso en modo emergencia");
   Print("  V7.7 [1]: TEMA+Kalman trend engine (lag casi cero)");
   Print("  V7.7 [2]: PPH - Hedge automatico de primaria a $", Inp_PPHThreshold);
   Print("  V7.7 [3]: Limite dinamico por margen real (100% del saldo)");
   Print("  V7.7 [4]: Spread rango ", Inp_MinSpread, "-", Inp_MaxSpread, " puntos");
   Print("  V7.6B: Net Hedge L1@$",Inp_NetHedgeTrigger1USD," L2@$",Inp_NetHedgeTrigger2USD);
   Print("  V7.6C: Storm Filter ATR/spread (nunca bloquea recovery)");
   Print("  RescueAllTrades: ", Inp_RescueAllTrades ? "ACTIVO" : "INACTIVO");
   Print("  GMT User:", Inp_UserGMT, "  Broker:", Inp_BrokerGMT,
         "  Ventana:", Inp_StartTime, "-", Inp_EndTime);
   Print("=============================================================");

   m_trade.SetExpertMagicNumber(Inp_Magic);
   m_trade.SetDeviationInPoints(25);
   m_trade.SetAsyncMode(false);
   m_trade.SetTypeFilling(DetectFillingMode());

   h_ATR     = iATR(_Symbol,  PERIOD_M1, Inp_ATRPeriod);
   h_EMAFast = iMA(_Symbol,   PERIOD_M1, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_EMASlow = iMA(_Symbol,   PERIOD_M1, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_RSI     = iRSI(_Symbol,  PERIOD_M1, Inp_RSIPeriod, PRICE_CLOSE);
   h_MACD    = iMACD(_Symbol, PERIOD_M1, Inp_MACDFast, Inp_MACDSlow, Inp_MACDSig, PRICE_CLOSE);

   if(h_ATR == INVALID_HANDLE || h_EMAFast == INVALID_HANDLE ||
      h_EMASlow == INVALID_HANDLE || h_RSI == INVALID_HANDLE ||
      h_MACD == INVALID_HANDLE) {
      Print("[AQ V7.7] ERROR: Indicadores base no iniciados correctamente");
      return INIT_FAILED;
   }

   h_ADX        = iADX(_Symbol, PERIOD_M1, Inp_ADXPeriod);
   h_HTFEMAFast = iMA(_Symbol, Inp_HTFTF, Inp_EMAFast, 0, MODE_EMA, PRICE_CLOSE);
   h_HTFEMASlow = iMA(_Symbol, Inp_HTFTF, Inp_EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   h_EMA200     = iMA(_Symbol, PERIOD_M1, Inp_EMA200Period, 0, MODE_EMA, PRICE_CLOSE);
   h_ATRSlow    = iATR(_Symbol, PERIOD_M1, Inp_ATRSlowPeriod);

   if(h_EMA200 == INVALID_HANDLE)
      Print("[AQ V7.7] AVISO: EMA200 no pudo crearse. Sensor 3 desactivado.");
   if(h_ATRSlow == INVALID_HANDLE)
      Print("[AQ V7.7] AVISO: ATR lento no pudo crearse. Sensor 4 desactivado.");

   for(int i = 0; i < MAX_RECORDS; i++) ZeroMemory(m_rec[i]);
   ZeroMemory(m_lbc);
   ZeroMemory(m_sensors);
   ZeroMemory(m_mkt);
   // *** V7.7 [TEMA+KALMAN]: Inicializar el estado del motor de tendencia ***
   ZeroMemory(m_tk);
   m_tk.initialized = false;
   m_pphHedgeTicket = 0;
   m_pphActive      = false;

   m_initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   m_bestEquity     = AccountInfoDouble(ACCOUNT_EQUITY);
   m_dailyBalance   = m_initialBalance;
   m_lastDailyReset = TimeCurrent();

   CalcBrokerTimeWindow();
   Print("[AQ V7.7] Ventana broker: ",
         m_sensors.brokerStartMin / 60, ":", m_sensors.brokerStartMin % 60, " - ",
         m_sensors.brokerEndMin   / 60, ":", m_sensors.brokerEndMin   % 60);

   SyncPositions();
   UpdatePortfolio();

   if(m_port.lbcCount > 0) {
      m_lbc.active        = true;
      m_lbc.activatedTime = TimeCurrent();
      m_lbc.maxOrdersCalc = Inp_LBCMaxPairs;
      Print("[AQ V7.7] LBC: detectadas ", m_port.lbcCount, " posiciones LBC existentes");
   }

   if(m_port.rescueCount > 0)
      Print("[AQ V7.7] RESCATE: detectadas ", m_port.rescueCount, " posiciones externas en ", _Symbol);

   if(Inp_ShowDashboard) { DeleteDash(); UpdateDash(); }

   Print("[AQ V7.7] LISTO | Saldo=$", m_initialBalance,
         " | MargPor0.01=$", NormalizeDouble(CalcMarginFor001(),2),
         " | MaxDinPos=", CalcDynamicMaxPositions(),
         " | TEMA Periodo=", Inp_TEMAPeriod,
         " | PPH Umbral=$", Inp_PPHThreshold,
         " | Spread: ", Inp_MinSpread, "-", Inp_MaxSpread, " pts");
   return INIT_SUCCEEDED;
}

//=================================================================
//  OnDeinit
//=================================================================
void OnDeinit(const int reason)
{
   Print("[AQ V7.7] DETENIDO | PnL=$", NormalizeDouble(m_totalPnL,2),
         " | Abiertas:", m_tradesOpened,
         " | Cerradas:", m_tradesClosed,
         " | Win%:", NormalizeDouble((m_totalWins+m_totalLosses > 0) ?
            (double)m_totalWins/(m_totalWins+m_totalLosses)*100 : 0, 1),
         " | LBC cosechado:$", NormalizeDouble(m_lbc.harvestedTotal,2));

   IndicatorRelease(h_ATR);
   IndicatorRelease(h_EMAFast);
   IndicatorRelease(h_EMASlow);
   IndicatorRelease(h_RSI);
   IndicatorRelease(h_MACD);
   if(h_ADX        != INVALID_HANDLE) IndicatorRelease(h_ADX);
   if(h_HTFEMAFast != INVALID_HANDLE) IndicatorRelease(h_HTFEMAFast);
   if(h_HTFEMASlow != INVALID_HANDLE) IndicatorRelease(h_HTFEMASlow);
   if(h_EMA200     != INVALID_HANDLE) IndicatorRelease(h_EMA200);
   if(h_ATRSlow    != INVALID_HANDLE) IndicatorRelease(h_ATRSlow);

   if(Inp_ShowDashboard) DeleteDash();
}

//=================================================================
//  OnTick — Flujo principal V7.7
//=================================================================
void OnTick()
{
   m_tickCount++;
   UpdateMarket();    // Actualiza mercado + TEMA-Kalman tick a tick
   UpdateKalman();    // Suaviza PnL de posiciones propias
   UpdatePortfolio(); // Estado del bloque (propias + rescatadas)

   // PRIORIDAD 0: NET EXPOSURE HEDGE — cobertura proporcional graduada
   RunNetExposureHedge();

   CheckEquityGuard();
   m_inSession = IsInMainSession();
   ResetDailyIfNeeded();
   bool dailyPaused = DailyLimitReached();

   UpdateSensors();

   // V7.6C: Filtro de tormenta de volatilidad
   RunVolatilityStormFilter();

   // *** V7.7 [PRIMARY POSITION HEDGE]: Ejecutar ANTES del recovery ***
   // Protege la posicion primaria si su perdida supera el umbral
   if(!m_isPaused && !m_isProcessing)
      RunPrimaryPositionHedge();

   // Pausa de ciclo
   if(m_cycleInPause) {
      if(TimeCurrent() - m_cycleResetTime >= Inp_CyclePauseSec) {
         m_cycleInPause       = false;
         m_recoveryActive     = false;
         m_recoveryOrders     = 0;
         m_recoveryTrendHedge = false;
         DeactivateLBC();
      } else {
         UpdatePortfolio();
         if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget)
            CloseBlockIfPositive("CyclePause_TP");
         if(Inp_ShowDashboard) UpdateDash();
         return;
      }
   }

   // Modo emergencia (fix V7.3F: recovery sigue activo)
   if(m_emergencyMode) {
      static datetime emgTime = 0;
      UpdatePortfolio();
      if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget) {
         CloseBlockIfPositive("Emergency_TP");
         m_emergencyMode = false; emgTime = 0;
      }
      if(m_port.totalPos == 0 && emgTime == 0) emgTime = TimeCurrent();
      if(emgTime > 0 && TimeCurrent() - emgTime >= Inp_EmergencyCooldown) {
         m_emergencyMode = false; emgTime = 0;
      }
      RunPrimaryPositionHedge(); // PPH opera tambien en emergencia
      RunRecoveryEngine();
      RunLBCEngine();
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   if(TimeCurrent() - m_lastCleanupTime > 5) {
      CleanupRecs(); SyncPositions();
      m_lastCleanupTime = TimeCurrent();
   }

   ManagePositions();

   // PRIORIDAD 1: Cierre del bloque cuando es positivo
   if(m_port.totalPos > 0 && m_port.totalProfit >= Inp_BlockTPTarget) {
      CloseBlockIfPositive("BlockTP");
      if(Inp_ShowDashboard) UpdateDash();
      return;
   }

   // PRIORIDAD 2: Recovery matematico
   RunRecoveryEngine();

   // PRIORIDAD 3: LBC
   RunLBCEngine();

   // PRIORIDAD 4: Basket TP
   RunBasketTP();

   // PRIORIDAD 5: Cycle max loss
   CheckCycleMaxLoss();

   // PRIORIDAD 6: Harvest
   RunHarvest();

   // PRIORIDAD 7: CT Engine
   if(!m_isPaused && !m_recoveryActive && !m_lbc.active && !dailyPaused)
      RunCTEngine();

   if(Inp_ShowDashboard) UpdateDash();
}

//=================================================================
//  OnChartEvent — Botones del dashboard
//=================================================================
void OnChartEvent(const int id, const long &lp, const double &dp, const string &sp)
{
   if(id == CHARTEVENT_OBJECT_CLICK) {
      if(sp == "AQ75_B1") {
         m_isPaused = !m_isPaused;
         if(!m_isPaused) {
            m_emergencyMode      = false;
            m_dailyLimitHit      = false;
            m_recoveryActive     = false;
            m_recoveryOrders     = 0;
            m_recoveryTrendHedge = false;
            m_netHedge1Applied   = false;
            m_netHedge2Applied   = false;
            m_pphHedgeTicket     = 0; // *** V7.7 ***
            m_pphActive          = false;
            DeactivateLBC();
            Print("[AQ V7.7] SISTEMA REANUDADO (propias + rescate + PPH reset)");
         } else {
            Print("[AQ V7.7] SISTEMA PAUSADO (recovery/LBC/PPH/rescue siguen si hay posiciones)");
         }
      }

      if(sp == "AQ75_B2") {
         Print("[AQ V7.7] CIERRE MANUAL solicitado...");
         int closed = 0;

         for(int i = PositionsTotal() - 1; i >= 0; i--) {
            ulong t = PositionGetTicket(i);
            if(!PositionSelectByTicket(t)) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != Inp_Magic) continue;
            if(ClosePos(t, "Manual")) closed++;
         }

         if(Inp_RescueAllTrades) {
            for(int i = PositionsTotal() - 1; i >= 0; i--) {
               ulong t = PositionGetTicket(i);
               if(!PositionSelectByTicket(t)) continue;
               if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
               if(PositionGetInteger(POSITION_MAGIC) == Inp_Magic) continue;
               if(CloseRescuePos(t, "Manual_Rescue")) closed++;
            }
         }

         m_lastCTBuyPrice    = m_lastCTSellPrice = 0;
         m_consecutiveLosses = 0;
         m_lotMultiplier     = 1.0;
         m_cycleInPause      = false;
         m_recoveryActive    = false;
         m_recoveryOrders    = 0;
         m_lastPrimaryDir    = 0;
         m_lastPrimaryLost   = false;
         m_netHedge1Applied  = false;
         m_netHedge2Applied  = false;
         m_pphHedgeTicket    = 0; // *** V7.7 ***
         m_pphActive         = false;
         DeactivateLBC();
         Print("[AQ V7.7] CIERRE MANUAL completo: ", closed, " posiciones cerradas");
      }

      // Compatibilidad hacia atras: botones V7.3
      if(sp == "D73_B1") { m_isPaused = !m_isPaused; Print("[AQ V7.7] Boton V7.3 redirigido"); }

      ChartRedraw(0);
   }
}
//+------------------------------------------------------------------+