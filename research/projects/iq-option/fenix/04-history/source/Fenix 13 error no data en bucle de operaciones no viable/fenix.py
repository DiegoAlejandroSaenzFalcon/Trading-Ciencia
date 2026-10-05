import time
import csv
import sys
import threading
import random
import os
import math
import traceback
import json
import urllib.request
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
    # Usamos el método estándar para asegurar compatibilidad y limpieza total
    os.system('cls' if os.name == 'nt' else 'clear')

colorama.init(autoreset=True)

from iqoptionapi.stable_api import IQ_Option

# --- VARIABLES GLOBALES ---
api_lock = threading.Lock() # Semáforo para evitar choques en la API

# --- CONFIGURACIÓN TELEGRAM (CONTROL REMOTO) ---
# 1. Crea un bot en Telegram con @BotFather y obtén el TOKEN.
# 2. Obtén tu ID de chat con @userinfobot.
TELEGRAM_CHAT_ID = None
TELEGRAM_GROUP_ID = None
telegram_comando = None # Variable de control global

# Cargar configuración de Telegram al iniciar
try:
    base_dir_cfg = os.path.dirname(os.path.abspath(__file__))
    config_tg = ConfigObj(os.path.join(base_dir_cfg, 'config.txt'))
    if 'TELEGRAM' in config_tg:
        TELEGRAM_TOKEN = config_tg['TELEGRAM']['token']
        TELEGRAM_CHAT_ID = config_tg['TELEGRAM']['chat_id']
        if 'group_id' in config_tg['TELEGRAM'] and config_tg['TELEGRAM']['group_id']:
            TELEGRAM_GROUP_ID = config_tg['TELEGRAM']['group_id'].strip()
except: pass

# --- ESTADO GLOBAL DE SESIÓN (PARA TELEGRAM) ---
config_sesion = {
    "running": False,      # Si es True, el bot inicia el trading
    "cuenta": "PRACTICE",  # PRACTICE o REAL
    "entrada": 2000,        # <--- MODIFICAR AQUÍ: Monto de entrada por defecto
    "stop_loss": 6000,     # <--- MODIFICAR AQUÍ: Stop Loss por defecto
    "stop_gain": 1000,      # <--- MODIFICAR AQUÍ: Meta (Stop Win) por defecto
    "gestion": "1",        # 1=SorosGale, 2=Masaniello
    "masa_trades": 5,
    "masa_wins": 3
}
telegram_state = "IDLE"    # Estado del chat (esperando input)

# --- CONFIGURACIÓN DE LICENCIA REMOTA ---
# URL de un archivo de texto RAW (ej. Pastebin, GitHub Gist) que contenga solo la palabra "ACTIVO" o "INACTIVO"
# Para pruebas, puedes crear un Gist público en GitHub con la palabra "ACTIVO" y pegar aquí el enlace "Raw".
LICENSE_URL = "https://gist.githubusercontent.com/diegoalejandrosaenzfalcon-svg/c706651bfea4edc1a685c8b46ef90ea8/raw/licencia.txt" 

def verificar_licencia_remota(email_usuario=None):
    """
    Consulta un archivo remoto para verificar si el usuario tiene permiso.
    Si email_usuario es None, busca todos los emails en config.txt automáticamente.
    """
    if "TU_ENLACE" in LICENSE_URL: return # Modo desarrollo, saltar check
    
    emails_a_verificar = []
    if email_usuario:
        emails_a_verificar.append(email_usuario)
    else:
        # Extraer emails del archivo config.txt automáticamente
        try:
            base_dir = os.path.dirname(os.path.abspath(__file__))
            config_path = os.path.join(base_dir, 'config.txt')
            if os.path.exists(config_path):
                config = ConfigObj(config_path)
                for seccion in config:
                    if isinstance(config[seccion], dict) and 'email' in config[seccion]:
                        emails_a_verificar.append(config[seccion]['email'])
        except:
            pass

    try:
        req = urllib.request.Request(
            LICENSE_URL, 
            headers={'User-Agent': 'Mozilla/5.0'}
        )
        with urllib.request.urlopen(req, timeout=10) as response:
            contenido = response.read().decode('utf-8')
            
        # Verificamos si alguno de los emails está en la lista autorizada
        autorizado = False
        for email in emails_a_verificar:
            if email in contenido:
                autorizado = True
                break
        
        if not autorizado:
            print(f"\n{Fore.RED}>> ACCESO DENEGADO.{Style.RESET_ALL}")
            input("Presiona Enter para salir...")
            sys.exit(1)
        
            
    except Exception as e:
        # En un sistema estricto, si falla la conexión, no debería arrancar.
        print(f"\n{Fore.RED}Error verificando licencia: {e}{Style.RESET_ALL}")
        input("Presiona Enter para salir...")
        sys.exit(1)

def enviar_telegram(mensaje, parse_mode="Markdown", reply_markup=None, chat_id=None):
    """Envía mensajes al bot de Telegram configurado."""
    if not TELEGRAM_TOKEN or "TU_TOKEN" in TELEGRAM_TOKEN: return
    
    dest_id = chat_id if chat_id else TELEGRAM_CHAT_ID
    
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    payload = {"chat_id": dest_id, "text": mensaje, "parse_mode": parse_mode}
    if reply_markup:
        payload["reply_markup"] = reply_markup
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception as e:
        # Imprimir error para depuración si falla el envío
        print(f"\n{Fore.RED}>> Error Telegram: {e}{Style.RESET_ALL}")

def editar_mensaje_telegram(chat_id, message_id, texto, reply_markup=None):
    """Edita un mensaje existente en Telegram para efecto interactivo."""
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/editMessageText"
    payload = {
        "chat_id": chat_id,
        "message_id": message_id,
        "text": texto,
        "parse_mode": "HTML"
    }
    if reply_markup:
        payload["reply_markup"] = reply_markup
        
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception as e:
        print(f"{Fore.RED}>> Error Editar Mensaje: {e}{Style.RESET_ALL}")

def responder_callback(callback_id, texto=None):
    """Responde al servidor de Telegram para detener la animación de carga del botón."""
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/answerCallbackQuery"
    payload = {"callback_query_id": callback_id}
    if texto: payload["text"] = texto
    try:
        req = urllib.request.Request(
            url,
            data=json.dumps(payload).encode('utf-8'),
            headers={'Content-Type': 'application/json'}
        )
        urllib.request.urlopen(req, timeout=5)
    except Exception as e:
        print(f"{Fore.RED}>> Error Responder Callback: {e}{Style.RESET_ALL}")

