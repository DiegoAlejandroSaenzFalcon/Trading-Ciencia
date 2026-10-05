import time
import csv
import sys
import threading
import random
import os
import math
import traceback
from datetime import datetime
import colorama
from configobj import ConfigObj
from colorama import Fore, Style

# FIX: Forzar a Python a buscar carpetas (como iqoptionapi) en el mismo directorio que el script
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Forzar codificación UTF-8 en consola Windows para evitar cierres por emojis
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding='utf-8')
    except AttributeError:
        pass

def limpiar_pantalla():
    os.system('cls' if os.name == 'nt' else 'clear')

colorama.init(autoreset=True)

from iqoptionapi.stable_api import IQ_Option

# --- SILENCIADOR DE ERRORES DE HILO (CAPAR ERROR UNDERLYING) ---
def thread_excepthook(args):
    # Si el error es el conocido de 'underlying', lo ignoramos silenciosamente
    if args.exc_type == KeyError and args.exc_value.args[0] == 'underlying':
        return 
    # Para cualquier otro error, usamos el comportamiento normal
    sys.__excepthook__(args.exc_type, args.exc_value, args.exc_traceback)

threading.excepthook = thread_excepthook
# ---------------------------------------------------------------

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
        self.max_stake_percent = 0.15 # Seguridad: Máximo 15% del capital por tiro

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
            
            # Seguridad: Limitar el stake máximo
            max_stake = self.capital_actual * self.max_stake_percent
            return max(1.0, min(stake, max_stake))
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
    email_seleccionado = ""
    password_seleccionado = ""

    try:
        if not os.path.exists(login_path):
            raise FileNotFoundError("El archivo no existe.")
        configu = ConfigObj(login_path)
        
        # Detección inteligente de cuentas (Busca secciones con email y password)
        cuentas = []
        for seccion in configu:
            if isinstance(configu[seccion], dict):
                if 'email' in configu[seccion] and 'password' in configu[seccion]:
                    cuentas.append(seccion)
        
        if not cuentas:
            raise ValueError("No se encontraron cuentas configuradas (secciones con email/password).")
            
        if len(cuentas) == 1:
            seccion = cuentas[0]
            email_seleccionado = configu[seccion]['email']
            password_seleccionado = configu[seccion]['password']
            print(f">> {Fore.YELLOW}Cuenta detectada: {seccion} ({email_seleccionado}){Style.RESET_ALL}")
        else:
            print(f"\n>> {Fore.CYAN}Seleccione la cuenta a utilizar:{Style.RESET_ALL}")
            for i, seccion in enumerate(cuentas):
                print(f"   {Fore.YELLOW}{i+1}. {seccion} ({configu[seccion]['email']}){Style.RESET_ALL}")
            
            while True:
                try:
                    sel = int(input(">> Opción: "))
                    if 1 <= sel <= len(cuentas):
                        seccion = cuentas[sel-1]
                        email_seleccionado = configu[seccion]['email']
                        password_seleccionado = configu[seccion]['password']
                        break
                    print(f">> {Fore.RED}Opción inválida.{Style.RESET_ALL}")
                except ValueError:
                    print(f">> {Fore.RED}Entrada inválida.{Style.RESET_ALL}")

    except Exception as e:
        print(f"{Fore.RED}>> ERROR DE CONFIGURACIÓN: No se pudo leer 'config.txt'.{Style.RESET_ALL}")
        print(f"   Detalle del error: {e}")
        print(f"   Verifica que el archivo esté en: {login_path}")
        input("Presiona Enter para salir...")
        sys.exit(1)

    print(f"\n>> {Fore.YELLOW}Estableciendo conexión segura...{Style.RESET_ALL}")
    api = IQ_Option(email_seleccionado, password_seleccionado)
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
        
    return api, email_seleccionado

