import time
import csv
import sys
import threading
import random
import os
import math
import traceback
import warnings
import logging
from datetime import datetime
import colorama
from configobj import ConfigObj
from colorama import Fore, Style

# SILENCIADOR DE ADVERTENCIAS (Consola Limpia)
warnings.filterwarnings("ignore")
logging.getLogger("urllib3").setLevel(logging.CRITICAL)
logging.getLogger("websocket").setLevel(logging.CRITICAL)
logging.getLogger("iqoptionapi").setLevel(logging.CRITICAL)

# FIX: Forzar a Python a buscar carpetas (como iqoptionapi) en el mismo directorio que el script
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Forzar codificación UTF-8 en consola Windows para evitar cierres por emojis
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except AttributeError:
        pass

# Configuración de manejo de errores en hilos para silenciar 'KeyError: underlying'
# Este error es un problema conocido de la librería con opciones digitales y no afecta la operativa principal.
def custom_thread_excepthook(args):
    if args.exc_type == KeyError and args.exc_value.args and args.exc_value.args[0] == 'underlying':
        return # Silenciar error específico
    # Llamar al manejador por defecto para otros errores
    sys.__excepthook__(args.exc_type, args.exc_value, args.exc_traceback)

threading.excepthook = custom_thread_excepthook

def limpiar_pantalla():
    os.system('cls' if os.name == 'nt' else 'clear')

from iqoptionapi.stable_api import IQ_Option
colorama.init(autoreset=True)

class MasanielloStrategy:
    def __init__(self, capital, total_trades, target_wins):
        self.capital_inicial = float(capital)
        self.capital_actual = float(capital)
        self.total_trades = int(total_trades)
        self.target_wins = int(target_wins)
        self.wins = 0
        self.losses = 0
        self.trades = 0
        self.finished = False

    def get_stake(self, payout):
        if self.finished: return 0.0
        
        rem_trades = self.total_trades - self.trades
        rem_wins = self.target_wins - self.wins
        
        if rem_wins <= 0:
            self.finished = True
            return 0.0
        if rem_wins > rem_trades:
            self.finished = True
            return 0.0
            
        try:
            comb_total = math.comb(rem_trades, rem_wins)
            comb_win = math.comb(rem_trades - 1, rem_wins - 1)
            if comb_total == 0: return 0.0
            fraction = comb_win / comb_total
            stake = (self.capital_actual * fraction) / payout
            return max(1.0, stake)
        except:
            return 0.0

    def update(self, result):
        self.trades += 1
        self.capital_actual += result
        if result > 0: self.wins += 1
        else: self.losses += 1
        if self.wins >= self.target_wins or self.trades >= self.total_trades:
            self.finished = True

def conectar_iq():
    limpiar_pantalla()
    print(f"{Fore.CYAN}>> ¡Bienvenido a nuestro sistema FENIX!{Style.RESET_ALL}")
    print(f"{Fore.CYAN}>> ¡Sistema Automatizado Trading: para el Broker IQ Option!{Style.RESET_ALL}")
    
    # Usamos ruta absoluta para evitar errores si se ejecuta desde otra carpeta
    base_dir = os.path.dirname(os.path.abspath(__file__))
    login_path = os.path.join(base_dir, 'config.txt')
    try:
        if not os.path.exists(login_path):
            raise FileNotFoundError("El archivo no existe.")
        configu = ConfigObj(login_path)
        email = configu['LOGIN']['email']
        password = configu['LOGIN']['password']
    except Exception as e:
        print(f"{Fore.RED}>> ERROR DE CONFIGURACIÓN: No se pudo leer 'config.txt'.{Style.RESET_ALL}")
        print(f"   Detalle del error: {e}")
        print(f"   Verifica que el archivo esté en: {login_path}")
        input("Presiona Enter para salir...")
        sys.exit(1)

    print(f"\n>> {Fore.YELLOW}Estableciendo conexión segura...{Style.RESET_ALL}")
    api = IQ_Option(email, password)
    check, reason = api.connect()
    
    if check:
        print(f">> {Fore.GREEN}● Conexión Exitosa{Style.RESET_ALL}")
        perfil = api.get_profile_ansyc()
        if perfil:
            nombre = perfil.get('name', 'Trader')
            uid = perfil.get('id', 'N/A')
            
            # Ajuste de seguridad: Truncar a 30 caracteres para mantener la tabla perfecta
            nombre_str = nombre[:30]
            uid_str = str(uid)[:30]
            
            print(f"{Fore.CYAN}┌{'─'*40}┐{Style.RESET_ALL}")
            print(f"{Fore.CYAN}│ {Fore.WHITE}TRADER: {Fore.YELLOW}{nombre_str:<30} {Fore.CYAN}│{Style.RESET_ALL}")
            print(f"{Fore.CYAN}│ {Fore.WHITE}ID:     {Fore.YELLOW}{uid_str:<30} {Fore.CYAN}│{Style.RESET_ALL}")
            print(f"{Fore.CYAN}└{'─'*40}┘{Style.RESET_ALL}")
            
            # Mostrar saldos de ambas cuentas
            saldo_demo = 0.0
            saldo_real = 0.0
            moneda_real = perfil.get('currency', 'USD')
            if 'balances' in perfil:
                for b in perfil['balances']:
                    if b['type'] == 4: saldo_demo = b['amount']
                    elif b['type'] == 1: saldo_real = b['amount']
            
            print(f"   Saldo Cuenta Demo: {Fore.GREEN}${saldo_demo:,.2f}{Style.RESET_ALL}")
            print(f"   Saldo Cuenta Real: {Fore.GREEN}{moneda_real} {saldo_real:,.2f}{Style.RESET_ALL}")
    else:
        print(f">> Error de conexión: {reason}")
        input("Presiona Enter para salir...")
        sys.exit(1)
        
    return api