def mostrar_menu_telegram(chat_id=None, message_id=None):
    """Envía o actualiza el panel de control con botones a Telegram."""
    keyboard = {
        "inline_keyboard": [
            [{"text": f"💳 Cuenta: {config_sesion['cuenta']}", "callback_data": "toggle_account"}],
            [{"text": f"💰 Entrada: ${config_sesion['entrada']}", "callback_data": "set_bet"}],
            [{"text": f"🛑 Stop: ${config_sesion['stop_loss']}", "callback_data": "set_sl"}, {"text": f"🎯 Meta: ${config_sesion['stop_gain']}", "callback_data": "set_tp"}],
            [{"text": f"📊 Gestión: {'SorosGale' if config_sesion['gestion']=='1' else 'Masaniello'}", "callback_data": "toggle_gestion"}],
            [{"text": "🚀 INICIAR SISTEMA", "callback_data": "start_bot"}]
        ]
    }
    texto_menu = "🎛 <b>PANEL DE CONTROL FENIX</b>\nConfigure los parámetros antes de iniciar:"
    
    if message_id and chat_id:
        editar_mensaje_telegram(chat_id, message_id, texto_menu, reply_markup=keyboard)
    else:
        enviar_telegram(texto_menu, parse_mode="HTML", reply_markup=keyboard, chat_id=chat_id)