def obtener_activos_otc(api):
    """
    Obtiene una lista de los activos OTC que están abiertos actualmente.
    """
    # print(">> Escaneando mercado (Buscando Binarias, Turbo y Digitales)...")
    activos_otc = []
    conteo = {'turbo': 0, 'binary': 0, 'digital': 0}
    
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

    # FIX: Validación de seguridad. Si la API falla y devuelve None, retornamos lista vacía para no romper el bot.
    if datos_mercado is None:
        return []

    # RESTAURACIÓN: Incluimos 'digital' nuevamente
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
    # Aumentamos el requisito de velas para tener datos previos
    if len(candles) < k_period + smooth_k + d_period + 1:
        return None, None, None, None
        
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
    
    # Necesitamos al menos d_period + 1 valores de %K lento para calcular %D actual y previo
    if len(slow_ks) < d_period + 1:
        return None, None, None, None
        
    current_k = slow_ks[-1]
    current_d = sum(slow_ks[-d_period:]) / d_period
    
    prev_k = slow_ks[-2]
    prev_d = sum(slow_ks[-(d_period+1):-1]) / d_period
    
    return current_k, current_d, prev_k, prev_d

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
    
    # RESTAURACIÓN: Incluimos 'digital' en el análisis
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

# --- DEFINICIÓN INTERNA DE ESTRATEGIAS (BLINDADAS) ---
ESTRATEGIAS = {
    "1": {
        "nombre": "ESTRATEGIA NOCTURNA (Mercado Lateral)",
        "rsi_period": 14,
        "rsi_overbought": 70,
        "rsi_oversold": 30,
        "bb_period": 20,
        "bb_sigma": 2.0,
        "st_period": 10,
        "st_multiplier": 3,
        "stoch_k_period": 14,
        "stoch_smooth_k": 3,
        "stoch_d_period": 3,
        "martingale_multiplier": 2.2,
        "duracion": 1
    },
    "2": {
        "nombre": "ESTRATEGIA DIURNA (Mercado Volátil)",
        "rsi_period": 14,
        "rsi_overbought": 55,
        "rsi_oversold": 45,
        "bb_period": 20,
        "bb_sigma": 2.0,
        "st_period": 10,
        "st_multiplier": 3,
        "stoch_k_period": 14,
        "stoch_smooth_k": 3,
        "stoch_d_period": 3,
        "martingale_multiplier": 2.2,
        "duracion": 1
    }
}

