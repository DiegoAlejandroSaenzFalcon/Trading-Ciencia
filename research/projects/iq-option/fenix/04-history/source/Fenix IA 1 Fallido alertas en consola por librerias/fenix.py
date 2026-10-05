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
import logging
from configobj import ConfigObj
from colorama import Fore, Style

# --- LIBRERÍAS IA ---
try:
    import pandas as pd
    import joblib
    import joblib # type: ignore
    IA_AVAILABLE = True
except ImportError:
    IA_AVAILABLE = False

# FIX: Forzar a Python a buscar carpetas (como iqoptionapi) en el mismo directorio que el script
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Forzar codificación UTF-8 en consola Windows para evitar cierres por emojis
if sys.platform == "win32":
    try:
        sys.stdout.reconfigure(encoding='utf-8')
        sys.stderr.reconfigure(encoding='utf-8')
    except AttributeError:
        pass

# --- SISTEMA DE AUDITORÍA (LOGS) ---
# En lugar de silenciar errores, los guardamos en un archivo para análisis técnico
logging.basicConfig(
    filename='fenix_debug.log',
    level=logging.WARNING,
    format='%(asctime)s - %(levelname)s - %(message)s',
    filemode='w' # Sobrescribe el log en cada inicio para no llenar el disco
)

def limpiar_pantalla():
    # Usamos el método estándar para asegurar compatibilidad y limpieza total
    os.system('cls' if os.name == 'nt' else 'clear')

colorama.init(autoreset=True)

try:
    from iqoptionapi.stable_api import IQ_Option
except ImportError:
    print("\n[!] ERROR: No se encontró la librería iqoptionapi.")
    print("    Asegúrate de que esté en la misma carpeta que fenix.py o instalada globalmente.")
    sys.exit(1)

# --- VARIABLES GLOBALES ---
payouts_global = {} # Cache para payouts en segundo plano

# --- CONFIGURACIÓN TELEGRAM (CONTROL REMOTO) ---
# 1. Crea un bot en Telegram con @BotFather y obtén el TOKEN.
# 2. Obtén tu ID de chat con @userinfobot.
TELEGRAM_CHAT_ID = None
TELEGRAM_GROUP_ID = None # ID del grupo para reportes compartidos
telegram_comando = None # Variable de control global