def obtener_activos_otc(api):
    """
    Obtiene una lista de los activos OTC que están abiertos actualmente.
    """
    # print(">> Escaneando mercado (Buscando Binarias, Turbo y Digitales)...")
    activos_otc = []
    conteo = {'turbo': 0, 'binary': 0, 'digital': 0}
    
    # 1. Intentar detectar Digitales (Exclusivo Librería Bionic)
    if hasattr(api, 'payout_digital'):
        try:
            digitales = api.payout_digital()
            for par, payout in digitales.items():
                # payout_digital devuelve diccionario {par: payout}
                if payout > 0:
                    # Solo contamos las digitales para verificar que la librería funciona.
                    # No las agregamos a la lista de operación todavía porque requieren una orden de compra distinta.
                    conteo['digital'] += 1
        except Exception as e:
            print(f">> Error al escanear digitales: {e}")

    # 2. Obtener Binarias y Turbo (Intentando método optimizado de Bionic)
    metodo_usado = "Estándar"
    datos_mercado = {}
    
    if hasattr(api, 'captura_binarias'):
        try:
            datos_mercado = api.captura_binarias()
            metodo_usado = "Bionic (Optimizado)"
        except:
            datos_mercado = api.get_all_open_time()
    else:
        datos_mercado = api.get_all_open_time()

    for tipo in ['turbo', 'binary', 'digital']:
        if tipo in datos_mercado:
            for par, data in datos_mercado[tipo].items():
                if data['open']:
                    activos_otc.append((par, tipo))
    
    return sorted(list(set(activos_otc)))

def calcular_rsi(candles, period=14):
    """
    Calcula el RSI de una lista de velas.
    Retorna el valor del RSI actual o None si no hay suficientes datos.
    """
    if len(candles) < period + 1:
        return None
        
    closes = [c['close'] for c in candles]
    deltas = [closes[i] - closes[i-1] for i in range(1, len(closes))]
    
    gains = [d if d > 0 else 0 for d in deltas]
    losses = [-d if d < 0 else 0 for d in deltas]
    
    avg_gain = sum(gains[:period]) / period
    avg_loss = sum(losses[:period]) / period
    
    for i in range(period, len(deltas)):
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period
        
    if avg_loss == 0:
        return 100
    
    rs = avg_gain / avg_loss
    return 100 - (100 / (1 + rs))

def calcular_sma(values, period):
    if len(values) < period:
        return None
    return sum(values[-period:]) / period

def calcular_std_dev(values, period, sma):
    if len(values) < period:
        return None
    variance = sum([((x - sma) ** 2) for x in values[-period:]]) / period
    return variance ** 0.5

def calcular_bollinger(candles, period=20, sigma=2.5):
    closes = [c['close'] for c in candles]
    if len(closes) < period:
        return None, None, None
    
    sma = calcular_sma(closes, period)
    std = calcular_std_dev(closes, period, sma)
    
    upper = sma + (std * sigma)
    lower = sma - (std * sigma)
    return upper, sma, lower

def calcular_ema(values, period):
    if len(values) < period:
        return None
    ema = sum(values[:period]) / period
    multiplier = 2 / (period + 1)
    for value in values[period:]:
        ema = (value - ema) * multiplier + ema
    return ema

def calcular_stochastic(candles, k_period=14, smooth_k=3, d_period=3):
    if len(candles) < k_period + smooth_k + d_period:
        return None, None
        
    highs = [c['max'] for c in candles]
    lows = [c['min'] for c in candles]
    closes = [c['close'] for c in candles]
    
    raw_ks = []
    for i in range(len(candles) - k_period + 1):
        window_highs = highs[i : i+k_period]
        window_lows = lows[i : i+k_period]
        current_close = closes[i + k_period - 1]
        highest = max(window_highs)
        lowest = min(window_lows)
        if highest == lowest:
            k = 100
        else:
            k = ((current_close - lowest) / (highest - lowest)) * 100
        raw_ks.append(k)
        
    slow_ks = [sum(raw_ks[i : i+smooth_k]) / smooth_k for i in range(len(raw_ks) - smooth_k + 1)]
    if not slow_ks: return None, None
    current_k = slow_ks[-1]
    current_d = sum(slow_ks[-d_period:]) / d_period
    return current_k, current_d