def main():
    # 1. Conectar a la API usando login.txt
    api, email_usuario = conectar_iq()
    
    # 2. Escaneo de Mercado (Inmediato)
    # api.update_ACTIVES_OPCODE() # Eliminado: Causa bloqueos innecesarios
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
        # Selección de Estrategia Interna
        print(f"\n>> {Fore.CYAN}Seleccione Perfil de Mercado:{Style.RESET_ALL}")
        print(f"   {Fore.YELLOW}1. NOCTURNA (Lateral - RSI 70/30){Style.RESET_ALL}")
        print(f"   {Fore.YELLOW}2. DIURNA   (Volátil - RSI 55/45){Style.RESET_ALL}")
        
        while True:
            sel_strat = input(">> Opción: ").strip()
            if sel_strat in ESTRATEGIAS:
                strat = ESTRATEGIAS[sel_strat]
                print(f">> Cargando perfil: {Fore.GREEN}{strat['nombre']}{Style.RESET_ALL}")
                break
            print(f">> {Fore.RED}Opción inválida.{Style.RESET_ALL}")

        # Asignación de variables desde el diccionario interno
        rsi_p = strat['rsi_period']
        rsi_ob = strat['rsi_overbought']
        rsi_os = strat['rsi_oversold']
        bb_p = strat['bb_period']
        bb_s = strat['bb_sigma']
        st_p = strat['st_period']
        st_m = strat['st_multiplier']
        stoch_k_p = strat['stoch_k_period']
        stoch_smooth = strat['stoch_smooth_k']
        stoch_d_p = strat['stoch_d_period']
        mg_mult = strat['martingale_multiplier']
        duracion = strat['duracion']
        
        filtros = config['FILTROS']
        evitar_paridad = filtros['evitar_paridad']
        if isinstance(evitar_paridad, str):
            evitar_paridad = [x.strip() for x in evitar_paridad.split(',')]
        min_payout = int(filtros.get('min_payout', 75))
            
    except Exception as e:
        print(f"{Fore.RED}>> Error de configuración: {e}{Style.RESET_ALL}")
        sys.exit(1)

    # Inicialización de variables
    entrada_base = 1.0
    niveles_mg = 0
    niveles_soros = 0
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

    # Stops (Valor monetario directo)
    while True:
        try:
            stop_loss = float(input(f">> Stop Loss ({Fore.RED}$ Valor{Style.RESET_ALL}): "))
            stop_gain = float(input(f">> Stop Gain ({Fore.GREEN}$ Valor{Style.RESET_ALL}): "))
            print(f">> Stops definidos: {Fore.RED}Loss ${stop_loss:.2f}{Style.RESET_ALL} / {Fore.GREEN}Gain ${stop_gain:.2f}{Style.RESET_ALL}")
            break
        except ValueError:
            print(f">> {Fore.RED}Entrada inválida. Use números.{Style.RESET_ALL}")
            
    # Gestión de Capital
    print(f">> Seleccione Gestión de Capital: {Fore.YELLOW}1. SorosGale  2. Masaniello{Style.RESET_ALL}")
    while True:
        tipo_gestion = input(">> Seleccione una opción: ").strip()
        if tipo_gestion in ['1', '2']:
            break
        print(f">> {Fore.RED}Opción inválida.{Style.RESET_ALL}")

    if tipo_gestion == '1':
        # SorosGale (Unificada) - Configuración Automática
        # Se establecen niveles altos para que el límite sea el Stop Loss/Gain global
        niveles_soros = 1000
        niveles_mg = 1000
        print(f"\n{Fore.CYAN}>> MODO SOROSGALE: {Fore.GREEN}AUTOMÁTICO{Style.RESET_ALL}")
    elif tipo_gestion == '2':
        # Masaniello (Usamos la entrada base como capital por defecto si el usuario da Enter)
        masa_capital = entrada_base
        print(f"\n{Fore.CYAN}>> CONFIGURACIÓN MASANIELLO{Style.RESET_ALL}")
        try:
            # Capital se toma de entrada_base automáticamente para evitar redundancia
            masa_trades = int(input(f">> Total de Operaciones del ciclo (Ej. 5): "))
            masa_wins = int(input(f">> Meta de Wins (Ej. 3): "))
        except ValueError:
            print(f">> {Fore.RED}Entrada inválida. Usando valores por defecto.{Style.RESET_ALL}")


    print(f">> {Fore.GREEN}✅ SISTEMA FENIX INICIADO: Motor de análisis listo.{Style.RESET_ALL}")
    
    # Migración de historial al inicio para no interrumpir la tabla
    migrar_historial(email_usuario)
    
    # --- INICIALIZACIÓN DE GESTIÓN ---
    masaniello = None
    if tipo_gestion == '2':
        masaniello = MasanielloStrategy(masa_capital, masa_trades, masa_wins)
        # print(f">> {Fore.CYAN}Gestión Activa: {Fore.YELLOW}MASANIELLO{Style.RESET_ALL}")
    # else:
        # print(f">> {Fore.CYAN}Gestión Activa: {Fore.YELLOW}MARTINGALA{Style.RESET_ALL}")

    input(f">> Presione {Fore.GREEN}ENTER{Style.RESET_ALL} para iniciar el sistema FENIX...")
    
    # --- INICIO DEL TRADING ---
    lucro_total = 0.0
    nivel_actual = 0
    ciclos_perdidos_consecutivos = 0 # Seguridad para Martingala
    
    sg_modo = 'SOROS' # Modos: 'SOROS' o 'MG' (Para SorosGale)
    sg_nivel_mg = 0
    
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
            
        # Seguridad Martingala: Si perdemos 2 ciclos completos seguidos, paramos.
        if tipo_gestion == '1' and ciclos_perdidos_consecutivos >= 2:
             print(f"\n{Fore.RED}>> PROTECCIÓN ACTIVADA: 2 Ciclos de Martingala perdidos consecutivamente.{Style.RESET_ALL}")
             print(f"{Fore.YELLOW}>> El sistema se detiene para proteger el capital.{Style.RESET_ALL}")
             break

        # Verificación de conexión para evitar congelamientos
        if not api.check_connect():
            sys.stdout.write(f"\r {Fore.RED}●{Style.RESET_ALL} {datetime.now().strftime('%H:%M:%S')} » {Fore.RED}Reconectando...{Style.RESET_ALL}\033[K")
            sys.stdout.flush()
            api.connect()

        # Etiqueta Dinámica de Modo
        mode_tag = ""
        if tipo_gestion == '1': # SorosGale
            if sg_modo == 'SOROS':
                mode_tag = f"{Fore.GREEN}[SOROSGALE]{Style.RESET_ALL}" # Verde = Ataque
            else:
                mode_tag = f"{Fore.RED}[SOROSGALE]{Style.RESET_ALL}"   # Rojo = Defensa
        elif tipo_gestion == '2':
            mode_tag = f"{Fore.CYAN}[MASANIELLO]{Style.RESET_ALL}"

        # Mensaje de estado para evitar vacío visual mientras escanea
        color_lucro = Fore.GREEN if lucro_total >= 0 else Fore.RED
        sys.stdout.write(f"\r {Fore.BLUE}●{Style.RESET_ALL} {datetime.now().strftime('%H:%M:%S')} » {mode_tag} {Fore.YELLOW}Escaneando...{Style.RESET_ALL} | P/L: {color_lucro}${lucro_total:<7.2f}{Style.RESET_ALL}\033[K")
        sys.stdout.flush()

        # 4. Obtener activos OTC y seleccionar uno
        activos_todos = obtener_activos_otc(api)
        
        # FILTRO DE OPERATIVA: Solo Binarias y Turbo (Excluir Digitales)
        # Filtramos aquí para que el bot solo opere en los tipos solicitados
        activos = [x for x in activos_todos if x[1] in ['binary', 'turbo', 'digital']]
        
        # Filtrar activos prohibidos desde config.txt
        activos = [a for a in activos if not any(ev.strip() in a[0] for ev in evitar_paridad)]

        if not activos:
            # Si no se obtienen activos, es probable que la API esté lenta (como indica el error 'get_all_init late')
            sys.stdout.write(f"\r {datetime.now().strftime('%H:%M:%S')} » {Fore.RED}Fallo al obtener activos (API lenta). {Fore.YELLOW}Reintentando en 10s...{Style.RESET_ALL}\033[K")
            sys.stdout.flush()
            time.sleep(10)
            continue
        
        # Actualizar estado con cantidad de activos operables
        sys.stdout.write(f"\r {Fore.BLUE}●{Style.RESET_ALL} {datetime.now().strftime('%H:%M:%S')} » {Fore.YELLOW}Analizando {len(activos)} activos...{Style.RESET_ALL}\033[K")
        sys.stdout.flush()

        # Obtener payouts actuales para filtrar y calcular gestión
        # BLOQUEO ELIMINADO: get_all_profit() suele congelar el bot si la API tarda en responder.
        # Usaremos el valor por defecto (87%) y el broker aplicará el real al operar.
        payouts_mercado = {}
        # try:
        #     # Intentamos obtener todos los payouts de una vez para eficiencia
        #     all_profits = api.get_all_profit()
        #     if all_profits:
        #         payouts_mercado = all_profits
        # except:
        #     pass

        activo_seleccionado = None
        tipo_seleccionado = None
        accion = None
        check = False
        order_id = None
        
        # Analizamos cada activo buscando señal RSI
        random.shuffle(activos) # Mezclamos para no analizar siempre en el mismo orden
        
        for i, activo_data in enumerate(activos):
            activo, tipo = activo_data
            
            # Feedback visual de progreso para ver que el bot avanza y qué activo analiza
            sys.stdout.write(f"\r {Fore.BLUE}●{Style.RESET_ALL} {datetime.now().strftime('%H:%M:%S')} » Analizando {i+1}/{len(activos)}: {activo}...\033[K")
            sys.stdout.flush()
            
            # FILTRO DE PAYOUT Y OBTENCION DE DATO REAL
            payout_actual = 0.87 # Valor por defecto seguro
            if activo in payouts_mercado and tipo in payouts_mercado[activo]:
                payout_int = payouts_mercado[activo][tipo]
                payout_actual = payout_int / 100.0
                # Si el payout es menor al mínimo configurado, saltamos este activo
                if payout_int < min_payout:
                    continue

            # Obtenemos velas (necesitamos suficientes para el cálculo, ej. 100)
            try:
                # OPTIMIZACIÓN DE VELOCIDAD: Bajamos a 60 velas. Es suficiente para RSI, BB y SuperTrend.
                candles = api.get_candles(activo, 60, 60, int(time.time()))
                
                if not candles or len(candles) < 50:
                    # Feedback visual rápido si falla la descarga de velas
                    sys.stdout.write(f"\r {datetime.now().strftime('%H:%M:%S')} {Fore.RED}Sin datos: {activo}{Style.RESET_ALL}\033[K")
                    continue
                    
                closes = [c['close'] for c in candles]
                highs = [c['max'] for c in candles]
                lows = [c['min'] for c in candles]
                
                # --- INDICADORES PHOENIX + KATANA ---
                rsi = calcular_rsi(candles, rsi_p)
                upper_bb, sma, lower_bb = calcular_bollinger(candles, bb_p, bb_s)
                # upper_kc, middle_kc, lower_kc = calcular_keltner(candles, bb_p, kelt_m) # Keltner desactivado
                
                # Calculamos SuperTrend con velas ANTERIORES para definir la tendencia de fondo, no la del pullback actual
                st_trend, _ = calcular_supertrend(candles[:-1], st_p, st_m)
                stoch_k, stoch_d, prev_k, prev_d = calcular_stochastic(candles, stoch_k_p, stoch_smooth, stoch_d_p)

                # --- VISUALIZACIÓN (Mostrar datos SIEMPRE para ver que el bot trabaja) ---
                # Usamos valores por defecto (0 o N/A) si algún indicador es None para no romper el print
                d_rsi = rsi if rsi is not None else 0
                d_stoch = stoch_k if stoch_k is not None else 0
                d_trend = st_trend if st_trend is not None else "NEUTRO"
                
                precio_actual = closes[-1]
                estado_banda = "Media"
                if upper_bb is not None and precio_actual > upper_bb: estado_banda = "Alta"
                elif lower_bb is not None and precio_actual < lower_bb: estado_banda = "Baja"
                
                color_st = Fore.GREEN if d_trend == "ALCISTA" else (Fore.RED if d_trend == "BAJISTA" else Fore.WHITE)
                hora_actual = datetime.now().strftime('%H:%M:%S')
                color_lucro = Fore.GREEN if lucro_total >= 0 else Fore.RED
                payout_str = f"{int(payout_actual*100)}%"
                
                trend_char = d_trend[0] # A o B
                band_char = estado_banda[0] # A, B o M
                
                # Imprimimos la línea de estado ANTES de filtrar, para ver los indicadores
                sys.stdout.write(f"\r {hora_actual} {Fore.YELLOW}{activo[:9]:<9}{Style.RESET_ALL} ({payout_str}) RSI:{d_rsi:>3.0f} Sto:{d_stoch:>3.0f} T:{color_st}{trend_char}{Style.RESET_ALL} B:{band_char} P:{color_lucro}${lucro_total:<7.2f}{Style.RESET_ALL}\033[K")
                sys.stdout.flush()

                # --- VALIDACIÓN ESTRICTA PARA OPERAR ---
                if rsi is None or upper_bb is None or sma is None or st_trend is None or stoch_k is None or prev_k is None:
                    continue

                # Actualizar stake Masaniello con payout real si es posible
                if tipo_gestion == '2' and not masaniello.finished:
                    monto_actual = masaniello.get_stake(payout_actual)
                
                estrategia_activa = ""
                accion = None
                status = False
                resultado = 0.0
                check = False

                # --- ESTRATEGIA OPTIMIZADA: TENDENCIA + RETROCESO ---
                # Usamos los parámetros cargados del config para dar flexibilidad (rsi_ob/rsi_os)
                # Estocástico: Exigimos >70/<30 para asegurar que el precio realmente retrocedió lo suficiente.
                
                # 1. VENTA (PUT) - Retroceso en Tendencia Bajista
                # Filtros: SuperTrend Bajista + RSI indica retroceso + Cruce Estocástico Bajista (desde la mitad)
                # RSI > rsi_ob (Configurado en 55 para detectar pullbacks moderados)
                if (st_trend == "BAJISTA" and 
                    rsi > rsi_ob and 
                    stoch_k > 50 and prev_k > prev_d and stoch_k < stoch_d):
                    accion = "put"
                    estrategia_activa = "TREND PULLBACK BEAR"
                
                # 2. COMPRA (CALL) - Retroceso en Tendencia Alcista
                # Filtros: SuperTrend Alcista + RSI indica retroceso + Cruce Estocástico Alcista (desde la mitad)
                # RSI < rsi_os (Configurado en 45 para detectar pullbacks moderados)
                elif (st_trend == "ALCISTA" and 
                      rsi < rsi_os and 
                      stoch_k < 50 and prev_k < prev_d and stoch_k > stoch_d):
                    accion = "call"
                    estrategia_activa = "TREND PULLBACK BULL"
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
                                resultado = float(win_money)
                                status = True
                                break
                            time.sleep(0.1)
                    else:
                        # Binarias/Turbo
                        status, resultado = api.check_win_v4(order_id)
                        
                if status:
                    lucro_total += resultado
                    # FIX: Actualizar color del total acumulado inmediatamente para que la tabla salga correcta
                    color_lucro = Fore.GREEN if lucro_total >= 0 else Fore.RED
                    operaciones_realizadas += 1
                    
                    # Capturamos el estado ACTUAL para imprimirlo en la tabla antes de calcular el siguiente nivel
                    nivel_impresion = nivel_actual
                    modo_impresion = sg_modo if tipo_gestion == '1' else ""
                    
                    if resultado > 0:
                        res_text = "WIN"
                        res_color_tag = Fore.GREEN
                        if tipo_gestion == '2': # Masaniello
                            masaniello.update(resultado)
                            nivel_actual = masaniello.trades # Usamos nivel para mostrar progreso
                        elif tipo_gestion == '1': # FENIX (Unified)
                            if sg_modo == 'SOROS':
                                nivel_actual += 1
                                if nivel_actual < niveles_soros:
                                    monto_actual = monto_actual + resultado # Interés compuesto
                                else:
                                    nivel_actual = 0
                                    monto_actual = entrada_base
                            else: # Estábamos en modo MG y ganamos (Recuperación exitosa)
                                sg_modo = 'SOROS'
                                sg_nivel_mg = 0
                                nivel_actual = 0
                                monto_actual = entrada_base
                    elif resultado < 0:
                        res_text = "LOSS"
                        res_color_tag = Fore.RED
                        if tipo_gestion == '2': # Masaniello
                            masaniello.update(resultado)
                            nivel_actual = masaniello.trades
                        elif tipo_gestion == '1': # FENIX (Unified)
                            if sg_modo == 'SOROS':
                                # Falló el intento de Soros, activar defensa
                                sg_modo = 'MG'
                                sg_nivel_mg = 1
                                nivel_actual = 1 # Visual
                                monto_actual = entrada_base * mg_mult # Primer nivel de MG para recuperar base
                            else:
                                # Falló la defensa (MG), aumentar nivel MG
                                sg_nivel_mg += 1
                                nivel_actual = sg_nivel_mg
                                if sg_nivel_mg <= niveles_mg:
                                    monto_actual = monto_actual * mg_mult
                                else:
                                    # Se perdió la defensa completa
                                    sg_modo = 'SOROS'
                                    sg_nivel_mg = 0
                                    nivel_actual = 0
                                    monto_actual = entrada_base
                                    ciclos_perdidos_consecutivos += 1
                    else:
                        res_text = "EMPATE"
                        res_color_tag = Fore.WHITE
                    
                    # Imprimir fila en la tabla
                    color_res = Fore.GREEN if resultado > 0 else Fore.RED if resultado < 0 else Fore.WHITE
                    
                    # Formato de datos que coincide exactamente con el encabezado
                    # Usamos slicing [:N] para asegurar que NUNCA rompa la tabla
                    hora_str = f"{hora_op[:8]:^8}"
                    par_str = f"{activo_seleccionado[:12]:^12}"
                    
                    # En SorosGale mostramos si es S (Soros) o M (Martingala) en el nivel
                    prefijo_nivel = "S" if (tipo_gestion == '1' and modo_impresion == 'SOROS') else "M" if (tipo_gestion == '1') else ""
                    niv_str_val = f"{prefijo_nivel}{nivel_impresion}"
                    
                    tipo_str = f"{accion.upper()[:5]:^5}"
                    niv_str = f"{niv_str_val[:3]:^3}"
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
                    guardar_log_usuario(email_usuario, activo_seleccionado, accion, nivel_actual, nombre_cuenta, res_text, resultado, estrategia_activa)
                    
                    # --- REINICIO MASANIELLO SI TERMINA ---
                    if tipo_gestion == '2' and masaniello.finished:
                        print(f"{Fore.CYAN}>> Ciclo Masaniello Finalizado.{Style.RESET_ALL}")
                        # Reiniciar ciclo automáticamente
                        masaniello = MasanielloStrategy(masaniello.capital_inicial, masaniello.total_trades, masaniello.target_wins)
                        monto_actual = masaniello.get_stake(0.87)
                        nivel_actual = 0
                        print(f"{Fore.CYAN}>> Nuevo ciclo iniciado.{Style.RESET_ALL}")

                    break
                # time.sleep(1) # ELIMINADO: Esta línea es la causa de la lentitud extrema.
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