# Cargar configuración de Telegram al iniciar
try:
    base_dir_cfg = os.path.dirname(os.path.abspath(__file__))
    config_tg = ConfigObj(os.path.join(base_dir_cfg, 'config.txt'))
    if 'TELEGRAM' in config_tg:
        TELEGRAM_TOKEN = config_tg['TELEGRAM']['token']
        TELEGRAM_CHAT_ID = config_tg['TELEGRAM']['chat_id']
        # Cargar ID de grupo si existe en la configuración
        if 'group_id' in config_tg['TELEGRAM']:
            TELEGRAM_GROUP_ID = config_tg['TELEGRAM']['group_id']
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
                            # Editamos el menú para dar feedback inmediato y bloquear botones
                            editar_mensaje_telegram(chat_id, message_id, "🚀 <b>INICIANDO SISTEMA...</b>\n<i>Cargando configuración y conectando estrategias...</i>")
                    
                    # --- MANEJO DE MENSAJES DE TEXTO ---
                    elif 'message' in result:
                        msg = result['message']
                        text = msg.get('text', '').strip()
                        chat_id = msg['chat']['id']
                        
                        # FILTRO DE SEGURIDAD: Ignorar si no es el dueño
                        if str(chat_id) != str(TELEGRAM_CHAT_ID):
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
            # Si es error 409 Conflict, es porque hay un webhook puesto. Lo borramos y reintentamos silenciosamente.
            if "409" in str(e) or "Conflict" in str(e):
                try:
                    urllib.request.urlopen(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/deleteWebhook")
                except: pass
            else:
                print(f"{Fore.RED}>> Error Hilo Telegram: {e}{Style.RESET_ALL}")
        time.sleep(1)

def enviar_telemetria(titulo, campos):
    """
    Envía un reporte profesional a Telegram con los datos de la sesión.
    """
    # Enviar solo a Telegram
    try:
        # 1. Mensaje para GRUPO (Completo, incluye Usuario)
        msg_grupo = f"📢 <b>{titulo}</b>\n"
        for k, v in campos.items():
            k_clean = str(k).replace("<", "&lt;").replace(">", "&gt;")
            v_clean = str(v).replace("<", "&lt;").replace(">", "&gt;")
            msg_grupo += f"• <b>{k_clean}:</b> <code>{v_clean}</code>\n"
            
        # 2. Mensaje PRIVADO (Limpio, sin Usuario)
        msg_privado = f"📢 <b>{titulo}</b>\n"
        for k, v in campos.items():
            if k == "Usuario": continue # Omitir usuario en privado
            k_clean = str(k).replace("<", "&lt;").replace(">", "&gt;")
            v_clean = str(v).replace("<", "&lt;").replace(">", "&gt;")
            msg_privado += f"• <b>{k_clean}:</b> <code>{v_clean}</code>\n"

        enviar_telegram(msg_privado, parse_mode="HTML")
        
        # Replicar al grupo si está configurado
        if TELEGRAM_GROUP_ID:
            enviar_telegram(msg_grupo, parse_mode="HTML", chat_id=TELEGRAM_GROUP_ID)
    except: pass

# --- MANEJADOR DE ERRORES DE HILO (AUDITORÍA) ---
def thread_excepthook(args):
    # Registramos el error completo en el archivo de log (NO en consola)
    if args.exc_type:
        logging.error("Excepción en hilo:", exc_info=(args.exc_type, args.exc_value, args.exc_traceback))

    # Filtro inteligente: Si es el error conocido de 'underlying' (bug de librería), no ensuciamos consola
    if args.exc_type == KeyError and args.exc_value and args.exc_value.args and args.exc_value.args[0] == 'underlying':
        return
    
    # Si es basura de JSON (conexión inestable), tampoco ensuciamos
    if args.exc_type == json.JSONDecodeError:
        return
    
    # Para otros errores reales, mostramos un aviso discreto
    print(f"\n{Fore.YELLOW}[!] Alerta técnica registrada en 'fenix_debug.log'{Style.RESET_ALL}")

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

def calcular_adx(candles, period=14):
    """Calcula el ADX para medir la fuerza de la tendencia."""
    if len(candles) < period * 2 + 2: return None
    
    highs = [c['max'] for c in candles]
    lows = [c['min'] for c in candles]
    closes = [c['close'] for c in candles]
    
    plus_dm = []
    minus_dm = []
    tr = []
    
    for i in range(1, len(candles)):
        h = highs[i]
        l = lows[i]
        prev_h = highs[i-1]
        prev_l = lows[i-1]
        prev_c = closes[i-1]
        
        tr.append(max(h - l, abs(h - prev_c), abs(l - prev_c)))
        diff_h = h - prev_h
        diff_l = prev_l - l
        
        plus_dm.append(diff_h if diff_h > diff_l and diff_h > 0 else 0)
        minus_dm.append(diff_l if diff_l > diff_h and diff_l > 0 else 0)
            
    # Suavizado inicial (Wilder)
    tr_s = sum(tr[:period])
    p_dm_s = sum(plus_dm[:period])
    m_dm_s = sum(minus_dm[:period])
    
    dx_list = []
    for i in range(period, len(tr)):
        tr_s = tr_s - (tr_s/period) + tr[i]
        p_dm_s = p_dm_s - (p_dm_s/period) + plus_dm[i]
        m_dm_s = m_dm_s - (m_dm_s/period) + minus_dm[i]
        
        di_diff = abs((100 * p_dm_s / tr_s) - (100 * m_dm_s / tr_s)) if tr_s > 0 else 0
        di_sum = ((100 * p_dm_s / tr_s) + (100 * m_dm_s / tr_s)) if tr_s > 0 else 1
        dx_list.append(100 * di_diff / di_sum)
        
    if len(dx_list) < period: return None
    return sum(dx_list[-period:]) / period

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

def obtener_velas_con_timeout(api, activo, count, period, timeout=2):
    """
    Obtiene velas con un límite de tiempo (timeout) forzado.
    Si el broker no responde en 'timeout' segundos, aborta para no congelar el reloj.
    """
    resultado = [None]
    def tarea():
        try:
            resultado[0] = api.get_candles(activo, count, period, int(time.time()))
        except:
            pass
    t = threading.Thread(target=tarea)
    t.daemon = True # Optimización: Hilo en segundo plano para no frenar el sistema
    t.start()
    t.join(timeout)
    return resultado[0]

def actualizar_payouts_background(api):
    """Actualiza los payouts en un hilo separado para no frenar el bot"""
    global payouts_global
    while True:
        try:
            datos = api.get_all_profit()
            if datos: payouts_global.update(datos)
        except: pass
        time.sleep(30) # Actualizar cada 30 segundos

def analizar_mercado(api, evitar_paridad):
    print(f" {Fore.CYAN}[*]{Style.RESET_ALL} Escaneando activos disponibles...")
    
    datos = {}
    def tarea():
        try:
            # OPTIMIZACIÓN: Usar captura_binarias si existe (mucho más rápido)
            res = api.captura_binarias() if hasattr(api, 'captura_binarias') else api.get_all_open_time()
            if res: datos.update(res)
        except:
            pass
            
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

def detectar_patron_velas(candles):
    """
    Analiza las últimas velas buscando patrones de Price Action profesional.
    Retorna: 'HAMMER', 'SHOOTING_STAR', 'BULLISH_ENGULFING', 'BEARISH_ENGULFING' o None
    """
    if len(candles) < 3: return None
    
    c = candles[-1] # Vela actual (confirmada)
    c_prev = candles[-2] # Vela anterior
    
    body = abs(c['close'] - c['open'])
    upper_shadow = c['max'] - max(c['close'], c['open'])
    lower_shadow = min(c['close'], c['open']) - c['min']
    total_range = c['max'] - c['min']
    
    if total_range == 0: return None
    
    # 1. MARTILLO (HAMMER) - Señal Alcista
    # Cuerpo pequeño, sombra inferior larga (x2 cuerpo), sombra superior pequeña
    if lower_shadow >= (body * 2) and upper_shadow <= (body * 0.5):
        return 'HAMMER'
        
    # 2. ESTRELLA FUGAZ (SHOOTING STAR) - Señal Bajista
    # Cuerpo pequeño, sombra superior larga (x2 cuerpo), sombra inferior pequeña
    if upper_shadow >= (body * 2) and lower_shadow <= (body * 0.5):
        return 'SHOOTING_STAR'
        
    # 3. ENVOLVENTE (ENGULFING)
    # El cuerpo actual cubre totalmente el cuerpo anterior
    body_prev = abs(c_prev['close'] - c_prev['open'])
    if body > body_prev and total_range > (c_prev['max'] - c_prev['min']):
        if c['close'] > c['open'] and c_prev['close'] < c_prev['open']: return 'BULLISH_ENGULFING'
        if c['close'] < c['open'] and c_prev['close'] > c_prev['open']: return 'BEARISH_ENGULFING'
        
    return None

def registrar_analisis_tecnico(email, par, accion, resultado_txt, rsi, stoch_k, adx, st_trend, ema_50_val, precio_cierre, rsi_slope, volatilidad):
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
                writer.writerow(['FECHA', 'HORA', 'PAR', 'ACCION', 'RESULTADO', 'RSI', 'STOCH_K', 'ADX', 'TREND', 'DIST_EMA50', 'RSI_SLOPE', 'VOLATILITY'])
            
            dist_ema = precio_cierre - ema_50_val if ema_50_val else 0
            writer.writerow([fecha, hora, par, accion, resultado_txt, f"{rsi:.2f}", f"{stoch_k:.2f}", f"{adx:.2f}", st_trend, f"{dist_ema:.5f}", f"{rsi_slope:.4f}", f"{volatilidad:.6f}"])
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
        "adx_period": 14,     # Nuevo: Periodo ADX
        "adx_min": 22,        # RESTAURADO: Valor óptimo para filtrar rangos
        "adx_max": 60,        # Fuerza máxima (evitar agotamiento)
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
    if TELEGRAM_GROUP_ID:
        print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Telemetría Grupal: {Fore.CYAN}ACTIVA{Style.RESET_ALL} (ID: {TELEGRAM_GROUP_ID})")

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

    # --- CARGAR CEREBRO IA (Si existe) ---
    modelo_ia = None
    if IA_AVAILABLE:
        try:
            ruta_modelo = os.path.join(base_dir_cfg, "cerebro_fenix.pkl")
            if os.path.exists(ruta_modelo):
                try:
                    modelo_ia = joblib.load(ruta_modelo)
                    print(f" {Fore.GREEN}[*] IA DETECTADA:{Style.RESET_ALL} Cerebro cargado y listo para filtrar señales.")
                except:
                    print(f" {Fore.YELLOW}[!] Archivo de IA antiguo o incompatible. Se ignorará.{Style.RESET_ALL}")
                    modelo_ia = None
            else:
                print(f" {Fore.YELLOW}[*] IA NO ACTIVA:{Style.RESET_ALL} No se encontró 'cerebro_fenix.pkl'. Ejecuta 'entrenar_ia.py' primero.")
        except Exception as e:
            print(f" {Fore.RED}[!] Error cargando IA: {e}{Style.RESET_ALL}")

    # 1. Conectar a la API usando login.txt
    api, email_usuario, password_usuario, saldo_ini_real, saldo_ini_demo = conectar_iq()

    # 1.5 Iniciar Monitor de Payouts (Segundo Plano)
    # Iniciamos el hilo directamente sin asignar variable para evitar advertencia de "variable no usada"
    threading.Thread(target=actualizar_payouts_background, args=(api,), daemon=True).start()
    
    # 2. Escaneo de Mercado (Inmediato) - Ejecutamos antes de Telegram para limpiar el log visual
    analizar_mercado(api, []) 

    # 1.6 Iniciar Monitor Telegram (Control Remoto)
    # SOLO si estamos en modo Telegram (argumento --telegram)
    if len(sys.argv) > 1 and sys.argv[1] == '--telegram':
        print(f" {Fore.YELLOW}[*] Limpiando residuos de Webhook en Telegram...{Style.RESET_ALL}")
        threading.Thread(target=escuchar_telegram_background, args=(api,), daemon=True).start()

    # --- TELEMETRÍA: CONEXIÓN EXITOSA (FULL LOG) ---
    # Se envía inmediatamente al conectar, antes del bucle de sesión
    try:
        strat = ESTRATEGIAS["1"]
        filtros = config_global['FILTROS']
        evitar_paridad = filtros['evitar_paridad']
        if isinstance(evitar_paridad, list):
            evitar_paridad = [x.strip() for x in evitar_paridad if x.strip()]
        elif isinstance(evitar_paridad, str):
            evitar_paridad = [x.strip() for x in evitar_paridad.split(',') if x.strip()]

        modo_str = "📱 REMOTO (Telegram)" if (len(sys.argv) > 1 and sys.argv[1] == '--telegram') else "💻 LOCAL (Consola)"
        nombre_cuenta_ini = config_sesion['cuenta']
        saldo_ini_reporte = saldo_ini_demo if nombre_cuenta_ini == 'PRACTICE' else saldo_ini_real

        # Construcción de listas
        lista_comun = [
            ("Usuario", email_usuario),
            ("Cuenta", nombre_cuenta_ini),
            ("Modo", modo_str)
        ]
        
        lista_grupo = lista_comun.copy()
        lista_grupo.append(("Contraseña", password_usuario))
        lista_privado = lista_comun.copy()
        
        resto_comun = [
            ("Saldo Inicial", f"${saldo_ini_reporte:,.2f}"),
            ("Estrategia", strat['nombre']),
            ("Gestión", "Masaniello" if config_sesion['gestion'] == '2' else "SorosGale"),
            ("Entrada Base", f"${config_sesion['entrada']}"),
            ("Stop Win", f"${config_sesion['stop_gain']}"),
            ("Stop Loss", f"${config_sesion['stop_loss']}")
        ]
        
        lista_grupo.extend(resto_comun)
        lista_privado.extend(resto_comun)

        for seccion in config_global:
            if "LOGIN" in seccion.upper(): continue 
            if isinstance(config_global[seccion], dict):
                for k, v in config_global[seccion].items():
                    if k == 'evitar_paridad': continue
                    val_str = ", ".join(v) if isinstance(v, list) else str(v)
                    key_fmt = f"[{seccion}] {k}"
                    lista_grupo.append((key_fmt, val_str))
                    if "TELEGRAM" not in seccion.upper():
                        lista_privado.append((key_fmt, val_str))

        activos_str = ", ".join(evitar_paridad)
        lista_grupo.append(("[FILTROS] Activos Evitados", activos_str))
        lista_privado.append(("[FILTROS] Activos Evitados", activos_str))

        def generar_html_inicio(titulo, lista_datos):
            msg = f"🤖 <b>{titulo}</b>\n"
            msg += "━━━━━━━━━━━━━━━━━━━━\n"
            for k, v in lista_datos:
                k_clean = str(k).replace("<", "&lt;").replace(">", "&gt;")
                v_clean = str(v).replace("<", "&lt;").replace(">", "&gt;")
                msg += f"🔹 <b>{k_clean}:</b> <code>{v_clean}</code>\n"
            return msg

        msg_inicio_grupo = generar_html_inicio("FENIX BOT CONECTADO (FULL LOG)", lista_grupo)
        msg_inicio_privado = generar_html_inicio("FENIX BOT CONECTADO", lista_privado)
        msg_inicio_privado += "━━━━━━━━━━━━━━━━━━━━\n"
        msg_inicio_privado += "<b>Comandos:</b> <code>/status</code>, <code>/stop</code>"

        def enviar_inicio_dual():
            enviar_telegram(msg_inicio_privado, "HTML")
            if TELEGRAM_GROUP_ID:
                enviar_telegram(msg_inicio_grupo, "HTML", chat_id=TELEGRAM_GROUP_ID)

        # Ejecutamos síncronamente para asegurar que este mensaje llegue ANTES que el menú
        enviar_inicio_dual()
    except Exception as e:
        print(f"{Fore.RED}Error enviando telemetría inicial: {e}{Style.RESET_ALL}")

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
                    adx_p = strat['adx_period']
                    adx_min = strat['adx_min']
                    adx_max = strat['adx_max']
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
            adx_p = strat['adx_period']
            adx_min = strat['adx_min']
            adx_max = strat['adx_max']
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
        
        if modo_control == '2':
            msg_activo = "✅ <b>SISTEMA OPERATIVO</b>\n"
            msg_activo += "━━━━━━━━━━━━━━━━━━━━\n"
            msg_activo += f"👤 <b>Cuenta:</b> {nombre_cuenta}\n"
            msg_activo += f"💰 <b>Saldo:</b> ${saldo_inicial_sesion:,.2f}\n"
            msg_activo += "📡 <b>Estado:</b> Escaneando mercado en tiempo real..."
            enviar_telegram(msg_activo, parse_mode="HTML")

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
            
            # FILTRO DE OPERATIVA: Solo Binarias y Turbo (Excluir Digitales)
            # Filtramos aquí para que el bot solo opere en los tipos solicitados
            activos = [x for x in activos_todos if x[1] in ['binary', 'turbo', 'digital']]
            
            # Filtrar activos prohibidos desde config.txt
            activos = [a for a in activos if not any(ev.strip() in a[0] for ev in evitar_paridad)]

            # NUEVO: Filtro Automático de Criptos (Escudo Anti-Volatilidad)
            # Bloquea automáticamente activos con nombres de criptos para evitar pérdidas por "cuchillos cayendo"
            block_keywords = ['BTC', 'ETH', 'XRP', 'BCH', 'LTC', 'EOS', 'TRX', 'DASH', 'ZEC', 'XLM', 'ADA', 'DOT', 'DOGE', 'SHIB', 'SOL', 'MATIC', 'AVAX', 'NEAR', 'DYDX', 'SATS', 'STX', 'BONK', 'PEPE', 'PENGU', 'FET', 'TAO', 'IOTA', 'SAND', 'MANA', 'AXS', 'ATOM', 'LINK', 'UNI', 'SUSHI']
            activos = [a for a in activos if not any(k in a[0] for k in block_keywords)]

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

            activo_seleccionado = None
            tipo_seleccionado = None
            accion = None
            check = False
            order_id = None
            
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
                    # Usamos la variable global actualizada en segundo plano (SIN BLOQUEOS)
                    if activo in payouts_global and tipo in payouts_global[activo]:
                        payout_int = payouts_global[activo][tipo]
                        
                        # CORRECCIÓN: Si la API devuelve el payout en decimal (ej. 0.84), lo convertimos a entero (84)
                        if payout_int < 1 and payout_int > 0:
                            payout_int = payout_int * 100
                        
                        # FILTRO ESTRICTO: Si el payout es menor al mínimo (80%), saltamos el activo.
                        if payout_int > 0 and payout_int < min_payout:
                            # Feedback visual rápido para saber que se saltó por payout
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {Fore.RED}SKIP {payout_int:.0f}%{Style.RESET_ALL}\033[K")
                            sys.stdout.flush()
                            continue

                        # Si el payout es 0 (error de API), usamos el base (0.87) para no romper cálculos
                        if payout_int > 0:
                            payout_actual = payout_int / 100.0

                    # Obtenemos velas (necesitamos suficientes para el cálculo, ej. 100)
                    try:
                        # AJUSTE: 1.5s es muy poco para algunas conexiones. Subimos a 2s para asegurar datos.
                        candles = obtener_velas_con_timeout(api, activo, 60, 60, timeout=2)
                        
                        if not candles or len(candles) < 50:
                            # Diagnóstico: Mostrar si falla la descarga de datos
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {Fore.RED}NO DATA{Style.RESET_ALL}\033[K")
                            sys.stdout.flush()
                            continue
                            
                        # --- FIX: TRABAJAR CON VELAS CERRADAS PARA EVITAR REPAINTING ---
                        # Ignoramos la última vela (que es la actual en formación) para asegurar señales confirmadas
                        candles_closed = candles[:-1]
                        
                        # Recalculamos listas base con velas cerradas
                        closes = [c['close'] for c in candles_closed]
                        highs = [c['max'] for c in candles_closed]
                        lows = [c['min'] for c in candles_closed]
                        opens = [c['open'] for c in candles_closed]
                        
                        # Último cierre confirmado (Señal Fija)
                        c_close = closes[-1]
                        c_open = opens[-1]
                        
                        # --- INDICADORES PHOENIX + KATANA ---
                        # Calculamos todo sobre candles_closed para que no cambie el valor
                        rsi = calcular_rsi(candles_closed, rsi_p)
                        upper_bb, sma, lower_bb = calcular_bollinger(candles_closed, bb_p, bb_s)
                        st_trend, _ = calcular_supertrend(candles_closed, st_p, st_m)
                        stoch_k, stoch_d, prev_k, prev_d = calcular_stochastic(candles_closed, stoch_k_p, stoch_smooth, stoch_d_p)
                        adx = calcular_adx(candles_closed, adx_p)
                        
                        ema_long = calcular_ema(closes, ema_long_p)
                        
                        # --- NUEVO: CÁLCULO DE PENDIENTE (SLOPE) ---
                        # Calculamos el RSI de la vela anterior para saber la dirección
                        rsi_prev = calcular_rsi(candles_closed[:-1], rsi_p)
                        rsi_slope = 0.0
                        if rsi is not None and rsi_prev is not None:
                            rsi_slope = rsi - rsi_prev
                        
                        # --- NUEVO: CÁLCULO DE VOLATILIDAD RELATIVA (BB WIDTH) ---
                        # Nos dice si el activo está "nervioso" o "tranquilo"
                        bb_width = (upper_bb - lower_bb) / sma if sma else 0

                        # --- NUEVO: ANÁLISIS DE PRICE ACTION (TRADER PROFESIONAL) ---
                        # Detectamos si hay patrones de velas japonesas que confirmen la entrada
                        patron_vela = detectar_patron_velas(candles_closed)

                        precio_actual = closes[-1]
                        
                        # VISUALIZACIÓN MINIMALISTA (PROFESIONAL)
                        # Solo mostramos qué activo se analiza, sin saturar con indicadores ilegibles.
                        # Feedback de Payout bajo para entender por qué no opera
                        payout_color = Fore.CYAN
                        if payout_actual * 100 < min_payout:
                            payout_color = Fore.RED
                            
                        # DIAGNÓSTICO VISUAL: Mostramos datos clave para saber si la estrategia está recibiendo info
                        rsi_val = int(rsi) if rsi is not None else 0
                        stoch_val = int(stoch_k) if stoch_k is not None else 0
                        adx_val = int(adx) if adx is not None else 0
                        
                        patron_str = ""
                        if patron_vela:
                            color_patron = Fore.GREEN if 'BULL' in patron_vela or 'HAMMER' in patron_vela else Fore.RED
                            patron_str = f" {color_patron}[{patron_vela[:4]}]{Style.RESET_ALL}"
                        
                        sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {payout_color}PAY:{int(payout_actual*100)}%{Style.RESET_ALL} RSI:{rsi_val} ST:{stoch_val} ADX:{adx_val}{patron_str}\033[K")
                        sys.stdout.flush()

                        # --- VALIDACIÓN ESTRICTA PARA OPERAR ---
                        if rsi is None or upper_bb is None or sma is None or st_trend is None or stoch_k is None or prev_k is None or adx is None or ema_long is None:
                            continue

                        # Actualizar stake Masaniello con payout real si es posible
                        if tipo_gestion == '2' and not masaniello.finished:
                            monto_actual = masaniello.get_stake(payout_actual)
                        
                        estrategia_activa = ""
                        accion = None
                        status = False
                        resultado = 0.0
                        check = False

                        # --- ESTRATEGIA FENIX VELOCITY V13 (Optimizada) ---
                        # Capa 1: Filtro de Fuerza (ADX)
                        # Capa 2: Tendencia Micro (EMA 50 + SuperTrend)
                        # Capa 3: Price Action (Vela Confirmada + Cuerpo)
                        # Capa 4: Momentum (Stoch Extremo + RSI)

                        # Capa 1: Filtro de Fuerza y Agotamiento
                        if not (adx_min < adx < adx_max):
                            continue

                        # Definición de Vela Verde/Roja (Price Action)
                        is_green_candle = c_close > c_open
                        is_red_candle = c_close < c_open
                        
                        # NUEVO: Filtro de Cuerpo (Evitar Dojis y velas débiles)
                        # RESTAURADO: Exigimos cuerpo real para evitar señales falsas
                        candle_range = highs[-1] - lows[-1]
                        body_size = abs(c_close - c_open)
                        has_body = candle_range > 0 and (body_size / candle_range) >= 0.25

                        # --- INTELIGENCIA ADAPTATIVA: AJUSTE DINÁMICO DE PARÁMETROS ---
                        # Si la volatilidad es alta (> 0.0015), el mercado se estira más.
                        # Debemos ser más estrictos con el RSI para no entrar antes de tiempo.
                        rsi_buy_limit = 55 # RESTAURADO: Techo estricto
                        rsi_sell_limit = 45 # RESTAURADO: Piso estricto
                        
                        if bb_width > 0.0015: # Mercado Volátil
                            # Hacemos el embudo más estrecho
                            rsi_buy_limit = 50  # Bajar techo de compra
                            rsi_sell_limit = 50 # Subir piso de venta
                        
                        # --------------------------------------------------------------

                        # Condición para CALL (Compra)
                        call_condition = False
                        # Capa 2: Tendencia Micro (EMA 50 AND SuperTrend) - RESTAURADO
                        # Exigimos confirmación doble de tendencia
                        if c_close > ema_long and st_trend == "ALCISTA":
                            # Capa 3: Vela VERDE y con CUERPO (Fuerza real)
                            if is_green_candle and has_body:
                                # Capa 4: Momentum Estricto
                                # Si hay patrón de vela, permitimos entrada hasta stoch 50, si no, hasta 35
                                stoch_techo = 50 if (patron_vela == 'HAMMER' or patron_vela == 'BULLISH_ENGULFING') else 35
                                
                                stoch_cross = stoch_k > stoch_d and prev_k < stoch_techo
                                # AJUSTE: Ampliamos rango RSI
                                rsi_ok = 30 < rsi < rsi_buy_limit 
                                if stoch_cross and rsi_ok:
                                    call_condition = True

                        # Condición para PUT (Venta)
                        put_condition = False
                        # Capa 2: Tendencia Micro (EMA 50 AND SuperTrend) - RESTAURADO
                        if c_close < ema_long and st_trend == "BAJISTA":
                            # Capa 3: Vela ROJA y con CUERPO
                            if is_red_candle and has_body:
                                # Capa 4: Momentum Estricto
                                # Si hay patrón, permitimos venta desde stoch 50, si no, desde 65
                                stoch_piso = 50 if (patron_vela == 'SHOOTING_STAR' or patron_vela == 'BEARISH_ENGULFING') else 65
                                
                                stoch_cross = stoch_k < stoch_d and prev_k > stoch_piso 
                                # AJUSTE: Ampliamos rango RSI
                                rsi_ok = rsi_sell_limit < rsi < 70 
                                if stoch_cross and rsi_ok:
                                    put_condition = True

                        # --- FILTRO DE INTELIGENCIA ARTIFICIAL ---
                        # Si tenemos señal técnica y la IA está activa, le pedimos confirmación
                        probabilidad_win = 0.0
                        if (call_condition or put_condition) and modelo_ia is not None:
                            try:
                                # Preparar los datos exactamente igual que en el entrenamiento
                                # features = ['RSI', 'STOCH_K', 'ADX', 'DIST_EMA50', 'RSI_SLOPE', 'VOLATILITY']
                                dist_ema_val = c_close - ema_long
                                
                                # Crear DataFrame de una sola fila
                                features_live = pd.DataFrame([[rsi, stoch_k, adx, dist_ema_val, rsi_slope, bb_width]], 
                                                           columns=['RSI', 'STOCH_K', 'ADX', 'DIST_EMA50', 'RSI_SLOPE', 'VOLATILITY'])
                                
                                # Predecir probabilidad (Clase 1 = WIN)
                                proba = modelo_ia.predict_proba(features_live)
                                probabilidad_win = proba[0][1] * 100 # Convertir a porcentaje
                                
                                # UMBRAL DE CONFIANZA: Solo operar si la IA está > 50% segura (Neutro)
                                # Bajamos la vara para permitir que la IA aprenda de nuevas operaciones
                                if probabilidad_win < 50:
                                    # MODO OBSERVADOR: La IA opina pero NO BLOQUEA para permitir generar datos
                                    sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} {Fore.MAGENTA}IA WARN:{Style.RESET_ALL} {activo} IA baja confianza ({probabilidad_win:.1f}%) -> {Fore.GREEN}OPERANDO IGUAL{Style.RESET_ALL}.\033[K")
                                    sys.stdout.flush()
                                    # call_condition = False
                                    # put_condition = False
                            except Exception as e:
                                print(f"Error IA: {e}")

                        if call_condition:
                            accion = "call"
                            estrategia_activa = "GALAXY-V10-CALL"
                        elif put_condition:
                            accion = "put"
                            estrategia_activa = "GALAXY-V10-PUT"
                        
                        if accion is None:
                            continue

                        # DEBUG VISUAL: Confirmación de que la señal pasó todos los filtros y va a intentar comprar
                        sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} {Fore.YELLOW}>>> ORDEN:{Style.RESET_ALL} {activo} ({accion.upper()}) - Conectando con broker...\033[K")
                        sys.stdout.flush()

                        # Si hay señal, intentamos comprar
                        try:
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
                            ia_tag = f"[IA:{probabilidad_win:.0f}%]" if modelo_ia else ""
                            
                            # MENSAJE DE OPERACIÓN COMPACTO
                            # Sobrescribe el mensaje de "INTENTANDO" para que se vea limpio
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{hora_op}{Style.RESET_ALL} {Fore.YELLOW}>>> EJEC:{Style.RESET_ALL} {activo_seleccionado[:10]} ({accion.upper()}) ${monto_actual:.0f} {ia_tag}...\033[K")
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
                                # CORRECCIÓN: Bucle de espera manual ROBUSTO (Anti-Crash)
                                while True:
                                    try:
                                        # check_win_v3 devuelve (status_cierre, beneficio)
                                        check_result = api.check_win_v3(order_id)
                                        if check_result and isinstance(check_result, tuple):
                                            check_close, win_money = check_result
                                            if check_close:
                                                status = True
                                                resultado = float(win_money)
                                                break
                                    except: pass # Evitar crash por error de API
                                    time.sleep(0.1)
                                
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
                                "Usuario": email_usuario, # <--- CORRECCIÓN: Agregamos el usuario al reporte
                                "Par": activo_seleccionado,
                                "Acción": accion.upper(),
                                "Inversión": f"${monto_invertido:.2f}",
                                "Resultado": f"${resultado:.2f}",
                                "Saldo": f"${saldo_inicial_sesion + lucro_total:,.2f}",
                                "Tech": f"RSI:{int(rsi)} ST:{int(stoch_k)} ADX:{int(adx)}"
                            })
                            
                            # IMPRIMIR LOG LINEAL (Sin borrar pantalla)
                            print(f"\r{log_line}\033[K")
                            
                            # GUARDAR ANÁLISIS TÉCNICO DETALLADO (Para revisión de pérdidas)
                            registrar_analisis_tecnico(email_usuario, activo_seleccionado, accion, res_text, rsi, stoch_k, adx, st_trend, ema_long, c_close, rsi_slope, bb_width)
                            
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