def calcular_atr(candles, period=14):
    if len(candles) < period + 1:
        return None
    highs = [c['max'] for c in candles]
    lows = [c['min'] for c in candles]
    closes = [c['close'] for c in candles]
    
    tr_list = []
    for i in range(1, len(candles)):
        h = highs[i]
        l = lows[i]
        cp = closes[i-1]
        tr = max(h-l, abs(h-cp), abs(l-cp))
        tr_list.append(tr)
    
    if len(tr_list) < period: return None
    # SMA del TR para ATR
    return sum(tr_list[-period:]) / period

def calcular_supertrend(candles, period=10, multiplier=3):
    if len(candles) < period + 10: return None, None
    
    highs = [c['max'] for c in candles]
    lows = [c['min'] for c in candles]
    closes = [c['close'] for c in candles]
    
    # Cálculo simplificado de SuperTrend para la última vela
    # Necesitamos iterar para mantener la consistencia de la banda
    atr = calcular_atr(candles, period)
    if atr is None: return None, None
    
    # Usamos una aproximación basada en la última vela para eficiencia en tiempo real
    # En un sistema HFT completo se calcularía recursivamente toda la serie
    hl2 = (highs[-1] + lows[-1]) / 2
    basic_upper = hl2 + (multiplier * atr)
    basic_lower = hl2 - (multiplier * atr)
    
    # Determinamos tendencia basándonos en el cierre respecto a las bandas básicas
    # Nota: Esta es una versión "ligera" del SuperTrend para scalping rápido
    trend = "ALCISTA" if closes[-1] > basic_lower else "BAJISTA"
    
    return trend, (basic_lower if trend == "ALCISTA" else basic_upper)

def calcular_keltner(candles, period=20, mult=1.5):
    closes = [c['close'] for c in candles]
    if len(closes) < period: return None, None, None
    
    ema = calcular_ema(closes, period)
    atr = calcular_atr(candles, 10) # ATR periodo 10 estándar para Keltner
    
    if ema is None or atr is None: return None, None, None
    
    upper = ema + (mult * atr)
    lower = ema - (mult * atr)
    return upper, ema, lower

def analizar_mercado(api, evitar_paridad):
    print(f"{Fore.CYAN}>> Escaneando activos disponibles...{Style.RESET_ALL}")
    try:
        datos = api.get_all_open_time()
    except:
        print(">> Error al obtener datos del mercado.")
        return

    total = 0
    abiertos = 0
    cerrados = 0
    rechazados = 0
    procesados = set()
    
    for tipo in ['turbo', 'binary', 'digital']:
        if tipo in datos:
            for par, info in datos[tipo].items():
                if par in procesados: continue
                procesados.add(par)
                total += 1
                if info['open']: abiertos += 1
                else: cerrados += 1
                if any(f.strip() in par for f in evitar_paridad): rechazados += 1
    
    print(f"{Fore.WHITE}   Total: {total} | {Fore.GREEN}Abiertos: {abiertos} {Fore.WHITE}| {Fore.RED}Cerrados: {cerrados} {Fore.WHITE}| {Fore.YELLOW}Filtrados: {rechazados}{Style.RESET_ALL}")
    print(f"{Fore.CYAN}{'─'*98}{Style.RESET_ALL}")

def migrar_historial(email):
    base_dir = os.path.dirname(os.path.abspath(__file__))
    safe_email = email.replace('@', '_').replace('.', '_')
    ruta_txt = os.path.join(base_dir, f"registro_{safe_email}.txt")
    ruta_csv = os.path.join(base_dir, f"registro_{safe_email}.csv")
    
    if not os.path.exists(ruta_csv) and os.path.exists(ruta_txt):
        try:
            datos_migrados = []
            with open(ruta_txt, 'r', encoding='utf-8') as f_txt:
                for linea in f_txt:
                    if '|' in linea and 'FECHA' not in linea and '=' not in linea:
                        cols = [c.strip() for c in linea.split('|')]
                        if len(cols) == 8:
                            cols.insert(3, "N/A")
                        if len(cols) >= 9:
                            datos_migrados.append(cols[:9])
            
            if datos_migrados:
                with open(ruta_csv, 'w', newline='', encoding='utf-8') as f_csv:
                    writer = csv.writer(f_csv)
                    writer.writerow(['FECHA', 'HORA', 'PARIDAD', 'ESTRATEGIA', 'DIRECCION', 'NIVEL', 'CUENTA', 'RESULTADO', 'LUCRO'])
                    writer.writerows(datos_migrados)
                print(f">> {Fore.GREEN}¡Historial antiguo migrado a Excel (.csv) exitosamente!{Style.RESET_ALL}")
        except Exception as e:
            print(f">> Advertencia: No se pudo migrar el historial antiguo: {e}")