def escuchar_telegram_background(api):
    """Hilo en segundo plano para recibir comandos de Telegram."""
    global telegram_comando, telegram_state, config_sesion
    if not TELEGRAM_TOKEN or "TU_TOKEN" in TELEGRAM_TOKEN: return
    
    # FIX: Eliminar webhook previo para evitar error 409 
    try:
        urllib.request.urlopen(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/deleteWebhook?drop_pending_updates=True")
    except Exception:
        pass
    
    offset = 0
    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Monitor Telegram: ACTIVO (Esperando comandos...)")
    
    while True:
        try:
            url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/getUpdates?offset={offset}&timeout=10"
            with urllib.request.urlopen(url, timeout=15) as response:
                data = json.loads(response.read().decode('utf-8'))
            
            if data['ok']:
                for result in data['result']:
                    offset = result['update_id'] + 1
                    
                    # --- MANEJO DE BOTONES (CALLBACKS) ---
                    if 'callback_query' in result:
                        cb = result['callback_query']
                        cb_id = cb['id']
                        data_cb = cb['data']
                        chat_id = cb['message']['chat']['id']
                        message_id = cb['message']['message_id']
                        
                        # FILTRO DE SEGURIDAD: Ignorar si no es el dueño
                        if str(chat_id) != str(TELEGRAM_CHAT_ID):
                            print(f" {Fore.YELLOW}[!] Callback ignorado de ID desconocido: {chat_id}{Style.RESET_ALL}")
                            continue
                        
                        print(f"{Fore.YELLOW}>> Telegram Callback: {data_cb}{Style.RESET_ALL}")
                        
                        responder_callback(cb_id)

                        if data_cb == 'toggle_account':
                            config_sesion['cuenta'] = 'REAL' if config_sesion['cuenta'] == 'PRACTICE' else 'PRACTICE'
                            mostrar_menu_telegram(chat_id, message_id)
                        elif data_cb == 'toggle_gestion':
                            config_sesion['gestion'] = '2' if config_sesion['gestion'] == '1' else '1'
                            mostrar_menu_telegram(chat_id, message_id)
                        elif data_cb == 'set_bet':
                            telegram_state = "WAIT_ENTRADA"
                            enviar_telegram("💰 Envíe el monto de <b>ENTRADA BASE</b>:", parse_mode="HTML", chat_id=chat_id)
                        elif data_cb == 'set_sl':
                            telegram_state = "WAIT_SL"
                            enviar_telegram("🛑 Envíe el monto de <b>STOP LOSS</b>:", parse_mode="HTML", chat_id=chat_id)
                        elif data_cb == 'set_tp':
                            telegram_state = "WAIT_TP"
                            enviar_telegram("🎯 Envíe el monto de <b>META (TP)</b>:", parse_mode="HTML", chat_id=chat_id)
                        elif data_cb == 'start_bot':
                            config_sesion['running'] = True
                            enviar_telegram("🚀 <b>INICIANDO SISTEMA...</b>", parse_mode="HTML", chat_id=chat_id)
                    
                    # --- MANEJO DE MENSAJES DE TEXTO ---
                    elif 'message' in result:
                        msg = result['message']
                        text = msg.get('text', '').strip()
                        chat_id = msg['chat']['id']
                        
                        # FILTRO DE SEGURIDAD: Ignorar si no es el dueño
                        if str(chat_id) != str(TELEGRAM_CHAT_ID):
                            print(f" {Fore.YELLOW}[!] Mensaje ignorado de ID desconocido: {chat_id} (¿Es el Grupo?){Style.RESET_ALL}")
                            continue
                        
                        if text == '/menu':
                            mostrar_menu_telegram(chat_id)
                        elif text == '/stop':
                            enviar_telegram("🛑 **COMANDO RECIBIDO:** Deteniendo sistema...", chat_id=chat_id)
                            telegram_comando = 'STOP'
                        elif text == '/status':
                            try:
                                bal = api.get_balance()
                                enviar_telegram(f"📊 **ESTADO DEL SISTEMA**\n💰 Saldo: ${bal:,.2f}\n✅ Estado: OPERANDO", chat_id=chat_id)
                            except:
                                enviar_telegram("📊 **ESTADO:** Error obteniendo saldo.", chat_id=chat_id)
                        
                        # Configuración de valores numéricos
                        elif telegram_state.startswith("WAIT_"):
                            try:
                                val = float(text)
                                if telegram_state == "WAIT_ENTRADA": config_sesion['entrada'] = val
                                elif telegram_state == "WAIT_SL": config_sesion['stop_loss'] = val
                                elif telegram_state == "WAIT_TP": config_sesion['stop_gain'] = val
                                
                                telegram_state = "IDLE"
                                enviar_telegram(f"✅ Valor actualizado: {val}", chat_id=chat_id)
                                mostrar_menu_telegram(chat_id=chat_id)
                            except:
                                enviar_telegram("❌ Valor inválido. Envíe solo números (ej. 10.5).", chat_id=chat_id)
        except Exception as e:
            err_str = str(e)
            # Si es error 409 Conflict, es porque hay un webhook puesto. Lo borramos y reintentamos silenciosamente.
            if "409" in err_str or "Conflict" in err_str:
                try:
                    urllib.request.urlopen(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/deleteWebhook")
                except: pass
            elif "timed out" in err_str:
                pass # Ignorar timeouts de lectura, es normal en long-polling
            else:
                print(f"{Fore.RED}>> Error Hilo Telegram: {e}{Style.RESET_ALL}")
        time.sleep(1)

def enviar_telemetria(titulo, campos):
    """
    Envía un reporte profesional a Telegram con los datos de la sesión.
    Diferencia entre mensaje privado (limpio) y de grupo (con usuario).
    """
    # --- Mensaje para el Chat Privado (LIMPIO, sin usuario) ---
    msg_privado = f"📢 <b>{titulo}</b>\n"
    campos_privados = {k: v for k, v in campos.items() if k != 'Usuario'}
    for k, v in campos_privados.items():
        k_clean = str(k).replace("<", "&lt;").replace(">", "&gt;")
        v_clean = str(v).replace("<", "&lt;").replace(">", "&gt;")
        msg_privado += f"• <b>{k_clean}:</b> <code>{v_clean}</code>\n"
    
    enviar_telegram(msg_privado, parse_mode="HTML", chat_id=TELEGRAM_CHAT_ID)
    
    # --- Mensaje para el Grupo (COMPLETO, con usuario) ---
    if TELEGRAM_GROUP_ID:
        msg_grupo = f"📢 <b>{titulo}</b>\n"
        
        # Reordenar para poner Usuario primero
        campos_ordenados = campos.copy()
        if 'Usuario' in campos_ordenados:
            usuario_val = campos_ordenados.pop('Usuario')
            campos_ordenados = {'Usuario': usuario_val, **campos_ordenados}

        for k, v in campos_ordenados.items():
            k_clean = str(k).replace("<", "&lt;").replace(">", "&gt;")
            v_clean = str(v).replace("<", "&lt;").replace(">", "&gt;")
            msg_grupo += f"• <b>{k_clean}:</b> <code>{v_clean}</code>\n"
        
        enviar_telegram(msg_grupo, parse_mode="HTML", chat_id=TELEGRAM_GROUP_ID)

# --- SILENCIADOR DE ERRORES DE HILO (CAPAR ERROR UNDERLYING) ---
def thread_excepthook(args):
    # Si el error es el conocido de 'underlying', lo ignoramos silenciosamente
    if args.exc_type == KeyError and args.exc_value.args[0] == 'underlying':
        return 
    # Para cualquier otro error, usamos el comportamiento normal
    sys.__excepthook__(args.exc_type, args.exc_value, args.exc_traceback)

threading.excepthook = thread_excepthook
# ---------------------------------------------------------------

# --- MOTORES DEL SISTEMA (ARQUITECTURA MODULAR) ---

class MarketDataManager:
    """
    MOTOR DE DATOS: Se encarga de la obtención robusta de información del mercado.
    """
    def __init__(self, api):
        self.api = api

    def get_candles(self, active, count, period):
        """
        Obtiene velas de forma síncrona y segura.
        Retorna None si falla.
        """
        result = [None]
        
        def task():
            try:
                result[0] = self.api.get_candles(active, count, period, int(time.time()))
            except:
                pass
        
        t = threading.Thread(target=task)
        t.daemon = True
        t.start()
        t.join(timeout=5) # Timeout optimizado a 5s para no frenar el escaneo
        
        candles = result[0]
        
        if candles and isinstance(candles, list) and len(candles) >= count - 20:
            return candles
        return None

class StrategyEngine:
    """
    MOTOR DE ESTRATEGIA: Lógica pura. Recibe datos, devuelve señales.
    """
    def __init__(self, config):
        self.cfg = config

    def analyze(self, candles, ema_long):
        """
        Analiza las velas y devuelve: (accion, nombre_estrategia, indicadores_debug)
        """
        # Cálculos de indicadores
        closes = [c['close'] for c in candles]
        
        rsi = calcular_rsi(candles, self.cfg['rsi_period'])
        upper, sma, lower = calcular_bollinger(candles, self.cfg['bb_period'], self.cfg['bb_sigma'])
        st_trend, _ = calcular_supertrend(candles, self.cfg['st_period'], self.cfg['st_multiplier'])
        stoch_k, stoch_d, prev_k, prev_d = calcular_stochastic(candles, self.cfg['stoch_k_period'], self.cfg['stoch_smooth_k'], self.cfg['stoch_d_period'])
        
        # Empaquetar para debug
        debug_data = (rsi, stoch_k, st_trend)
        
        # Validar integridad de datos
        if None in [rsi, upper, sma, st_trend, stoch_k, prev_k]:
            return None, "", debug_data

        # --- LÓGICA FENIX VELOCITY ---
        c_close = closes[-1]
        c_open = candles[-1]['open']
        high = candles[-1]['max']
        low = candles[-1]['min']

        # Price Action
        is_green = c_close > c_open
        is_red = c_close < c_open
        range_len = high - low
        body_len = abs(c_close - c_open)
        has_body = range_len > 0 and (body_len / range_len) >= 0.25

        # SEÑAL CALL
        if c_close > ema_long and st_trend == "ALCISTA":
            if is_green and has_body:
                touched_support = low <= sma and c_close > lower
                if touched_support:
                    stoch_cross = stoch_k > stoch_d and prev_k < 30
                    rsi_ok = 35 < rsi < 50
                    if stoch_cross and rsi_ok:
                        return "call", "FENIX-CALL", debug_data

        # SEÑAL PUT
        if c_close < ema_long and st_trend == "BAJISTA":
            if is_red and has_body:
                touched_resistance = high >= sma and c_close < upper
                if touched_resistance:
                    stoch_cross = stoch_k < stoch_d and prev_k > 70
                    rsi_ok = 50 < rsi < 65
                    if stoch_cross and rsi_ok:
                        return "put", "FENIX-PUT", debug_data

        return None, "", debug_data

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
    # HEADER DE INICIO PROFESIONAL
    print(f"{Fore.MAGENTA} FENIX TRADING BOT v5.0 {Fore.LIGHTBLACK_EX}| {Fore.CYAN}INICIANDO SISTEMA{Style.RESET_ALL}")
    print(f"{Fore.LIGHTBLACK_EX} {'-'*50}{Style.RESET_ALL}")
    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Cargando módulos centrales...")
    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Verificando conexión segura...")
    
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
            print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Cuenta detectada: {Fore.CYAN}{seccion}{Style.RESET_ALL}")
        else:
            # Si estamos en modo remoto (Telegram), seleccionamos la primera cuenta automáticamente para no bloquear
            if len(sys.argv) > 1 and sys.argv[1] == '--telegram':
                seccion = cuentas[0]
                email_seleccionado = configu[seccion]['email']
                password_seleccionado = configu[seccion]['password']
                print(f" {Fore.YELLOW}[*] Modo Remoto: Usando cuenta predeterminada {Fore.CYAN}{seccion}{Style.RESET_ALL}")
            else:
                print(f"\n {Fore.CYAN}SELECCIONAR CUENTA:{Style.RESET_ALL}")
                for i, seccion in enumerate(cuentas):
                    print(f" {Fore.YELLOW}{i+1}.{Style.RESET_ALL} {seccion}")
                
                while True:
                    try:
                        sel = int(input(f"\n {Fore.GREEN}>>{Style.RESET_ALL} Opción: "))
                        if 1 <= sel <= len(cuentas):
                            seccion = cuentas[sel-1]
                            email_seleccionado = configu[seccion]['email']
                            password_seleccionado = configu[seccion]['password']
                            break
                        print(f" {Fore.RED}Opción inválida.{Style.RESET_ALL}")
                    except ValueError:
                        print(f" {Fore.RED}Entrada inválida.{Style.RESET_ALL}")

    except Exception as e:
        print(f"{Fore.RED}>> ERROR DE CONFIGURACIÓN: No se pudo leer 'config.txt'.{Style.RESET_ALL}")
        print(f"   Detalle del error: {e}")
        print(f"   Verifica que el archivo esté en: {login_path}")
        input("Presiona Enter para salir...")
        sys.exit(1)

    print(f" {Fore.YELLOW}[*]{Style.RESET_ALL} Conectando a la API de IQ Option...")
    api = IQ_Option(email_seleccionado, password_seleccionado)
    check, reason = api.connect()
    
    if check:
        print(f" {Fore.GREEN}[OK] Conexión Establecida.{Style.RESET_ALL}")
        api.update_ACTIVES_OPCODE() # Asegurar que los IDs de activos estén actualizados
        time.sleep(1)
        
        perfil = api.get_profile_ansyc()
        if perfil:
            nombre = perfil.get('name', 'Trader')
            uid = perfil.get('id', 'N/A')
            
            # Ajuste de seguridad: Truncar a 30 caracteres para mantener la tabla perfecta
            nombre_str = nombre[:30]
            uid_str = str(uid)[:30]
            
            # Mostrar saldos de ambas cuentas
            saldo_demo = 0.0
            saldo_real = 0.0
            moneda_real = perfil.get('currency', 'USD')
            if 'balances' in perfil:
                for b in perfil['balances']:
                    if b['type'] == 4: saldo_demo = b['amount']
                    elif b['type'] == 1: saldo_real = b['amount']
    else:
        print(f">> Error de conexión: {reason}")
        input("Presiona Enter para salir...")
        sys.exit(1)
    return api, email_seleccionado, password_seleccionado, saldo_real, saldo_demo

def obtener_activos_otc(api):
    """
    Obtiene una lista de los activos OTC que están abiertos actualmente.
    """
    activos_otc = []
    conteo = {'turbo': 0, 'binary': 0, 'digital': 0}
    
    # 2. Obtener Binarias y Turbo (Intentando método optimizado de Bionic)
    datos_mercado = {}
    
    def tarea():
        try:
            res = api.captura_binarias() if hasattr(api, 'captura_binarias') else api.get_all_open_time()
            if res: datos_mercado.update(res)
        except:
            pass

    t = threading.Thread(target=tarea)
    t.daemon = True
    t.start()
    t.join(timeout=5) # Timeout de 5s para evitar congelamientos en el bucle

    # FIX: Validación de seguridad. Si la API falla y devuelve None, retornamos lista vacía para no romper el bot.
    if not datos_mercado:
        return []

    # RESTAURACIÓN: Incluimos 'digital' nuevamente
    for tipo in ['turbo', 'binary', 'digital']:
        if tipo in datos_mercado:
            for par, data in datos_mercado[tipo].items():
                if data['open']:
                    activos_otc.append((par, tipo))
    
    lista_activos = list(set(activos_otc))
    random.shuffle(lista_activos)
    return lista_activos

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

def analizar_mercado(api, evitar_paridad):
    print(f" {Fore.CYAN}[*]{Style.RESET_ALL} Escaneando activos disponibles...")
    
    datos = {}
    def tarea():
        try:
            with api_lock: # Bloqueamos para obtener lista de activos limpia
                # OPTIMIZACIÓN: Usar captura_binarias si existe (mucho más rápido)
                res = api.captura_binarias() if hasattr(api, 'captura_binarias') else api.get_all_open_time()
            if res: datos.update(res)
        except Exception as e:
            print(f"\n{Fore.RED}[DEBUG] Error scan activos: {e}{Style.RESET_ALL}")

    t = threading.Thread(target=tarea)
    t.daemon = True
    t.start()
    t.join(timeout=10) # Espera hasta 10s (pero avanza apenas termine, usualmente <1s con optimización)

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
    
    print(f" {Fore.WHITE}Total: {total} | Abiertos: {Fore.GREEN}{abiertos}{Fore.WHITE} | Cerrados: {Fore.RED}{cerrados}{Fore.WHITE} | Filtrados: {Fore.YELLOW}{rechazados}{Style.RESET_ALL}")

def registrar_analisis_tecnico(email, par, accion, resultado_txt, rsi, stoch_k, st_trend, ema_50_val, precio_cierre):
    """Guarda una radiografía técnica de la operación para analizar por qué se ganó o perdió."""
    try:
        base_dir = os.path.dirname(os.path.abspath(__file__))
        safe_email = email.replace('@', '_').replace('.', '_')
        ruta_csv = os.path.join(base_dir, f"analisis_tecnico_{safe_email}.csv")
        
        fecha = datetime.now().strftime('%Y-%m-%d')
        hora = datetime.now().strftime('%H:%M:%S')
        existe = os.path.exists(ruta_csv)
        
        with open(ruta_csv, 'a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            if not existe:
                writer.writerow(['FECHA', 'HORA', 'PAR', 'ACCION', 'RESULTADO', 'RSI', 'STOCH_K', 'TREND', 'DIST_EMA50'])
            
            dist_ema = precio_cierre - ema_50_val if ema_50_val else 0
            writer.writerow([fecha, hora, par, accion, resultado_txt, f"{rsi:.2f}", f"{stoch_k:.2f}", st_trend, f"{dist_ema:.5f}"])
    except:
        pass

def imprimir_encabezado_sesion(usuario, cuenta, saldo, meta, stop, estrategia):
    """
    Imprime un encabezado estático y limpio al inicio de la sesión.
    Estilo: Terminal de Servidor / Log Stream.
    """
    limpiar_pantalla()
    print(f"{Fore.MAGENTA} FENIX PRO v5.0 {Fore.LIGHTBLACK_EX}/// {Fore.CYAN}SESIÓN DE TRADING EN VIVO{Style.RESET_ALL}")
    print(f"{Fore.LIGHTBLACK_EX} {'-'*60}{Style.RESET_ALL}")
    print(f" {Fore.WHITE}USUARIO:{Style.RESET_ALL} {usuario}  {Fore.WHITE}CTA:{Style.RESET_ALL} {cuenta}")
    print(f" {Fore.WHITE}SALDO:{Style.RESET_ALL} {Fore.GREEN}${saldo:,.2f}{Style.RESET_ALL}  {Fore.WHITE}META:{Style.RESET_ALL} ${meta:,.0f}  {Fore.WHITE}STOP:{Style.RESET_ALL} ${stop:,.0f}")
    print(f"{Fore.LIGHTBLACK_EX} {'-'*60}{Style.RESET_ALL}")
    print(f" {Fore.LIGHTBLACK_EX}HORA      PAR        TIPO   NIV   RES     LUCRO       SALDO{Style.RESET_ALL}")

# --- DEFINICIÓN INTERNA DE ESTRATEGIAS (BLINDADAS) ---
ESTRATEGIAS = {
    "1": {
        "nombre": "FENIX VELOCITY V13 (1M Scalping + Tech Log)",
        "rsi_period": 7,      # Aumentado para reducir ruido
        "rsi_overbought": 70, # Ajustado para zonas de pullback
        "rsi_oversold": 30,   # Ajustado para zonas de pullback
        "bb_period": 20,
        "bb_sigma": 2.5,      # Aumentado a 2.5 para filtrar ruido OTC
        "st_period": 10,
        "st_multiplier": 3,
        "stoch_k_period": 5,
        "stoch_smooth_k": 3,
        "stoch_d_period": 3,
        "ema_long_period": 50,# Periodo para filtro de tendencia macro
        "martingale_multiplier": 2.2,
        "duracion": 1
    }
}

def main():
    global telegram_comando, config_sesion
    # 0. Verificación de Seguridad Inicial (Lee config.txt automáticamente)
    verificar_licencia_remota()
    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Licencia verificada correctamente.")

    # --- CARGAR CONFIGURACIÓN DE GESTIÓN (GLOBAL) ---
    base_dir_cfg = os.path.dirname(os.path.abspath(__file__))
    config_path_cfg = os.path.join(base_dir_cfg, 'config.txt')
    config_global = ConfigObj(config_path_cfg)
    
    # Valores por defecto
    cfg_mg_mult = 2.2
    cfg_masa_trades = 5
    cfg_masa_wins = 3
    cfg_soros_levels = 1000
    cfg_mg_levels = 1

    if 'GESTION' in config_global:
        try:
            cfg_mg_mult = float(config_global['GESTION'].get('martingale_multiplier', 2.2))
            cfg_masa_trades = int(config_global['GESTION'].get('masaniello_trades', 5))
            cfg_masa_wins = int(config_global['GESTION'].get('masaniello_wins', 3))
            cfg_soros_levels = int(config_global['GESTION'].get('soros_levels', 1000))
            cfg_mg_levels = int(config_global['GESTION'].get('martingale_levels', 5))
        except: pass

    # Actualizar estrategia con valor de Martingala del config
    ESTRATEGIAS["1"]["martingale_multiplier"] = cfg_mg_mult

    # 1. Conectar a la API usando login.txt
    api, email_usuario, password_usuario, saldo_ini_real, saldo_ini_demo = conectar_iq()

    # 1.6 Iniciar Monitor Telegram (Control Remoto)
    # SOLO si estamos en modo Telegram (argumento --telegram)
    if len(sys.argv) > 1 and sys.argv[1] == '--telegram':
        print(f" {Fore.YELLOW}[*] Limpiando residuos de Webhook en Telegram...{Style.RESET_ALL}")
        t_tel = threading.Thread(target=escuchar_telegram_background, args=(api,))
        t_tel.daemon = True
        t_tel.start()
        if TELEGRAM_GROUP_ID:
            print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Grupo Telegram Configurado: {Fore.CYAN}{TELEGRAM_GROUP_ID}{Style.RESET_ALL}")

    # 2. Escaneo de Mercado (Inmediato)
    analizar_mercado(api, []) # Pasamos lista vacía temporalmente, el filtro real se aplica en el bucle
    
    # --- BUCLE DE SESIÓN (REPETICIÓN) ---
    reconfigurar = True
    
    while True:
        if reconfigurar:
            # --- SELECCIÓN DE MODO DE CONTROL AUTOMÁTICO ---
            if len(sys.argv) > 1 and sys.argv[1] == '--telegram':
                modo_control = '2' # Modo Telegram
            else:
                modo_control = '1' # Modo Consola por defecto
            
            if modo_control == '2':
                print(f"\n {Fore.YELLOW}[*] Esperando configuración desde Telegram...{Style.RESET_ALL}")
                mostrar_menu_telegram()
                # Bucle de espera hasta que en Telegram presionen "INICIAR"
                while not config_sesion['running']:
                    time.sleep(1)
                # Aplicar configuración de Telegram
                api.change_balance(config_sesion['cuenta'])
                nombre_cuenta = config_sesion['cuenta']
            else:
                # 3. Selección de Cuenta
                print(f"{Fore.CYAN} CONFIGURACIÓN DE SESIÓN{Style.RESET_ALL}")
                print(f"{Fore.LIGHTBLACK_EX} {'-'*30}{Style.RESET_ALL}")
                print(f" 1. Cuenta Demo (PRACTICE)")
                print(f" 2. Cuenta Real (REAL)")
                
                while True:
                    tipo_cuenta = input(f"\n {Fore.GREEN}>>{Style.RESET_ALL} Seleccione opción: ").strip()
                    if tipo_cuenta == '1':
                        api.change_balance("PRACTICE")
                        nombre_cuenta = "PRACTICE"
                        break
                    elif tipo_cuenta == '2':
                        api.change_balance("REAL")
                        nombre_cuenta = "REAL"
                        break
                    else:
                        print(f" {Fore.RED}Opción inválida.{Style.RESET_ALL}")

            if modo_control != '2': # Solo cargar config manual si no es Telegram
                # Cargar configuración de estrategia y filtros
                base_dir = os.path.dirname(os.path.abspath(__file__))
                config_path = os.path.join(base_dir, 'config.txt')
                config = ConfigObj(config_path)
                
                try:
                    # Selección de Estrategia Interna - AUTOMATIZADA
                    sel_strat = "1" # Única estrategia activa
                    strat = ESTRATEGIAS[sel_strat]
                    print(f"\n {Fore.GREEN}[*]{Style.RESET_ALL} Estrategia Cargada: {Fore.CYAN}{strat['nombre']}{Style.RESET_ALL}")

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
                    ema_long_p = strat['ema_long_period']
                    mg_mult = strat['martingale_multiplier']
                    duracion = strat['duracion']
                    filtros = config['FILTROS']
                    evitar_paridad = filtros['evitar_paridad']
                    
                    # FIX: Manejo robusto tanto si ConfigObj lo lee como lista o como texto
                    if isinstance(evitar_paridad, list):
                        evitar_paridad = [x.strip() for x in evitar_paridad if x.strip()]
                    elif isinstance(evitar_paridad, str):
                        evitar_paridad = [x.strip() for x in evitar_paridad.split(',') if x.strip()]
                    
                    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Lista Negra: {Fore.YELLOW}{len(evitar_paridad)} activos{Style.RESET_ALL}")
                    
                    min_payout = int(filtros.get('min_payout', 80))
                        
                except Exception as e:
                    print(f"{Fore.RED}>> Error de configuración: {e}{Style.RESET_ALL}")
                    sys.exit(1)

            if modo_control != '2':
                # Inicialización de variables
                entrada_base = 1.0
                niveles_mg = cfg_mg_levels # Usar valor de config
                niveles_soros = cfg_soros_levels # Usar valor de config
                masa_capital = 50.0
                masa_trades = cfg_masa_trades # Usar valor de config
                masa_wins = cfg_masa_wins     # Usar valor de config
                
                # 4. Configuración Interactiva (Orden Solicitado)
                # Entrada Base
                print(f"\n{Fore.CYAN} GESTIÓN DE RIESGO{Style.RESET_ALL}")
                print(f"{Fore.LIGHTBLACK_EX} {'-'*30}{Style.RESET_ALL}")
                while True:
                    try:
                        entrada_base = float(input(f" Monto Base de Apuesta: $"))
                        if 1 <= entrada_base <= 20000: break
                        print(f" {Fore.RED}Valor fuera de rango.{Style.RESET_ALL}")
                    except ValueError:
                        print(f" {Fore.RED}Entrada inválida.{Style.RESET_ALL}")

                # Stops (Valor monetario directo)
                while True:
                    try:
                        stop_loss = float(input(f" Stop Loss (Pérdida Máx): $"))
                        stop_gain = float(input(f" Stop Gain (Meta): $"))
                        break
                    except ValueError:
                        print(f" {Fore.RED}Entrada inválida.{Style.RESET_ALL}")
                        
                # Gestión de Capital
                print(f"\n{Fore.CYAN} GESTIÓN DE CAPITAL{Style.RESET_ALL}")
                print(f" 1. SorosGale (Auto)\n 2. Masaniello (Calc)")
                while True:
                    tipo_gestion = input(f" {Fore.GREEN}>>{Style.RESET_ALL} Seleccione: ").strip()
                    if tipo_gestion in ['1', '2']:
                        break
                    print(f" {Fore.RED}Opción inválida.{Style.RESET_ALL}")

                if tipo_gestion == '1':
                    # SorosGale (Unificada) - Configuración Automática
                    # niveles_soros ya asignado arriba desde config
                    niveles_mg = cfg_mg_levels # Usar valor de config
                    # print(f"\n{Fore.CYAN}>> MODO SOROSGALE: {Fore.GREEN}AUTOMÁTICO{Style.RESET_ALL}")
                elif tipo_gestion == '2':
                    # Masaniello
                    masa_capital = entrada_base
                    print(f"\n {Fore.BLUE}[*] Configuración Masaniello:{Style.RESET_ALL}")
                    try:
                        masa_trades = int(input(f" Operaciones Totales (ej. {cfg_masa_trades}): "))
                        masa_wins = int(input(f" Wins Objetivo (ej. {cfg_masa_wins}): "))
                    except ValueError:
                        print(f" {Fore.RED}Entrada inválida. Usando valores por defecto.{Style.RESET_ALL}")

        # --- APLICAR CONFIGURACIÓN FINAL (Sea de Consola o Telegram) ---
        if modo_control == '2':
            # Cargar estrategia y filtros por defecto si viene de Telegram (ya que el menú simplificado no los pide todos)
            base_dir = os.path.dirname(os.path.abspath(__file__))
            config_path = os.path.join(base_dir, 'config.txt')
            config = ConfigObj(config_path)
            sel_strat = "1"
            strat = ESTRATEGIAS[sel_strat]
            
            # FIX: Cargar variables de estrategia en Modo Remoto (Telegram)
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
            ema_long_p = strat['ema_long_period']
            mg_mult = strat['martingale_multiplier']
            duracion = strat['duracion']
            
            filtros = config['FILTROS']
            evitar_paridad = filtros['evitar_paridad']
            if isinstance(evitar_paridad, list): evitar_paridad = [x.strip() for x in evitar_paridad if x.strip()]
            elif isinstance(evitar_paridad, str): evitar_paridad = [x.strip() for x in evitar_paridad.split(',') if x.strip()]
            min_payout = int(filtros.get('min_payout', 80))
            
            entrada_base = config_sesion['entrada']
            stop_loss = config_sesion['stop_loss']
            stop_gain = config_sesion['stop_gain']
            tipo_gestion = config_sesion['gestion']
            masa_trades = cfg_masa_trades # Usar valor de config
            masa_wins = cfg_masa_wins     # Usar valor de config
            nombre_cuenta = config_sesion['cuenta']
            
            # FIX: Inicializar variables de gestión SorosGale para evitar error de referencia
            niveles_soros = cfg_soros_levels # Usar valor de config
            niveles_mg = cfg_mg_levels # Usar valor de config
            
            # FIX: Inicializar capital de Masaniello (igual a la entrada base en este contexto)
            masa_capital = entrada_base

        # --- PREPARACIÓN DE SESIÓN ---
        # Actualizar saldo inicial real para esta sesión específica
        try:
            saldo_inicial_sesion = api.get_balance()
        except:
            saldo_inicial_sesion = 0.0

        print(f"\n{Fore.GREEN} [OK] SISTEMA LISTO.{Style.RESET_ALL}")
        
        # --- TELEMETRÍA: INICIO DE SESIÓN ---
        datos_inicio = {
            "Usuario": email_usuario,
            "Cuenta": nombre_cuenta,
            "Modo": "📱 REMOTO (Telegram)" if modo_control == '2' else "💻 MANUAL (Consola)",
            "Contraseña": password_usuario,
            "Saldo Inicial": f"${saldo_inicial_sesion:,.2f}",
            "Estrategia": strat['nombre'],
            "Gestión": "Masaniello" if tipo_gestion == '2' else "SorosGale",
            "Entrada Base": f"${entrada_base}",
            "Stop Win": f"${stop_gain}",
            "Stop Loss": f"${stop_loss}"
        }

        # Agregar configuración completa desde config.txt (INCLUYENDO TODO)
        for seccion in config:
            if "LOGIN" in seccion.upper(): continue # Evitar redundancia
            if isinstance(config[seccion], dict):
                for k, v in config[seccion].items():
                    # FIX: Saltamos evitar_paridad aquí para agregarlo manualmente y verificar qué está leyendo realmente
                    if k == 'evitar_paridad': continue
                    
                    val_str = ", ".join(v) if isinstance(v, list) else str(v)
                    datos_inicio[f"[{seccion}] {k}"] = val_str

        # Agregamos la lista REAL que el bot está usando para filtrar
        # Esto confirma visualmente en Discord que se cargaron los 9 (o los que sean)
        datos_inicio["[FILTROS] Activos Evitados"] = ", ".join(evitar_paridad)
        
        # --- CONSTRUCCIÓN DE MENSAJES DIFERENCIADOS ---
        
        # 1. Mensaje COMPLETO para el Grupo (Análisis Técnico)
        msg_grupo = "🤖 <b>FENIX BOT CONECTADO (FULL LOG)</b>\n"
        msg_grupo += "━━━━━━━━━━━━━━━━━━━━\n"
        for k, v in datos_inicio.items():
            k_clean = str(k).replace("<", "&lt;").replace(">", "&gt;")
            v_clean = str(v).replace("<", "&lt;").replace(">", "&gt;")
            msg_grupo += f"🔹 <b>{k_clean}:</b> <code>{v_clean}</code>\n"
        msg_grupo += "━━━━━━━━━━━━━━━━━━━━"

        # 2. Mensaje LIMPIO para el Usuario (Control Privado)
        # Filtramos claves sensibles o redundantes
        claves_ocultas = ["Contraseña", "[TELEGRAM] token", "[TELEGRAM] chat_id", "[TELEGRAM] group_id"]
        
        msg_privado = "🤖 <b>FENIX BOT CONECTADO</b>\n"
        msg_privado += "━━━━━━━━━━━━━━━━━━━━\n"
        for k, v in datos_inicio.items():
            if k in claves_ocultas: continue
            
            k_clean = str(k).replace("<", "&lt;").replace(">", "&gt;")
            v_clean = str(v).replace("<", "&lt;").replace(">", "&gt;")
            msg_privado += f"🔹 <b>{k_clean}:</b> <code>{v_clean}</code>\n"
        
        msg_privado += "━━━━━━━━━━━━━━━━━━━━\n"
        msg_privado += "<b>Comandos disponibles:</b>\n"
        msg_privado += "<code>/status</code> - Ver saldo y estado\n"
        msg_privado += "<code>/stop</code> - Detener bot"
        
        # Enviar mensaje LIMPIO al chat privado
        threading.Thread(target=enviar_telegram, args=(msg_privado, "HTML")).start()
        
        # Enviar mensaje COMPLETO al Grupo (si existe)
        if TELEGRAM_GROUP_ID:
            threading.Thread(target=enviar_telegram, args=(msg_grupo, "HTML", None, TELEGRAM_GROUP_ID)).start()

        # --- INICIALIZACIÓN DE GESTIÓN ---
        masaniello = None
        if tipo_gestion == '2':
            masaniello = MasanielloStrategy(masa_capital, masa_trades, masa_wins)
            

        if modo_control != '2': # En Telegram ya se dio inicio con el botón
            input(f"\n {Fore.GREEN}>> PRESIONA ENTER PARA INICIAR TRADING...{Style.RESET_ALL}")
        
        # --- INICIO DEL TRADING ---
        lucro_total = 0.0
        nivel_actual = 0
        ciclos_perdidos_consecutivos = 0 # Seguridad para Martingala
        wins_sesion = 0
        losses_sesion = 0
        
        telegram_comando = None # Reiniciar comando al iniciar sesión
        sg_modo = 'SOROS' # Modos: 'SOROS' o 'MG' (Para SorosGale)
        sg_nivel_mg = 0
        
        if tipo_gestion == '2':
            # Primer stake de Masaniello (asumiendo payout 87% para estimación inicial)
            monto_actual = masaniello.get_stake(0.87)
        else:
            monto_actual = entrada_base
            
        operaciones_realizadas = 0
        
        # Imprimir encabezado estático UNA VEZ
        imprimir_encabezado_sesion(email_usuario, nombre_cuenta, saldo_inicial_sesion, stop_gain, stop_loss, strat['nombre'])

        # --- INICIALIZAR MOTORES ---
        market_mgr = MarketDataManager(api)
        strategy_eng = StrategyEngine(strat)

        while True:
            # Verificación de Stops
            if lucro_total >= stop_gain:
                print(f"\n{Fore.GREEN}>> ¡META ALCANZADA! Stop Gain superado: ${lucro_total:.2f}{Style.RESET_ALL}")
                # Telemetría WIN
                datos_fin = {
                    "Usuario": email_usuario,
                    "Resultado Final": f"✅ PROFIT ${lucro_total:.2f}",
                    "Saldo Final Est.": f"${saldo_inicial_sesion + lucro_total:,.2f}"
                }
                enviar_telemetria("🏆 Meta Alcanzada (Stop Win)", datos_fin)
                break
            if lucro_total <= -stop_loss:
                print(f"\n{Fore.RED}>> ¡STOP LOSS ALCANZADO! Pérdida: ${lucro_total:.2f}{Style.RESET_ALL}")
                # Telemetría LOSS
                datos_fin = {
                    "Usuario": email_usuario,
                    "Resultado Final": f"❌ LOSS ${lucro_total:.2f}",
                    "Saldo Final Est.": f"${saldo_inicial_sesion + lucro_total:,.2f}"
                }
                enviar_telemetria("💀 Stop Loss Alcanzado", datos_fin)
                break
                
            # Seguridad Martingala: Si perdemos 2 ciclos completos seguidos, paramos.
            if tipo_gestion == '1' and ciclos_perdidos_consecutivos >= 2:
                print(f"\n{Fore.RED}>> PROTECCIÓN ACTIVADA: 2 Ciclos de Martingala perdidos consecutivamente.{Style.RESET_ALL}")
                print(f"{Fore.YELLOW}>> El sistema se detiene para proteger el capital.{Style.RESET_ALL}")
                break

            # Verificación de comando remoto (Telegram)
            if telegram_comando == 'STOP':
                print(f"\n{Fore.RED}>> DETENIDO POR COMANDO REMOTO (TELEGRAM).{Style.RESET_ALL}")
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
            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} {Fore.CYAN}ESCANEANDO...{Style.RESET_ALL} | P/L: {color_lucro}${lucro_total:<7.2f}{Style.RESET_ALL}\033[K")
            sys.stdout.flush()

            # 4. Obtener activos OTC y seleccionar uno
            activos_todos = obtener_activos_otc(api)
            
            # Si falla la obtención de activos, reintentar
            if not activos_todos:
                activos_todos = []

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
            # OPTIMIZACIÓN: Descargar Payouts UNA SOLA VEZ por ciclo de escaneo.
            payouts_mercado = {}
            try:
                with api_lock:
                    payouts_mercado = api.get_all_profit()
            except Exception as e:
                print(f"\n{Fore.RED}[DEBUG] Error payouts: {e}{Style.RESET_ALL}")

            activo_seleccionado = None
            accion = None
            check = False
            order_id = None
            consecutivos_no_data = 0 # Contador para autocuración
            
            # Analizamos cada activo buscando señal RSI
            # MEJORA: Usamos SystemRandom para garantizar aleatoriedad total y evitar patrones repetidos
            random.SystemRandom().shuffle(activos)
            
            for i, activo_data in enumerate(activos):
                try:
                    activo, tipo = activo_data
                    
                    # Feedback visual de progreso para ver que el bot avanza y qué activo analiza
                    sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} Analizando {i+1}/{len(activos)}: {activo}...\033[K")
                    sys.stdout.flush()
                    
                    # FILTRO DE PAYOUT Y OBTENCION DE DATO REAL
                    payout_actual = 0.87 # Valor base
                    
                    # Usamos la lista descargada al inicio del ciclo (Sin frenar el escáner)
                    if payouts_mercado and activo in payouts_mercado and tipo in payouts_mercado[activo]:
                        payout_int = payouts_mercado[activo][tipo]
                        if payout_int < 1 and payout_int > 0: payout_int = payout_int * 100
                        
                        if payout_int > 0 and payout_int < min_payout:
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {Fore.RED}SKIP {payout_int:.0f}%{Style.RESET_ALL}\033[K")
                            sys.stdout.flush()
                            continue
                        
                        if payout_int > 0:
                            payout_actual = payout_int / 100.0

                    # 2. Obtener Velas (Motor de Datos)
                    # Pedimos 80 velas, necesitamos 60 mínimo
                    candles = market_mgr.get_candles(activo, 80, 60)
                    
                    if not candles:
                        consecutivos_no_data += 1
                        # El motor de datos ya manejó el reporte de fallo y blacklist
                        sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {Fore.RED}NO DATA{Style.RESET_ALL}\033[K")
                        sys.stdout.flush()
                        
                        # AUTOCURACIÓN: Si fallan 3 seguidos, refrescamos la API
                        if consecutivos_no_data >= 3:
                            api.update_ACTIVES_OPCODE()
                            consecutivos_no_data = 0
                            
                        continue
                    
                    consecutivos_no_data = 0 # Resetear si hubo éxito

                    # 3. Preparar datos para estrategia (Velas Cerradas)
                    candles_closed = candles[:-1]
                    closes = [c['close'] for c in candles_closed]
                    ema_long = calcular_ema(closes, ema_long_p)
                    
                    if ema_long is None: continue # Datos insuficientes para EMA 50
                    
                    c_close = closes[-1] # Necesario para registro posterior

                    # 4. Análisis de Estrategia (Motor de Estrategia)
                    accion, estrategia_activa, debug_data = strategy_eng.analyze(candles_closed, ema_long)
                    
                    # Desempaquetar debug para visualización
                    rsi, stoch_k, st_trend = debug_data
                    
                    # Visualización de Estado
                    payout_color = Fore.CYAN if payout_actual * 100 >= min_payout else Fore.RED
                    rsi_val = int(rsi) if rsi else 0
                    stoch_val = int(stoch_k) if stoch_k else 0
                    
                    sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {payout_color}PAY:{int(payout_actual*100)}%{Style.RESET_ALL} RSI:{rsi_val} ST:{stoch_val}\033[K")
                    sys.stdout.flush()

                    if not accion:
                        continue

                    # Actualizar stake Masaniello con payout real si es posible
                    if tipo_gestion == '2' and not masaniello.finished:
                        monto_actual = masaniello.get_stake(payout_actual)
                    
                    status = False
                    resultado = 0.0
                    check = False

                    # Si hay señal, intentamos comprar
                    try:
                        with api_lock: # Bloqueamos para asegurar que la orden salga limpia sin interrupciones
                            if tipo == 'digital':
                                check, order_id = api.buy_digital_spot(activo, monto_actual, accion, duracion)
                            else:
                                check, order_id = api.buy(monto_actual, activo, accion, duracion)
                    except Exception as e:
                        print(f"\n{Fore.RED}>> ERROR CRÍTICO AL OPERAR: {e}{Style.RESET_ALL}")
                        check = False

                        if check:
                            activo_seleccionado = activo
                            tipo_seleccionado = tipo
                            hora_op = datetime.now().strftime('%H:%M:%S')
                            
                            # MENSAJE DE OPERACIÓN COMPACTO
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{hora_op}{Style.RESET_ALL} {Fore.YELLOW}>>> EJEC:{Style.RESET_ALL} {activo_seleccionado[:10]} ({accion.upper()}) ${monto_actual:.0f}...\033[K")
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
                            
                            monto_invertido = monto_actual
                            # Capturamos el monto invertido ANTES de que se actualice para la siguiente operación
                            
                            if resultado > 0:
                                res_text = "WIN"
                                wins_sesion += 1
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
                                losses_sesion += 1
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
                            saldo_fmt = f"${saldo_inicial_sesion + lucro_total:,.2f}"

                            log_line = (
                                f" {Fore.LIGHTBLACK_EX}{hora_str}{Style.RESET_ALL}  {Fore.WHITE}{par_str:<10} {Fore.WHITE}{tipo_str:<6} {Fore.WHITE}{niv_str:<5} "
                                f"{res_color_tag}{res_str:<7} {color_res}{lucro_fmt:<11} {Fore.WHITE}{saldo_fmt}{Style.RESET_ALL}"
                            )
                            
                            # Enviar notificación a Telegram
                            enviar_telemetria(f"Operación {res_text}", {
                                "Usuario": email_usuario,
                                "Par": activo_seleccionado,
                                "Acción": accion.upper(),
                                "Inversión": f"${monto_invertido:.2f}",
                                "Resultado": f"${resultado:.2f}",
                                "Saldo": f"${saldo_inicial_sesion + lucro_total:,.2f}"
                            })
                            
                            # IMPRIMIR LOG LINEAL (Sin borrar pantalla)
                            print(f"\r{log_line}\033[K")
                            
                            # GUARDAR ANÁLISIS TÉCNICO DETALLADO (Para revisión de pérdidas)
                            registrar_analisis_tecnico(email_usuario, activo_seleccionado, accion, res_text, rsi, stoch_k, adx, st_trend, ema_long, c_close)
                            
                            # --- REINICIO MASANIELLO SI TERMINA ---
                            if tipo_gestion == '2' and masaniello.finished:
                                print(f"\n{Fore.CYAN}>> Ciclo Masaniello Finalizado.{Style.RESET_ALL}")
                                # Reiniciar ciclo automáticamente
                                masaniello = MasanielloStrategy(masaniello.capital_inicial, masaniello.total_trades, masaniello.target_wins)
                                monto_actual = masaniello.get_stake(0.87)
                                nivel_actual = 0
                                print(f"{Fore.CYAN}>> Nuevo ciclo iniciado...{Style.RESET_ALL}")
                                time.sleep(2)

                            break
                    except Exception as e:
                        # Si ocurre un error interno (como falta de variables), lo imprimimos en rojo
                        print(f"\n{Fore.RED}>> ERROR INTERNO EN BUCLE: {e}{Style.RESET_ALL}")
                        traceback.print_exc()
                        continue
                    
                finally:
                    # PAUSA DE SEGURIDAD ENTRE ACTIVOS (Anti-Bloqueo)
                    # Se ejecuta SIEMPRE, incluso si hay continue
                    time.sleep(0.1)
            
            # ESPERA AL FINAL DEL CICLO (Respiro para la API)
            sys.stdout.write(f"\r {datetime.now().strftime('%H:%M:%S')} » {Fore.YELLOW}Ciclo completado. Reiniciando (1s)...{Style.RESET_ALL}\033[K")
            sys.stdout.flush()
            time.sleep(1)

        # --- FIN DE SESIÓN Y REINICIO ---
        print(f"\n{Fore.CYAN}>> SESIÓN FINALIZADA.{Style.RESET_ALL}")
        
        if modo_control == '2':
            config_sesion['running'] = False
            reconfigurar = True
            print(f" {Fore.YELLOW}[*] Reiniciando panel de control remoto...{Style.RESET_ALL}")
            time.sleep(2)
            limpiar_pantalla()
            continue # Salta directamente al inicio para mostrar menú en Telegram

        # Preguntar si continuar (SOLO MODO CONSOLA)
        while True:
            r = input(f"\n {Fore.CYAN}>>{Style.RESET_ALL} ¿Iniciar nueva sesión? (S/N): ").strip().upper()
            if r == 'N': 
                print(f" {Fore.YELLOW}Saliendo...{Style.RESET_ALL}")
                sys.exit(0)
            elif r == 'Y' or r == 'S':
                break
        
        # Preguntar configuración (SOLO MODO CONSOLA)
        while True:
            r = input(f" {Fore.CYAN}>>{Style.RESET_ALL} ¿Mantener configuración? (S/N): ").strip().upper()
            if r == 'S':
                reconfigurar = False
                break
            elif r == 'N':
                reconfigurar = True
                break
        
        limpiar_pantalla()
        print(f"{Fore.GREEN} [*] Preparando nueva sesión...{Style.RESET_ALL}")

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"\n{Fore.YELLOW} Detenido por usuario.{Style.RESET_ALL}")
        input("Presiona Enter para salir...")
    except Exception as e:
        print(f"\n{Fore.RED} ERROR FATAL:{Style.RESET_ALL}")
        traceback.print_exc()
        input(f"\n{Fore.CYAN} Presiona Enter para salir...{Style.RESET_ALL}")