def guardar_log_usuario(email, par, accion, nivel, cuenta, resultado_txt, lucro, estrategia):
    try:
        base_dir = os.path.dirname(os.path.abspath(__file__))
        safe_email = email.replace('@', '_').replace('.', '_')
        ruta_csv = os.path.join(base_dir, f"registro_{safe_email}.csv")
        
        fecha = datetime.now().strftime('%Y-%m-%d')
        hora = datetime.now().strftime('%H:%M:%S')
        res_clean = resultado_txt.replace(Fore.GREEN, '').replace(Fore.RED, '').replace(Fore.WHITE, '').replace(Style.RESET_ALL, '')
        
        existe_csv = os.path.exists(ruta_csv)
        with open(ruta_csv, 'a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            if not existe_csv:
                writer.writerow(['FECHA', 'HORA', 'PARIDAD', 'ESTRATEGIA', 'DIRECCION', 'NIVEL', 'CUENTA', 'RESULTADO', 'LUCRO'])
            
            writer.writerow([fecha, hora, par, estrategia, accion.upper(), nivel, cuenta, res_clean, f"{lucro:.2f}"])
    except Exception as e:
        print(f">> Error guardando log: {e}")

def imprimir_encabezado():
    # Formato Compacto y Seguro (Aprox 75 caracteres de ancho)
    # Se ajusta perfectamente a pantallas pequeñas y evita desbordamientos
    print(f"\n{Fore.CYAN}>> REGISTRO DE OPERACIONES{Style.RESET_ALL}")
    print(f"{Fore.CYAN}┌{'─'*8}┬{'─'*12}┬{'─'*5}┬{'─'*3}┬{'─'*9}┬{'─'*5}┬{'─'*12}┬{'─'*12}┐{Style.RESET_ALL}")
    print(f"{Fore.CYAN}│{Fore.WHITE}{'HORA':^8}{Fore.CYAN}│{Fore.WHITE}{'PAR':^12}{Fore.CYAN}│{Fore.WHITE}{'TIPO':^5}{Fore.CYAN}│{Fore.WHITE}{'NIV':^3}{Fore.CYAN}│{Fore.WHITE}{'CUENTA':^9}{Fore.CYAN}│{Fore.WHITE}{'RES':^5}{Fore.CYAN}│{Fore.WHITE}{'LUCRO':^12}{Fore.CYAN}│{Fore.WHITE}{'TOTAL':^12}{Fore.CYAN}│{Style.RESET_ALL}")
    print(f"{Fore.CYAN}├{'─'*8}┼{'─'*12}┼{'─'*5}┼{'─'*3}┼{'─'*9}┼{'─'*5}┼{'─'*12}┼{'─'*12}┤{Style.RESET_ALL}")

def main():
    # 1. Conectar a la API usando login.txt
    api = conectar_iq()
    
    # 2. Escaneo de Mercado (Inmediato)
    api.update_ACTIVES_OPCODE()
    analizar_mercado(api, []) # Pasamos lista vacía temporalmente, el filtro real se aplica en el bucle
    
    # 3. Selección de Cuenta
    while True:
        print(f">> Indique el tipo de cuenta: {Fore.YELLOW}1. Cuenta Demo  2. Cuenta Real{Style.RESET_ALL}")
        tipo_cuenta = input(">> Seleccione una opción: ").strip()
        if tipo_cuenta == '1':
            api.change_balance("PRACTICE")
            nombre_cuenta = "PRACTICE"
            break
        elif tipo_cuenta == '2':
            api.change_balance("REAL")
            nombre_cuenta = "REAL"
            break
        else:
            print(f">> {Fore.RED}Opción inválida.{Style.RESET_ALL}")

    # Cargar configuración de estrategia y filtros
    base_dir = os.path.dirname(os.path.abspath(__file__))
    config_path = os.path.join(base_dir, 'config.txt')
    config = ConfigObj(config_path)
    
    try:
        strat = config['ESTRATEGIA']
        rsi_p = int(strat['rsi_period'])
        rsi_ob = int(strat['rsi_overbought'])
        rsi_os = int(strat['rsi_oversold'])
        bb_p = int(strat['bb_period'])
        bb_s = float(strat['bb_sigma'])
        
        # Parámetros adicionales (Valores por defecto si no están en config)
        st_p = int(strat.get('st_period', 10))
        st_m = int(strat.get('st_multiplier', 3))
        # kelt_m = float(strat.get('keltner_multiplier', 1.5)) # No usado actualmente
        mg_mult = float(strat.get('martingale_multiplier', 2.3))
        duracion = int(strat.get('duracion', 1)) # Duración en minutos
        
        stoch_k_p = int(strat.get('stoch_k_period', 14))
        stoch_smooth = int(strat.get('stoch_smooth_k', 3))
        stoch_d_p = int(strat.get('stoch_d_period', 3))
        
        filtros = config['FILTROS']
        evitar_paridad = filtros['evitar_paridad']
        if isinstance(evitar_paridad, str):
            evitar_paridad = [x.strip() for x in evitar_paridad.split(',')]
            
    except Exception as e:
        print(f"{Fore.RED}>> Error leyendo parámetros en config.txt: {e}{Style.RESET_ALL}")
        sys.exit(1)

    # Inicialización de variables
    entrada_base = 1.0
    niveles_mg = 0
    masa_capital = 50.0
    masa_trades = 5
    masa_wins = 3
    
    # 4. Configuración Interactiva (Orden Solicitado)
    # Entrada Base
    while True:
        try:
            entrada_base = float(input(f">> Entrada Base ({Fore.YELLOW}$1 - $20000{Style.RESET_ALL}): "))
            if 1 <= entrada_base <= 20000: break
            print(f">> {Fore.RED}Valor fuera de rango.{Style.RESET_ALL}")
        except ValueError:
            print(f">> {Fore.RED}Entrada inválida.{Style.RESET_ALL}")

    # Stops
    while True:
        try:
            stop_loss = float(input(">> Stops: Loss: "))
            stop_gain = float(input(">> Stops: Gain: "))
            break
        except ValueError:
            print(f">> {Fore.RED}Entrada inválida.{Style.RESET_ALL}")
            
    # Pular Vela
    while True:
        pular_input = input(f">> Pular Vela (Esperar {duracion}min tras Loss)? (S/N): ").strip().upper()
        if pular_input in ['S', 'N']:
            usar_pular_vela = (pular_input == 'S')
            break
        print(">> Opción inválida. Use S o N.")
    
    # Gestión de Capital
    print(f">> Seleccione Gestión de Capital: {Fore.YELLOW}1. Martingala  2. Masaniello{Style.RESET_ALL}")
    while True:
        tipo_gestion = input(">> Seleccione una opción: ").strip()
        if tipo_gestion in ['1', '2']:
            break
        print(f">> {Fore.RED}Opción inválida.{Style.RESET_ALL}")

    if tipo_gestion == '1':
        # Martingala
        while True:
            try:
                niveles_mg = int(input(f">> Número de Niveles de Martin Galas ({Fore.YELLOW}0-6{Style.RESET_ALL}): "))
                if 0 <= niveles_mg <= 10: break
                print(f">> {Fore.RED}Valor fuera de rango.{Style.RESET_ALL}")
            except ValueError:
                print(f">> {Fore.RED}Entrada inválida.{Style.RESET_ALL}")
    else:
        # Masaniello (Usamos la entrada base como capital por defecto si el usuario da Enter)
        masa_capital = entrada_base
        print(f"\n{Fore.CYAN}>> CONFIGURACIÓN MASANIELLO{Style.RESET_ALL}")
        try:
            in_cap = input(f">> Capital para el ciclo Masaniello (Enter para ${entrada_base}): ")
            if in_cap.strip(): masa_capital = float(in_cap)
            masa_trades = int(input(f">> Total de Operaciones del ciclo (Ej. 5): "))
            masa_wins = int(input(f">> Meta de Wins (Ej. 3): "))
        except ValueError:
            print(f">> {Fore.RED}Entrada inválida. Usando valores por defecto.{Style.RESET_ALL}")

    print(f">> {Fore.GREEN}✅ SISTEMA FENIX INICIADO: Motor de análisis listo.{Style.RESET_ALL}")
    
    # Migración de historial al inicio para no interrumpir la tabla
    migrar_historial(config['LOGIN']['email'])
    
    # --- INICIALIZACIÓN DE GESTIÓN ---
    masaniello = None
    if tipo_gestion == '2':
        masaniello = MasanielloStrategy(masa_capital, masa_trades, masa_wins)
        # print(f">> {Fore.CYAN}Gestión Activa: {Fore.YELLOW}MASANIELLO{Style.RESET_ALL}")
    # else:
        # print(f">> {Fore.CYAN}Gestión Activa: {Fore.YELLOW}MARTINGALA{Style.RESET_ALL}")

    # Mostrar tabla de Martingala si aplica
    if tipo_gestion == '1':
        print(f"\n{Fore.CYAN}>> PROYECCIÓN DE RIESGO (MARTINGALA x{mg_mult:.2f}){Style.RESET_ALL}")
        print(f"{Fore.CYAN}┌{'─'*10}┬{'─'*15}┬{'─'*15}┐{Style.RESET_ALL}")
        print(f"{Fore.CYAN}│{Fore.WHITE} {'NIVEL':^8} {Fore.CYAN}│{Fore.WHITE} {'INVERSIÓN':^13} {Fore.CYAN}│{Fore.WHITE} {'ACUMULADO':^13} {Fore.CYAN}│{Style.RESET_ALL}")
        print(f"{Fore.CYAN}├{'─'*10}┼{'─'*15}┼{'─'*15}┤{Style.RESET_ALL}")
        acumulado = 0.0
        for i in range(niveles_mg + 1):
            monto_nivel = entrada_base * (mg_mult ** i)
            acumulado += monto_nivel
            nivel_str = "ENTRADA" if i == 0 else f"GALA {i}"
            print(f"{Fore.CYAN}│{Fore.YELLOW} {nivel_str:^8} {Fore.CYAN}│{Fore.GREEN} ${monto_nivel:^12.2f} {Fore.CYAN}│{Fore.RED} ${acumulado:^12.2f} {Fore.CYAN}│{Style.RESET_ALL}")
        print(f"{Fore.CYAN}└{'─'*10}┴{'─'*15}┴{'─'*15}┘{Style.RESET_ALL}\n")
    
    input(f">> Presione {Fore.GREEN}ENTER{Style.RESET_ALL} para iniciar el sistema FENIX...")
    
    # --- INICIO DEL TRADING ---
    lucro_total = 0.0
    nivel_actual = 0
    
    if tipo_gestion == '2':
        # Primer stake de Masaniello (asumiendo payout 87% para estimación inicial)
        monto_actual = masaniello.get_stake(0.87)
    else:
        monto_actual = entrada_base
        
    operaciones_realizadas = 0
    
    imprimir_encabezado()
    
    # Mensaje inicial inmediato para evitar vacío visual
    sys.stdout.write(f"\r {Fore.BLUE}●{Style.RESET_ALL} {datetime.now().strftime('%H:%M:%S')} » {Fore.YELLOW}Iniciando...{Style.RESET_ALL}\033[K")
    sys.stdout.flush()

    while True:
        # Verificación de Stops
        if lucro_total >= stop_gain:
            print(f"\n{Fore.GREEN}>> ¡META ALCANZADA! Stop Gain superado: ${lucro_total:.2f}{Style.RESET_ALL}")
            break
        if lucro_total <= -stop_loss:
            print(f"\n{Fore.RED}>> ¡STOP LOSS ALCANZADO! Pérdida: ${lucro_total:.2f}{Style.RESET_ALL}")
            break

        # Mensaje de estado para evitar vacío visual mientras escanea
        color_lucro = Fore.GREEN if lucro_total >= 0 else Fore.RED
        sys.stdout.write(f"\r {Fore.BLUE}●{Style.RESET_ALL} {datetime.now().strftime('%H:%M:%S')} » {Fore.YELLOW}Escaneando...{Style.RESET_ALL} | P/L: {color_lucro}${lucro_total:<7.2f}{Style.RESET_ALL}\033[K")
        sys.stdout.flush()

        # 4. Obtener activos OTC y seleccionar uno
        activos_todos = obtener_activos_otc(api)
        
        # FILTRO DE OPERATIVA: Solo Binarias y Turbo (Excluir Digitales)
        # Filtramos aquí para que el bot solo opere en los tipos solicitados
        activos = [x for x in activos_todos if x[1] in ['binary', 'turbo']]
        
        # Filtrar activos prohibidos desde config.txt
        activos = [a for a in activos if not any(ev.strip() in a[0] for ev in evitar_paridad)]

        if not activos:
            sys.stdout.write(f"\r {datetime.now().strftime('%H:%M:%S')} » {Fore.YELLOW}Sin activos. Reintentando...{Style.RESET_ALL}\033[K")
            sys.stdout.flush()
            time.sleep(60)
            continue
        
        # Actualizar estado con cantidad de activos operables
        sys.stdout.write(f"\r {Fore.BLUE}●{Style.RESET_ALL} {datetime.now().strftime('%H:%M:%S')} » {Fore.YELLOW}Analizando {len(activos)} activos...{Style.RESET_ALL}\033[K")
        sys.stdout.flush()

        activo_seleccionado = None
        tipo_seleccionado = None
        accion = None
        check = False
        order_id = None
        
        # Analizamos cada activo buscando señal RSI
        random.shuffle(activos) # Mezclamos para no analizar siempre en el mismo orden
        
        for activo_data in activos:
            activo, tipo = activo_data
            # Obtenemos velas (necesitamos suficientes para el cálculo, ej. 100)
            try:
                candles = api.get_candles(activo, 60, 150, int(time.time()))
                closes = [c['close'] for c in candles]
                highs = [c['max'] for c in candles]
                lows = [c['min'] for c in candles]
                
                # --- INDICADORES PHOENIX + KATANA ---
                rsi = calcular_rsi(candles, rsi_p)
                upper_bb, _, lower_bb = calcular_bollinger(candles, bb_p, bb_s)
                # upper_kc, middle_kc, lower_kc = calcular_keltner(candles, bb_p, kelt_m) # Keltner desactivado
                
                # Calculamos SuperTrend con velas ANTERIORES para definir la tendencia de fondo, no la del pullback actual
                st_trend, _ = calcular_supertrend(candles[:-1], st_p, st_m)
                stoch_k, _ = calcular_stochastic(candles, stoch_k_p, stoch_smooth, stoch_d_p)

                if rsi is None or upper_bb is None or st_trend is None or stoch_k is None:
                    continue

                # Actualizar stake Masaniello con payout real si es posible
                if tipo_gestion == '2' and not masaniello.finished:
                    # Recalculamos con 0.87 (promedio seguro) para mantener la progresión matemática
                    monto_actual = masaniello.get_stake(0.87)

                precio_actual = closes[-1]
                
                estado_banda = "Media"
                if precio_actual > upper_bb: estado_banda = "Alta"
                
                color_st = Fore.GREEN if st_trend == "ALCISTA" else Fore.RED
                hora_actual = datetime.now().strftime('%H:%M:%S')
                color_lucro = Fore.GREEN if lucro_total >= 0 else Fore.RED
                
                # MENSAJE COMPACTO (Evita salto de línea en pantallas pequeñas)
                # Ej: 12:00:00 EURUSD RSI:50 Sto:20 T:A B:M P:$10.00
                trend_char = st_trend[0] # A o B
                band_char = estado_banda[0] # A, B o M
                sys.stdout.write(f"\r {hora_actual} {Fore.YELLOW}{activo[:10]:<10}{Style.RESET_ALL} RSI:{rsi:>3.0f} Sto:{stoch_k:>3.0f} T:{color_st}{trend_char}{Style.RESET_ALL} B:{band_char} P:{color_lucro}${lucro_total:<7.2f}{Style.RESET_ALL}\033[K")
                sys.stdout.flush()
                
                estrategia_activa = ""
                accion = None
                status = False
                resultado = 0.0
                check = False

                # --- LÓGICA PHOENIX + KATANA (OPTIMIZADA) ---
                # 1. VENTA (PUT) - Pullback en Tendencia Bajista
                # Tendencia Bajista + Precio (High) toca Banda Superior + RSI Sobrecompra + Stoch Sobrecompra (> 80)
                # Ajuste: Volvemos a valores estrictos para evitar pérdidas en mercados sucios
                if st_trend == "BAJISTA" and highs[-1] >= upper_bb and rsi > rsi_ob and stoch_k > 80:
                    accion = "put"
                    estrategia_activa = "PHOENIX BEAR"
                
                # 2. COMPRA (CALL) - Pullback en Tendencia Alcista
                # Tendencia Alcista + Precio (Low) toca Banda Inferior + RSI Sobrevendido + Stoch Sobrevendido (< 20)
                # Ajuste: Volvemos a valores estrictos para evitar pérdidas en mercados sucios
                elif st_trend == "ALCISTA" and lows[-1] <= lower_bb and rsi < rsi_os and stoch_k < 20:
                    accion = "call"
                    estrategia_activa = "PHOENIX BULL"
                else:
                    continue

                # Si hay señal, intentamos comprar
                try:
                    if tipo == 'digital':
                        check, order_id = api.buy_digital_spot(activo, monto_actual, accion, duracion)
                    else:
                        check, order_id = api.buy(monto_actual, activo, accion, duracion)
                except Exception as e:
                    check = False

                if check:
                    activo_seleccionado = activo
                    tipo_seleccionado = tipo
                    hora_op = datetime.now().strftime('%H:%M:%S')
                    
                    # MENSAJE DE OPERACIÓN COMPACTO
                    sys.stdout.write(f"\r {hora_op} {Fore.YELLOW}► OPERANDO:{Style.RESET_ALL} {activo_seleccionado[:10]} ({accion.upper()}) ${monto_actual:.0f}...\033[K")
                    sys.stdout.flush()
                    
                    status = False
                    resultado = 0.0

                    if tipo_seleccionado == 'digital':
                        while True:
                            check_close, win_money = api.check_win_digital_v2(order_id)
                            if check_close:
                                resultado = win_money
                                status = True
                                break
                            time.sleep(1)
                    else:
                        status, resultado = api.check_win_v4(order_id)
                        
                if status:
                    lucro_total += resultado
                    operaciones_realizadas += 1
                    
                    if resultado > 0:
                        res_text = "WIN"
                        res_color_tag = Fore.GREEN
                        if tipo_gestion == '1': # Martingala
                            nivel_actual = 0
                            monto_actual = entrada_base
                        else: # Masaniello
                            masaniello.update(resultado)
                            nivel_actual = masaniello.trades # Usamos nivel para mostrar progreso
                    elif resultado < 0:
                        res_text = "LOSS"
                        res_color_tag = Fore.RED
                        if tipo_gestion == '1': # Martingala
                            nivel_actual += 1
                            if nivel_actual <= niveles_mg:
                                monto_actual = monto_actual * mg_mult
                            else:
                                nivel_actual = 0
                                monto_actual = entrada_base
                        else: # Masaniello
                            masaniello.update(resultado)
                            nivel_actual = masaniello.trades
                    else:
                        res_text = "EMPATE"
                        res_color_tag = Fore.WHITE
                    
                    # Imprimir fila en la tabla
                    color_res = Fore.GREEN if resultado > 0 else Fore.RED if resultado < 0 else Fore.WHITE
                    
                    # Formato de datos que coincide exactamente con el encabezado
                    # Usamos slicing [:N] para asegurar que NUNCA rompa la tabla
                    hora_str = f"{hora_op[:8]:^8}"
                    par_str = f"{activo_seleccionado[:12]:^12}"
                    tipo_str = f"{accion.upper()[:5]:^5}"
                    niv_str = f"{str(nivel_actual)[:3]:^3}"
                    cta_str = f"{nombre_cuenta[:9]:^9}"
                    res_str = f"{res_text[:5]:^5}"
                    
                    # Formato monetario seguro
                    lucro_fmt = f"${resultado:,.2f}"
                    total_fmt = f"${lucro_total:,.2f}"
                    lucro_str = f"{lucro_fmt[:12]:^12}"
                    total_str = f"{total_fmt[:12]:^12}"

                    log_line = (
                        f"{Fore.CYAN}│{Fore.WHITE}{hora_str}"
                        f"{Fore.CYAN}│{Fore.WHITE}{par_str}"
                        f"{Fore.CYAN}│{Fore.WHITE}{tipo_str}"
                        f"{Fore.CYAN}│{Fore.WHITE}{niv_str}"
                        f"{Fore.CYAN}│{Fore.WHITE}{cta_str}"
                        f"{Fore.CYAN}│{res_color_tag}{res_str}{Style.RESET_ALL}"
                        f"{Fore.CYAN}│{color_res}{lucro_str}{Style.RESET_ALL}"
                        f"{Fore.CYAN}│{color_lucro}{total_str}{Style.RESET_ALL}"
                        f"{Fore.CYAN}│{Style.RESET_ALL}"
                    )

                    # SOLUCIÓN DEFINITIVA: Regresar, limpiar la línea actual y luego imprimir.
                    print(f"\r\033[K{log_line}")
                    guardar_log_usuario(config['LOGIN']['email'], activo_seleccionado, accion, nivel_actual, nombre_cuenta, res_text, resultado, estrategia_activa)
                    
                    # --- LÓGICA PULAR VELA ---
                    if resultado < 0 and usar_pular_vela:
                        print(f"{Fore.YELLOW}>> Pular Vela Activado: Esperando {duracion} minuto(s) por seguridad...{Style.RESET_ALL}")
                        time.sleep(duracion * 60)
                        
                    # --- REINICIO MASANIELLO SI TERMINA ---
                    if tipo_gestion == '2' and masaniello.finished:
                        print(f"{Fore.CYAN}>> Ciclo Masaniello Finalizado.{Style.RESET_ALL}")
                        # Reiniciar ciclo automáticamente
                        masaniello = MasanielloStrategy(masaniello.capital_inicial, masaniello.total_trades, masaniello.target_wins)
                        monto_actual = masaniello.get_stake(0.87)
                        nivel_actual = 0
                        print(f"{Fore.CYAN}>> Nuevo ciclo iniciado.{Style.RESET_ALL}")

                    break
                time.sleep(1)
            except Exception as e:
                continue
        
        # Espera dinámica
        # Esperamos un poco antes de volver a escanear para no saturar, actualizando el reloj
        for _ in range(5): 
             color_lucro = Fore.GREEN if lucro_total >= 0 else Fore.RED
             sys.stdout.write(f"\r {datetime.now().strftime('%H:%M:%S')} » Esperando... | P/L: {color_lucro}${lucro_total:<7.2f}{Style.RESET_ALL}\033[K")
             sys.stdout.flush()
             time.sleep(1)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n{Fore.YELLOW}>> Detenido por el usuario.{Style.RESET_ALL}")
    except Exception as e:
        print(f"\n{Fore.RED}>> ERROR FATAL NO CONTROLADO:{Style.RESET_ALL}")
        traceback.print_exc()
    input(f"\n{Fore.CYAN}Presiona Enter para finalizar...{Style.RESET_ALL}")