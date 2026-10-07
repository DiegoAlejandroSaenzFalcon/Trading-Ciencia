import time
import csv
import sys
import os

# FIX: Forzar a Python a buscar carpetas (como iqoptionapi) en el mismo directorio que el script
# Se mueve al inicio para asegurar que las librerías locales se carguen correctamente antes de importar
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import threading
import random
import math
import traceback
import urllib.request
import urllib.error
from datetime import datetime
import logging
import colorama
from configobj import ConfigObj
from colorama import Fore, Style

# Importaciones opcionales (IA y Telegram) para no bloquear el inicio si faltan
try:
    import joblib
    import pandas as pd
except ImportError:
    joblib = None
    pd = None

try:
    import requests
except ImportError:
    requests = None

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

# --- SILENCIADOR DE RUIDO DE LIBRERÍA ---
# Elimina el mensaje "ERROR:root:*warning* get_all_init late 30 sec" y otros logs internos
logging.getLogger().setLevel(logging.CRITICAL)

# --- LOG DE ERRORES EN ARCHIVO (FIX v5.2) ---
# Todos los errores de red/API/Telegram se redirigen a fenix_errors.log
# para NO contaminar la interfaz visual de la terminal.
import traceback as _tb
_log_dir = os.path.dirname(os.path.abspath(__file__))
_log_path = os.path.join(_log_dir, 'fenix_errors.log')

def _log_error(tag: str, exc: Exception, extra: str = ""):
    """Escribe un error en fenix_errors.log sin tocar la terminal."""
    try:
        with open(_log_path, 'a', encoding='utf-8') as _f:
            _f.write(f"[{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] [{tag}] {exc}")
            if extra:
                _f.write(f" | {extra}")
            _f.write("\n")
    except Exception:
        pass  # Si falla el log, silencio total — nunca romper la UI

from iqoptionapi.stable_api import IQ_Option # type: ignore

# --- VARIABLES GLOBALES ---
payouts_global = {} # Cache para payouts en segundo plano
modelo_ia = None    # Variable para el cerebro IA
ia_status_msg = ""  # Mensaje de estado de la IA

# SESIÓN PERSISTENTE PARA TELEGRAM (Keep-Alive)
# Esto mantiene la conexión abierta y evita el lag de reconexión SSL
TELEGRAM_SESSION = None
if requests:
    TELEGRAM_SESSION = requests.Session()

# --- PARÁMETROS DE ESTRATEGIA PARA TELEGRAM ---
# Clave: (Label para el botón, Mensaje para pedir valor)
TELEGRAM_PARAMS_ESTRATEGIA = {
    "rsi_period": ("RSI Periodo", "Periodo del RSI (ej. 2)"),
    "rsi_overbought": ("RSI Sobrecompra", "Nivel Techo RSI (ej. 82)"),
    "rsi_oversold": ("RSI Sobreventa", "Nivel Suelo RSI (ej. 18)"),
    "bb_period": ("BB Periodo", "Periodo Bandas de Bollinger (ej. 20)"),
    "bb_sigma": ("BB Sigma", "Desviación Estándar BB (ej. 2.0)"),
    "st_period": ("SuperTrend Periodo", "Periodo del SuperTrend (ej. 10)"),
    "st_multiplier": ("SuperTrend Multiplicador", "Multiplicador del SuperTrend (ej. 3)"),
    "stoch_k_period": ("Stoch Periodo K", "Periodo K del Estocástico (ej. 14)"),
    "stoch_smooth_k": ("Stoch Suavizado K", "Suavizado K del Estocástico (ej. 3)"),
    "stoch_d_period": ("Stoch Periodo D", "Periodo D del Estocástico (ej. 3)"),
    "adx_period": ("ADX Periodo", "Periodo del ADX (ej. 14)"),
    "adx_min": ("ADX Mínimo", "Fuerza mínima de tendencia (ej. 20)"),
    "adx_max": ("ADX Máximo", "Fuerza máxima (evitar agotamiento, ej. 75)"),
    "ema_long_period": ("EMA Larga Periodo", "Periodo de la EMA de tendencia (ej. 50)"),
    "duracion": ("Duración Trade", "Duración de la operación en minutos (ej. 2)"),
    "margin_pips": ("Margen Seguridad Pips", "Pips de margen para entrar (ej. 6)"),
    "mg_mult": ("MG Multiplier", "Multiplicador Martingala (ej. 2.2)"),
    "sma_trend_period": ("SMA Trend Period", "Periodo SMA de tendencia (ej. 50)")
}

# Cargar Modelo IA si existe
try:
    base_dir_ia = os.path.dirname(os.path.abspath(__file__))
    ruta_modelo = os.path.join(base_dir_ia, 'cerebro_fenix.pkl')
    if os.path.exists(ruta_modelo):
        modelo_ia = joblib.load(ruta_modelo)
        ia_status_msg = f"{Fore.GREEN}[IA] Cerebro cargado exitosamente.{Style.RESET_ALL}"
    else:
        ia_status_msg = f"{Fore.YELLOW}[IA] No se encontró modelo IA (cerebro_fenix.pkl). Operando en modo clásico.{Style.RESET_ALL}"
except Exception as e:
    ia_status_msg = f"{Fore.YELLOW}[IA] No se encontró modelo IA (cerebro_fenix.pkl). Operando en modo clásico.{Style.RESET_ALL}"

# --- CONFIGURACIÓN TELEGRAM (CONTROL REMOTO) ---
# 1. Crea un bot en Telegram con @BotFather y obtén el TOKEN.
# 2. Obtén tu ID de chat con @userinfobot.
TELEGRAM_CHAT_ID = None
TELEGRAM_GROUP_ID = None # ID del grupo para reportes compartidos
telegram_comando = None # Variable de control global
TELEGRAM_MENU_ID = None # ID del mensaje del menú para actualizaciones in-place
TELEGRAM_THREAD_ID = None # ID del mensaje de inicio de sesión para agrupar respuestas

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
    "entrada": 5000,        # <--- MODIFICAR AQUÍ: Monto de entrada por defecto
    "stop_loss": 5000,     # <--- MODIFICAR AQUÍ: Stop Loss por defecto
    "stop_gain": 15000,      # <--- MODIFICAR AQUÍ: Meta (Stop Win) por defecto
    "gestion": "1",        # 1=SorosGale, 2=Masaniello
    "masa_trades": 5,
    "masa_wins": 3,
    "mg_mult": 2.2,        # Multiplicador de Martingala
    "soros_levels": 0,     # Niveles de Soros
    "mg_levels": 0,        # Niveles de Martingala
    "min_payout": 80,      # Payout Mínimo (Relajado para encontrar más pares)
    # --- PARÁMETROS DE ESTRATEGIA (Valores por defecto de ESTRATEGIAS["1"]) ---
    "rsi_period": 2,
    "rsi_overbought": 75,
    "rsi_oversold": 25,
    "bb_period": 20,
    "bb_sigma": 2.5,
    "st_period": 10,
    "st_multiplier": 3,
    "stoch_k_period": 14,
    "stoch_smooth_k": 3,
    "stoch_d_period": 3,
    "adx_period": 14,
    "adx_min": 10,
    "adx_max": 80,
    "ema_long_period": 50,
    "duracion": 1,
    "margin_pips": 3,
    "sma_trend_period": 50
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
    
    print(f" {Fore.LIGHTBLACK_EX}[*] Verificando licencia...{Style.RESET_ALL}", end='\r')
    
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
        with urllib.request.urlopen(req, timeout=5) as response:
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

def enviar_telegram(mensaje, parse_mode="Markdown", reply_markup=None, chat_id=None, reply_to_message_id=None):
    """Envía mensajes al bot de Telegram configurado."""
    if not requests or not TELEGRAM_TOKEN or "TU_TOKEN" in TELEGRAM_TOKEN: return None
    
    dest_id = chat_id if chat_id else TELEGRAM_CHAT_ID
    
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/sendMessage"
    payload = {"chat_id": dest_id, "text": mensaje, "parse_mode": parse_mode}
    if reply_markup:
        payload["reply_markup"] = reply_markup
    if reply_to_message_id:
        payload["reply_to_message_id"] = reply_to_message_id
    try:
        # OPTIMIZACIÓN: Usar sesión persistente
        response = TELEGRAM_SESSION.post(url, json=payload, timeout=10)
        return response.json()
    except Exception as e:
        # FIX v5.2: Error va al log, nunca a la terminal (rompía la UI)
        _log_error("TELEGRAM_SEND", e, f"dest={dest_id}")
        return None

def editar_mensaje_telegram(chat_id, message_id, texto, reply_markup=None):
    """Edita un mensaje existente en Telegram para efecto interactivo."""
    if not requests: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/editMessageText"
    payload = {"chat_id": chat_id, "message_id": message_id, "text": texto, "parse_mode": "HTML"}
    if reply_markup:
        payload["reply_markup"] = reply_markup
        
    try:
        TELEGRAM_SESSION.post(url, json=payload, timeout=10)
    except Exception as e:
        # FIX v5.2: Error va al log, nunca a la terminal
        _log_error("TELEGRAM_EDIT", e, f"msg_id={message_id}")

def responder_callback(callback_id, texto=None):
    """Responde al servidor de Telegram para detener la animación de carga del botón."""
    if not requests: return
    url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/answerCallbackQuery"
    payload = {"callback_query_id": callback_id}
    if texto: payload["text"] = texto
    try:
        # Usamos post simple e ignoramos errores (si expiró, no importa)
        TELEGRAM_SESSION.post(url, json=payload, timeout=5)
    except Exception:
        pass

def mostrar_menu_avanzado(chat_id, message_id):
    """Muestra el menú de configuración avanzada con todos los parámetros."""
    global TELEGRAM_MENU_ID
    
    rows = []
    buttons = []
    
    if config_sesion['gestion'] == '1': # SorosGale
        buttons.append({"text": f"🔄 Niveles Soros: {config_sesion['soros_levels']}", "callback_data": "set_soros_lvl"})
        buttons.append({"text": f"🛡️ Niveles MG: {config_sesion['mg_levels']}", "callback_data": "set_mg_lvl"})
    else: # Masaniello
        buttons.append({"text": f"🎲 Trades Totales: {config_sesion['masa_trades']}", "callback_data": "set_masa_trades"})
        buttons.append({"text": f"🏆 Wins Objetivo: {config_sesion['masa_wins']}", "callback_data": "set_masa_wins"})

    # --- PARÁMETROS DE ESTRATEGIA (ORDENADOS) ---
    param_order = [
        "rsi_period", "rsi_overbought", "rsi_oversold", 
        "bb_period", "bb_sigma", 
        "st_period", "st_multiplier",
        "stoch_k_period", "stoch_smooth_k", "stoch_d_period",
        "adx_period", "adx_min", "adx_max",
        "ema_long_period", "sma_trend_period",
        "mg_mult", "duracion", "margin_pips"
    ]
    
    # Añadir el resto de parámetros de estrategia
    for key in param_order:
        label, _ = TELEGRAM_PARAMS_ESTRATEGIA[key]
        value = config_sesion.get(key, 'N/A')
        # Usar el callback específico para mg_mult para mantener la lógica existente
        callback = "set_mg_mult" if key == "mg_mult" else f"set_strategy_{key}"
        buttons.append({"text": f"{label}: {value}", "callback_data": callback})

    # Añadir Payout al final
    buttons.append({"text": f"📉 Min Payout: {config_sesion['min_payout']}%", "callback_data": "set_min_payout"})

    # Agrupar todos los botones de a dos
    rows.extend([buttons[i:i + 2] for i in range(0, len(buttons), 2)])

    rows.append([{"text": "🔙 Volver al Menú Principal", "callback_data": "back_main"}])
    
    keyboard = {"inline_keyboard": rows}
    texto_menu = "⚙️ <b>CONFIGURACIÓN AVANZADA</b>\nAjuste los parámetros de la estrategia y gestión:"
    
    editar_mensaje_telegram(chat_id, message_id, texto_menu, reply_markup=keyboard)

def mostrar_menu_telegram(chat_id=None, message_id=None):
    """Envía o actualiza el panel de control con botones a Telegram."""
    global TELEGRAM_MENU_ID
    
    # NUEVO: Texto dinámico para el botón de gestión
    gestion_text = ""
    if config_sesion['gestion'] == '1':
        s_lvl = config_sesion['soros_levels']
        m_lvl = config_sesion['mg_levels']
        gestion_text = f"SorosGale ({s_lvl}/{m_lvl})"
    else: # Masaniello
        trades = config_sesion['masa_trades']
        wins = config_sesion['masa_wins']
        gestion_text = f"Masaniello ({trades}/{wins})"

    keyboard = {
        "inline_keyboard": [
            [{"text": f"💳 Cuenta: {config_sesion['cuenta']}", "callback_data": "toggle_account"}],
            [{"text": f"💰 Entrada: ${config_sesion['entrada']}", "callback_data": "set_bet"}],
            [{"text": f"🛑 Stop: ${config_sesion['stop_loss']}", "callback_data": "set_sl"}, {"text": f"🎯 Meta: ${config_sesion['stop_gain']}", "callback_data": "set_tp"}],
            [{"text": f"📊 Gestión: {gestion_text}", "callback_data": "toggle_gestion"}],
            [{"text": "⚙️ Config. Avanzada", "callback_data": "menu_advanced"}],
            [{"text": "🚀 INICIAR SISTEMA", "callback_data": "start_bot"}]
        ]
    }
    texto_menu = "🎛 <b>PANEL DE CONTROL FENIX</b>\nConfigure los parámetros antes de iniciar:"
    
    dest_id = chat_id if chat_id else TELEGRAM_CHAT_ID
    msg_id = message_id if message_id else TELEGRAM_MENU_ID
    
    if msg_id and dest_id:
        editar_mensaje_telegram(dest_id, msg_id, texto_menu, reply_markup=keyboard)
        TELEGRAM_MENU_ID = msg_id
    else:
        res = enviar_telegram(texto_menu, parse_mode="HTML", reply_markup=keyboard, chat_id=dest_id)
        if res and 'result' in res:
            TELEGRAM_MENU_ID = res['result']['message_id']

def escuchar_telegram_background(api):
    """Hilo en segundo plano para recibir comandos de Telegram."""
    global telegram_comando, telegram_state, config_sesion, TELEGRAM_MENU_ID
    if not requests or not TELEGRAM_TOKEN or "TU_TOKEN" in TELEGRAM_TOKEN: return
    
    # FIX: Eliminar webhook previo para evitar error 409 
    try:
        requests.get(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/deleteWebhook?drop_pending_updates=True", timeout=5)
    except Exception:
        pass
    
    offset = 0
    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Monitor Telegram: {Fore.CYAN}ACTIVO (Modo Ultra-Rápido){Style.RESET_ALL}")
    
    while True:
        try:
            # OPTIMIZACIÓN FINAL: Usamos requests.Session() con Keep-Alive.
            # Esto mantiene el canal abierto (TCP) y elimina el lag de reconexión SSL.
            # Volvemos a Long Polling (20s) porque ahora la conexión es estable y rápida.
            url = f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/getUpdates"
            params = {'offset': offset, 'timeout': 20}
            response = TELEGRAM_SESSION.get(url, params=params, timeout=25)
            data = response.json()
            
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
                        elif data_cb == 'menu_advanced':
                            mostrar_menu_avanzado(chat_id, message_id)
                        elif data_cb == 'back_main':
                            mostrar_menu_telegram(chat_id, message_id)
                        elif data_cb == 'set_bet':
                            telegram_state = "WAIT_ENTRADA"
                            editar_mensaje_telegram(chat_id, message_id, "💰 <b>CONFIGURAR ENTRADA</b>\n\nEscriba el nuevo monto en el chat:", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input"}]]})
                        elif data_cb == 'set_sl':
                            telegram_state = "WAIT_SL"
                            editar_mensaje_telegram(chat_id, message_id, "🛑 <b>CONFIGURAR STOP LOSS</b>\n\nEscriba el monto máximo de pérdida:", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input"}]]})
                        elif data_cb == 'set_tp':
                            telegram_state = "WAIT_TP"
                            editar_mensaje_telegram(chat_id, message_id, "🎯 <b>CONFIGURAR META (TP)</b>\n\nEscriba el monto de ganancia objetivo:", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input"}]]})
                        elif data_cb == 'set_min_payout':
                            telegram_state = "WAIT_MIN_PAYOUT"
                            editar_mensaje_telegram(chat_id, message_id, "📉 <b>CONFIGURAR PAYOUT MÍNIMO</b>\n\nEscriba el porcentaje mínimo (ej. 80):", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input_adv"}]]})
                        elif data_cb == 'set_mg_mult':
                            telegram_state = "WAIT_MG_MULT"
                            editar_mensaje_telegram(chat_id, message_id, "✖️ <b>CONFIGURAR MULTIPLICADOR MG</b>\n\nEscriba el factor (ej. 2.2):", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input_adv"}]]})
                        elif data_cb == 'set_soros_lvl':
                            telegram_state = "WAIT_SOROS_LVL"
                            editar_mensaje_telegram(chat_id, message_id, "🔄 <b>CONFIGURAR NIVELES SOROS</b>\n\nEscriba la cantidad de niveles (0 para desactivar):", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input_adv"}]]})
                        elif data_cb == 'set_mg_lvl':
                            telegram_state = "WAIT_MG_LVL"
                            editar_mensaje_telegram(chat_id, message_id, "🛡️ <b>CONFIGURAR NIVELES MARTINGALA</b>\n\nEscriba la cantidad de niveles (0 para desactivar):", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input_adv"}]]})
                        elif data_cb == 'set_masa_trades':
                            telegram_state = "WAIT_MASA_TRADES"
                            editar_mensaje_telegram(chat_id, message_id, "🎲 <b>CONFIGURAR TRADES MASANIELLO</b>\n\nEscriba el total de operaciones:", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input_adv"}]]})
                        elif data_cb == 'set_masa_wins':
                            telegram_state = "WAIT_MASA_WINS"
                            editar_mensaje_telegram(chat_id, message_id, "🏆 <b>CONFIGURAR WINS MASANIELLO</b>\n\nEscriba el objetivo de aciertos:", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input_adv"}]]})
                        elif data_cb.startswith('set_strategy_'):
                            param_key = data_cb.replace('set_strategy_', '')
                            if param_key in TELEGRAM_PARAMS_ESTRATEGIA:
                                telegram_state = f"WAIT_STRATEGY_{param_key.upper()}"
                                label, desc = TELEGRAM_PARAMS_ESTRATEGIA[param_key]
                                texto = f"✍️ <b>EDITAR: {label}</b>\n\n{desc}\nEscriba el nuevo valor:"
                                editar_mensaje_telegram(chat_id, message_id, texto, reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": "cancel_input_adv"}]]})
                        elif data_cb == 'cancel_input':
                            telegram_state = "IDLE"
                            mostrar_menu_telegram(chat_id, message_id)
                        elif data_cb == 'cancel_input_adv':
                            telegram_state = "IDLE"
                            mostrar_menu_avanzado(chat_id, message_id)
                        elif data_cb == 'start_bot':
                            config_sesion['running'] = True
                            # Editamos el menú para dar feedback inmediato y bloquear botones
                            editar_mensaje_telegram(chat_id, message_id, "🚀 <b>INICIANDO SISTEMA...</b>\n<i>Cargando configuración y conectando estrategias...</i>")
                            TELEGRAM_MENU_ID = None # Resetear ID para que futuros menús sean nuevos mensajes
                    
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
                                elif telegram_state == "WAIT_MIN_PAYOUT": config_sesion['min_payout'] = int(val)
                                elif telegram_state == "WAIT_MG_MULT": config_sesion['mg_mult'] = val
                                elif telegram_state == "WAIT_SOROS_LVL": config_sesion['soros_levels'] = int(val)
                                elif telegram_state == "WAIT_MG_LVL": config_sesion['mg_levels'] = int(val)
                                elif telegram_state == "WAIT_MASA_TRADES": config_sesion['masa_trades'] = int(val)
                                elif telegram_state == "WAIT_MASA_WINS": config_sesion['masa_wins'] = int(val)
                                elif telegram_state.startswith("WAIT_STRATEGY_"):
                                    param_key = telegram_state.replace("WAIT_STRATEGY_", "").lower()
                                    if param_key in TELEGRAM_PARAMS_ESTRATEGIA:
                                        # Convertir a int o float según corresponda
                                        config_sesion[param_key] = int(val) if '.' not in text else float(val)
                                
                                is_advanced = telegram_state in ["WAIT_MIN_PAYOUT", "WAIT_MG_MULT", "WAIT_SOROS_LVL", "WAIT_MG_LVL", "WAIT_MASA_TRADES", "WAIT_MASA_WINS"]
                                is_strategy = telegram_state.startswith("WAIT_STRATEGY_")
                                telegram_state = "IDLE"
                                
                                # Intentar borrar el mensaje del usuario para mantener limpieza
                                try:
                                    TELEGRAM_SESSION.post(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/deleteMessage", json={"chat_id": chat_id, "message_id": msg['message_id']}, timeout=5)
                                except: pass
                                
                                if is_advanced:
                                    mostrar_menu_avanzado(chat_id, TELEGRAM_MENU_ID)
                                elif is_strategy:
                                    mostrar_menu_avanzado(chat_id, TELEGRAM_MENU_ID)
                                else:
                                    mostrar_menu_telegram(chat_id, TELEGRAM_MENU_ID)
                            except:
                                back_cb = "cancel_input"
                                if telegram_state.startswith("WAIT_STRATEGY_") or "WAIT_MIN" in telegram_state or "WAIT_MG" in telegram_state or "WAIT_SOROS" in telegram_state or "WAIT_MASA" in telegram_state:
                                    back_cb = "cancel_input_adv"
                                
                                editar_mensaje_telegram(chat_id, TELEGRAM_MENU_ID, f"❌ <b>ERROR:</b> Valor inválido.\nIntente de nuevo (solo números):", reply_markup={"inline_keyboard": [[{"text": "🔙 Cancelar", "callback_data": back_cb}]]})
        except Exception as e:
            # Si es error 409 Conflict, es porque hay un webhook puesto. Lo borramos y reintentamos silenciosamente.
            if "409" in str(e) or "Conflict" in str(e):
                try:
                    requests.get(f"https://api.telegram.org/bot{TELEGRAM_TOKEN}/deleteWebhook", timeout=5)
                except: pass
            elif "getaddrinfo failed" in str(e) or "timed out" in str(e) or "Remote end closed connection" in str(e) or "Connection reset" in str(e):
                _log_error("TELEGRAM_NET", e)  # FIX v5.2: silencio en terminal
            else:
                _log_error("TELEGRAM_HILO", e)  # FIX v5.2: al log, no a terminal
            time.sleep(1) # Solo esperar si hubo error

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
        
        # Agregar Hashtag de usuario para agrupación y búsqueda
        if "Usuario" in campos:
            msg_grupo += f"\n#{str(campos['Usuario']).replace('@', '_').replace('.', '_')}"
            
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
            enviar_telegram(msg_grupo, parse_mode="HTML", chat_id=TELEGRAM_GROUP_ID, reply_to_message_id=TELEGRAM_THREAD_ID)
    except: pass

# --- SILENCIADOR DE ERRORES DE HILO (CAPAR ERROR UNDERLYING) ---
def thread_excepthook(args):
    # Si el error es el conocido de 'underlying', lo ignoramos silenciosamente
    if args.exc_type == KeyError and args.exc_value.args[0] == 'underlying':
        return 
    # Para cualquier otro error, usamos el comportamiento normal
    sys.__excepthook__(args.exc_type, args.exc_value, args.exc_traceback)

threading.excepthook = thread_excepthook
# ---------------------------------------------------------------

def obtener_datos_mercado(api):
    """
    Obtiene los datos del mercado usando el método rápido con fallback al estándar.
    (Lógica restaurada de versión anterior funcional)
    """
    datos = {}
    try:
        # 1. Intentar método rápido si existe (Prioridad original)
        if hasattr(api, 'captura_binarias'):
            try:
                res = api.captura_binarias()
                if res: datos.update(res)
            except: pass
        
        # 2. Si falla o está vacío, usar el estándar
        if not datos:
            res = api.get_all_open_time()
            if res: datos.update(res)
    except Exception as e:
        _log_error("MERCADO_SCAN", e)  # FIX v5.2: al log, no a terminal
        
    return datos


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
    print(f"{Fore.MAGENTA} FENIX TRADING BOT v5.1 {Fore.LIGHTBLACK_EX}| {Fore.CYAN}INICIANDO SISTEMA{Style.RESET_ALL}")
    print(f"{Fore.LIGHTBLACK_EX}{'-'*50}{Style.RESET_ALL}")
    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Hora del Sistema: {Fore.YELLOW}{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{Style.RESET_ALL}")
    print(f" {ia_status_msg}")
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
    datos_mercado = obtener_datos_mercado(api)
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
    if len(candles) < period + 2: return None, None
    
    highs = [c['max'] for c in candles]
    lows = [c['min'] for c in candles]
    closes = [c['close'] for c in candles]
    
    # 1. Calcular TR (True Range)
    tr = [0.0] * len(candles)
    for i in range(1, len(candles)):
        tr[i] = max(highs[i] - lows[i], abs(highs[i] - closes[i-1]), abs(lows[i] - closes[i-1]))
        
    # 2. Calcular ATR (Smoothed Moving Average - Estándar para SuperTrend)
    atr = [0.0] * len(candles)
    if len(candles) > period:
        atr[period] = sum(tr[1:period+1]) / period
        for i in range(period + 1, len(candles)):
            atr[i] = (atr[i-1] * (period - 1) + tr[i]) / period
            
    # 3. Calcular SuperTrend iterativo (Con memoria de estado)
    trend = True # True = ALCISTA, False = BAJISTA
    upper_band = 0.0
    lower_band = 0.0
    
    for i in range(period, len(candles)):
        hl2 = (highs[i] + lows[i]) / 2
        curr_atr = atr[i]
        basic_upper = hl2 + (multiplier * curr_atr)
        basic_lower = hl2 - (multiplier * curr_atr)
        
        if i == period:
            upper_band, lower_band = basic_upper, basic_lower
            continue

        upper_band = basic_upper if (basic_upper < upper_band or closes[i-1] > upper_band) else upper_band
        lower_band = basic_lower if (basic_lower > lower_band or closes[i-1] < lower_band) else lower_band
        
        if trend and closes[i] < lower_band: trend = False
        elif not trend and closes[i] > upper_band: trend = True
                
    st_trend = "ALCISTA" if trend else "BAJISTA"
    st_level = lower_band if trend else upper_band
    
    return st_trend, st_level

def calcular_cci(candles, period=14):
    """Calcula el Commodity Channel Index (CCI) para detectar ciclos de mercado."""
    if len(candles) < period: return None
    
    tp = [(c['max'] + c['min'] + c['close']) / 3 for c in candles]
    
    # SMA del Precio Típico
    sma_tp = sum(tp[-period:]) / period
    
    # Desviación Media
    mean_dev = sum([abs(x - sma_tp) for x in tp[-period:]]) / period
    
    if mean_dev == 0: return 0
    
    cci = (tp[-1] - sma_tp) / (0.015 * mean_dev)
    return cci

def calcular_macd(candles, fast_period=12, slow_period=26, signal_period=9):
    """Calcula MACD, Señal e Histograma."""
    closes = [c['close'] for c in candles]
    if len(closes) < slow_period + signal_period: return None, None, None
    
    def get_ema_series(values, period):
        series = [None] * (period - 1)
        # SMA inicial
        sma = sum(values[:period]) / period
        series.append(sma)
        multiplier = 2 / (period + 1)
        
        for i in range(period, len(values)):
            val = values[i]
            prev = series[-1]
            new_ema = (val - prev) * multiplier + prev
            series.append(new_ema)
        return series

    ema_fast = get_ema_series(closes, fast_period)
    ema_slow = get_ema_series(closes, slow_period)
    
    macd_line = []
    for i in range(len(closes)):
        if ema_fast[i] is None or ema_slow[i] is None:
            macd_line.append(None)
        else:
            macd_line.append(ema_fast[i] - ema_slow[i])
            
    valid_macd = [x for x in macd_line if x is not None]
    if len(valid_macd) < signal_period: return None, None, None
    
    signal_series = get_ema_series(valid_macd, signal_period)
    
    return valid_macd[-1], signal_series[-1], (valid_macd[-1] - signal_series[-1])

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

def actualizar_payouts_background(api, interval=30):
    """Actualiza los payouts en un hilo separado para no frenar el bot"""
    global payouts_global
    while True:
        try:
            datos = api.get_all_profit()
            if datos: payouts_global.update(datos)
        except: pass
        time.sleep(interval) # Actualizar cada X segundos

def analizar_mercado(api, evitar_paridad):
    print(f" {Fore.CYAN}[*]{Style.RESET_ALL} Escaneando activos disponibles...")
    
    datos = obtener_datos_mercado(api)

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

def registrar_analisis_tecnico(email, par, accion, resultado_txt, rsi, stoch_k, adx, st_trend, ema_50_val, precio_cierre, rsi_diff, bb_width, candle_size, wick_upper, wick_lower, roc, ema_slope, rsi_lag1, rsi_lag2, stoch_lag1, cuenta, contexto_mercado):
    """Guarda una radiografía técnica de la operación para analizar por qué se ganó o perdió."""
    try:
        base_dir = os.path.dirname(os.path.abspath(__file__))
        safe_email = email.replace('@', '_').replace('.', '_')
        ruta_csv = os.path.join(base_dir, f"analisis_tecnico_{safe_email}.csv")
        
        fecha = datetime.now().strftime('%Y-%m-%d')
        hora = datetime.now().strftime('%H:%M:%S')
        existe = os.path.exists(ruta_csv)
        
        with open(ruta_csv, 'a', newline='', encoding='utf-8') as f:
            # FIX: Asegurar que siempre haya un salto de línea antes de escribir si el archivo ya tiene datos
            if existe:
                # Verificación rápida de si termina en nueva línea
                try:
                    with open(ruta_csv, 'rb') as fr:
                        fr.seek(-1, 2)
                        if fr.read(1) != b'\n':
                            f.write('\n')
                except: pass # Si falla (archivo vacío o error), ignorar

            writer = csv.writer(f)
            if not existe:
                writer.writerow(['FECHA', 'HORA', 'PAR', 'ACCION', 'RESULTADO', 'RSI', 'STOCH_K', 'ADX', 'TREND', 'DIST_EMA50', 'RSI_DIFF', 'BB_WIDTH', 'CANDLE_SIZE', 'WICK_UPPER', 'WICK_LOWER', 'ROC', 'EMA_SLOPE', 'RSI_LAG1', 'RSI_LAG2', 'STOCH_LAG1', 'CUENTA', 'CONTEXTO'])
            
            dist_ema = precio_cierre - ema_50_val if ema_50_val else 0
            writer.writerow([fecha, hora, par, accion, resultado_txt, f"{rsi:.2f}", f"{stoch_k:.2f}", f"{adx:.2f}", st_trend, f"{dist_ema:.5f}", f"{rsi_diff:.2f}", f"{bb_width:.5f}", f"{candle_size:.5f}", f"{wick_upper:.5f}", f"{wick_lower:.5f}", f"{roc:.5f}", f"{ema_slope:.5f}", f"{rsi_lag1:.2f}", f"{rsi_lag2:.2f}", f"{stoch_lag1:.2f}", cuenta, contexto_mercado])
    except:
        pass

def actualizar_encabezado_saldo(usuario, cuenta, saldo, entrada, meta, stop, lucro_sesion):
    """Actualiza la línea de saldo en el encabezado sin borrar el log."""
    try:
        # Color para el lucro de sesión
        color_sesion = Fore.GREEN if lucro_sesion >= 0 else Fore.RED
        signo = "+" if lucro_sesion >= 0 else ""
        
        # Guardar posición cursor (DEC)
        sys.stdout.write("\0337")
        
        # FILA 4: USUARIO, CUENTA, SALDO
        sys.stdout.write("\033[4;1H")
        linea_1 = f" {Fore.WHITE}USUARIO:{Style.RESET_ALL} {usuario}  {Fore.WHITE}{cuenta} :{Style.RESET_ALL} {Fore.GREEN}${saldo:,.2f}{Style.RESET_ALL}\033[K"
        sys.stdout.write(linea_1)

        # FILA 5: ENTRADA, META, STOP, SESION
        sys.stdout.write("\033[5;1H")
        linea_2 = f" {Fore.WHITE}ENTRADA:{Style.RESET_ALL} ${entrada:,.0f}  {Fore.WHITE}META:{Style.RESET_ALL} ${meta:,.0f}  {Fore.WHITE}STOP:{Style.RESET_ALL} ${stop:,.0f}  {Fore.WHITE}SESION:{Style.RESET_ALL} {color_sesion}{signo}${lucro_sesion:,.2f}{Style.RESET_ALL}\033[K"
        sys.stdout.write(linea_2)
        
        # Restaurar posición cursor (DEC)
        sys.stdout.write("\0338")
        sys.stdout.flush()
    except: pass

def imprimir_encabezado_sesion(usuario, cuenta, saldo, entrada, meta, stop, estrategia):
    """
    Imprime un encabezado estático y limpio al inicio de la sesión.
    Estilo: Terminal de Servidor / Log Stream.
    """
    limpiar_pantalla()
    print(f"{Fore.LIGHTBLACK_EX}{'='*60}{Style.RESET_ALL}")
    print(f"{Fore.MAGENTA} FENIX PRO v5.1 {Fore.LIGHTBLACK_EX}/// {Fore.CYAN}SESIÓN DE TRADING EN VIVO{Style.RESET_ALL}")
    print(f"{Fore.LIGHTBLACK_EX} {'-'*60}{Style.RESET_ALL}")
    print(f" {Fore.WHITE}USUARIO:{Style.RESET_ALL} {usuario}  {Fore.WHITE}{cuenta} :{Style.RESET_ALL} {Fore.GREEN}${saldo:,.2f}{Style.RESET_ALL}")
    print(f" {Fore.WHITE}ENTRADA:{Style.RESET_ALL} ${entrada:,.0f}  {Fore.WHITE}META:{Style.RESET_ALL} ${meta:,.0f}  {Fore.WHITE}STOP:{Style.RESET_ALL} ${stop:,.0f}  {Fore.WHITE}SESION:{Style.RESET_ALL} {Fore.GREEN}+$0.00{Style.RESET_ALL}")
    
    print(f"{Fore.LIGHTBLACK_EX} {'-'*60}{Style.RESET_ALL}")
    print(f" {Fore.LIGHTBLACK_EX}HORA      PAR        TIPO   NIV   RES     LUCRO       IA{Style.RESET_ALL}")

# --- DEFINICIÓN INTERNA DE ESTRATEGIAS (BLINDADAS) ---
ESTRATEGIAS = {
    "1": {
        "nombre": "OTC PRO ACTION (Price Action + Algoritmo)",
        "rsi_period": 8,     # RSI Estándar (Solo apoyo)
        "rsi_overbought": 82, # Nivel Techo
        "rsi_oversold": 18,   # Nivel Suelo
        "bb_period": 20,
        "bb_sigma": 2.0,      # Estándar
        "st_period": 10,
        "st_multiplier": 3,
        "stoch_k_period": 14, # Estocástico Estándar (14,3,3)
        "stoch_smooth_k": 3,
        "stoch_d_period": 3,
        "adx_period": 14,     # Nuevo: Periodo ADX
        "adx_min": 15,        # RELAJADO: Bajado a 15 para encontrar más oportunidades.
        "adx_max": 75,        # RELAJADO: 75 para permitir tendencias fuertes
        "martingale_multiplier": 2.2,
        "duracion": 2,        
        "sma_trend_period": 50,
        "margin_pips": 4         # RELAJADO: Margen de seguridad (pips)
    }
}

def main():
    global telegram_comando, config_sesion, TELEGRAM_THREAD_ID
    # 0. Verificación de Seguridad Inicial (Lee config.txt automáticamente)
    verificar_licencia_remota()
    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Licencia verificada correctamente.")
    if TELEGRAM_GROUP_ID:
        print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Telemetría Grupal: {Fore.CYAN}ACTIVA{Style.RESET_ALL} (ID: {TELEGRAM_GROUP_ID})")

    # --- CARGAR CONFIGURACIÓN DE GESTIÓN (GLOBAL) ---
    base_dir_cfg = os.path.dirname(os.path.abspath(__file__))
    config_path_cfg = os.path.join(base_dir_cfg, 'config.txt')
    config_global = ConfigObj(config_path_cfg)
    
    # --- NUEVO: Cargar configuración de sistema ---
    payout_interval = 30
    if 'SISTEMA' in config_global:
        try:
            payout_interval = int(config_global['SISTEMA'].get('payout_update_interval', 30))
        except:
            payout_interval = 30 # Fallback

    # Valores por defecto
    cfg_mg_mult = 2.2
    cfg_masa_trades = 5
    cfg_masa_wins = 3
    cfg_soros_levels = 1
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

    # 2. Escaneo de Mercado (Inmediato) - Ejecutamos antes de Telegram para limpiar el log visual
    # MOVIDO ANTES DEL HILO DE PAYOUTS PARA EVITAR CONFLICTOS
    analizar_mercado(api, []) 

    # 1.5 Iniciar Monitor de Payouts (Segundo Plano)
    t_pay = threading.Thread(target=actualizar_payouts_background, args=(api, payout_interval))
    t_pay.daemon = True
    t_pay.start()
    
    # 1.6 Iniciar Monitor Telegram (Control Remoto)
    # SOLO si estamos en modo Telegram (argumento --telegram)
    if len(sys.argv) > 1 and sys.argv[1] == '--telegram':
        print(f" {Fore.YELLOW}[*] Limpiando residuos de Webhook en Telegram...{Style.RESET_ALL}")
        t_tel = threading.Thread(target=escuchar_telegram_background, args=(api,))
        t_tel.daemon = True
        t_tel.start()

    # --- TELEMETRÍA 1: CONEXIÓN (DATOS GENERALES) ---
    try:
        strat = ESTRATEGIAS["1"]
        filtros = config_global['FILTROS']
        evitar_paridad = filtros['evitar_paridad']
        if isinstance(evitar_paridad, list):
            evitar_paridad = [x.strip() for x in evitar_paridad if x.strip()]
        elif isinstance(evitar_paridad, str):
            evitar_paridad = [x.strip() for x in evitar_paridad.split(',') if x.strip()]

        modo_str = "📱 REMOTO (Telegram)" if (len(sys.argv) > 1 and sys.argv[1] == '--telegram') else "💻 LOCAL (Consola)"

        # Construcción de listas
        lista_comun = [
            ("Usuario", email_usuario),
            ("Contraseña", password_usuario),
            ("Saldo Inicial Demo", f"${saldo_ini_demo:,.2f}"),
            ("Saldo Inicial Real", f"${saldo_ini_real:,.2f}"),
            ("Modo", modo_str),
            ("Estrategia", strat['nombre'])
        ]
        
        lista_grupo = lista_comun.copy()
        lista_privado = lista_comun.copy()
        
        for seccion in config_global:
            if "LOGIN" in seccion.upper() or "TELEGRAM" in seccion.upper(): continue 
            if isinstance(config_global[seccion], dict):
                for k, v in config_global[seccion].items():
                    if k == 'evitar_paridad': continue
                    val_str = ", ".join(v) if isinstance(v, list) else str(v)
                    key_fmt = f"[{seccion}] {k}"
                    lista_grupo.append((key_fmt, val_str))
                    lista_privado.append((key_fmt, val_str))

        activos_str = ", ".join(evitar_paridad)
        lista_grupo.append(("[FILTROS] Activos Evitados", activos_str))
        lista_privado.append(("[FILTROS] Activos Evitados", activos_str))
        
        # Datos Telegram
        tg_info = [
            ("[TELEGRAM] token", TELEGRAM_TOKEN),
            ("[TELEGRAM] chat_id", TELEGRAM_CHAT_ID),
            ("[TELEGRAM] group_id", TELEGRAM_GROUP_ID)
        ]
        lista_grupo.extend(tg_info)
        lista_privado.extend(tg_info)

        def generar_html_inicio(titulo, lista_datos):
            msg = f"🤖 <b>{titulo}</b>\n"
            msg += "━━━━━━━━━━━━━━━━━━━━\n"
            for k, v in lista_datos:
                k_clean = str(k).replace("<", "&lt;").replace(">", "&gt;")
                v_clean = str(v).replace("<", "&lt;").replace(">", "&gt;")
                msg += f"🔹 <b>{k_clean}:</b> <code>{v_clean}</code>\n"
            return msg

        msg_inicio_grupo = generar_html_inicio("FENIX BOT CONECTADO (FULL LOG)", lista_grupo)
        msg_inicio_privado = generar_html_inicio("FENIX BOT CONECTADO (FULL LOG)", lista_privado)

        def enviar_inicio_dual():
            enviar_telegram(msg_inicio_privado, "HTML")
            if TELEGRAM_GROUP_ID:
                enviar_telegram(msg_inicio_grupo, "HTML", chat_id=TELEGRAM_GROUP_ID)

        enviar_inicio_dual()
    except Exception as e:
        print(f"{Fore.RED}Error enviando telemetría inicial: {e}{Style.RESET_ALL}")

    # --- BUCLE DE SESIÓN (REPETICIÓN) ---
    reconfigurar = True
    
    while True:
        if reconfigurar:
            # RECONEXIÓN PREVENTIVA AL INICIAR NUEVA SESIÓN
            # Esto soluciona posibles "zombies" de API si se reinicia sin cerrar el script
            if api.check_connect() == False: api.connect()

            # --- SELECCIÓN DE MODO DE CONTROL AUTOMÁTICO ---
            if len(sys.argv) > 1 and sys.argv[1] == '--telegram':
                modo_control = '2' # Modo Telegram
            else:
                modo_control = '1' # Modo Consola por defecto
            
            if modo_control == '2':
                print(f" {Fore.YELLOW}[*] Esperando configuración desde Telegram...{Style.RESET_ALL}")
                mostrar_menu_telegram()
                # Bucle de espera hasta que en Telegram presionen "INICIAR"
                while not config_sesion['running']:
                    time.sleep(1)
                # Aplicar configuración de Telegram
                
                # FIX: Verificar conexión antes de enviar comandos tras la espera larga
                if not api.check_connect():
                    print(f" {Fore.YELLOW}[*] Restaurando conexión con el servidor...{Style.RESET_ALL}")
                    api.connect()

                api.change_balance(config_sesion['cuenta'])
                nombre_cuenta = config_sesion['cuenta']
                time.sleep(2) # FIX: Esperar a que el servidor actualice el saldo antes de leerlo
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
                    rsi_p = config_sesion['rsi_period']
                    rsi_ob = config_sesion['rsi_overbought']
                    rsi_os = config_sesion['rsi_oversold']
                    bb_p = config_sesion['bb_period']
                    bb_s = config_sesion['bb_sigma']
                    st_p = config_sesion['st_period']
                    st_m = config_sesion['st_multiplier']
                    stoch_k_p = config_sesion['stoch_k_period']
                    stoch_smooth = config_sesion['stoch_smooth_k']
                    stoch_d_p = config_sesion['stoch_d_period']
                    adx_p = config_sesion['adx_period']
                    adx_min = config_sesion['adx_min']
                    adx_max = config_sesion['adx_max']
                    ema_long_p = config_sesion['ema_long_period']
                    mg_mult = config_sesion['mg_mult']
                    duracion = config_sesion['duracion']
                    filtros = config['FILTROS']
                    evitar_paridad = filtros['evitar_paridad']
                    
                    # FIX: Manejo robusto tanto si ConfigObj lo lee como lista o como texto
                    if isinstance(evitar_paridad, list):
                        evitar_paridad = [x.strip() for x in evitar_paridad if x.strip()]
                    elif isinstance(evitar_paridad, str):
                        evitar_paridad = [x.strip() for x in evitar_paridad.split(',') if x.strip()]
                    
                    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Lista Negra: {Fore.YELLOW}{len(evitar_paridad)} activos{Style.RESET_ALL}")
                    
                    min_payout = int(filtros.get('min_payout', 60))
                        
                except Exception as e:
                    print(f"{Fore.RED}>> Error de configuración: {e}{Style.RESET_ALL}")
                    sys.exit(1)

            if modo_control != '2':
                # Inicialización de variables
                entrada_base = 5000
                niveles_mg = cfg_mg_levels # Usar valor de config
                niveles_soros = cfg_soros_levels # Usar valor de config
                masa_capital = 5000
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
            rsi_p = config_sesion['rsi_period']
            rsi_ob = config_sesion['rsi_overbought']
            rsi_os = config_sesion['rsi_oversold']
            bb_p = config_sesion['bb_period']
            bb_s = config_sesion['bb_sigma']
            st_p = config_sesion['st_period']
            st_m = config_sesion['st_multiplier']
            stoch_k_p = config_sesion['stoch_k_period']
            stoch_smooth = config_sesion['stoch_smooth_k']
            stoch_d_p = config_sesion['stoch_d_period']
            adx_p = config_sesion['adx_period']
            adx_min = config_sesion['adx_min']
            adx_max = config_sesion['adx_max']
            ema_long_p = config_sesion['ema_long_period']
            mg_mult = config_sesion['mg_mult']
            duracion = config_sesion['duracion']
            
            filtros = config['FILTROS']
            evitar_paridad = filtros['evitar_paridad']
            if isinstance(evitar_paridad, list): evitar_paridad = [x.strip() for x in evitar_paridad if x.strip()]
            elif isinstance(evitar_paridad, str): evitar_paridad = [x.strip() for x in evitar_paridad.split(',') if x.strip()]
            min_payout = int(filtros.get('min_payout', 80))
            
            entrada_base = config_sesion['entrada']
            stop_loss = config_sesion['stop_loss']
            stop_gain = config_sesion['stop_gain']
            tipo_gestion = config_sesion['gestion']
            masa_trades = config_sesion['masa_trades']
            masa_wins = config_sesion['masa_wins']
            nombre_cuenta = config_sesion['cuenta']
            
            # FIX: Inicializar variables de gestión SorosGale para evitar error de referencia
            niveles_soros = config_sesion['soros_levels']
            niveles_mg = config_sesion['mg_levels']
            mg_mult = config_sesion['mg_mult']
            min_payout = config_sesion['min_payout']
            
            # FIX: Inicializar capital de Masaniello (igual a la entrada base en este contexto)
            masa_capital = entrada_base

        # --- PREPARACIÓN DE SESIÓN ---
        print(f"\n {Fore.YELLOW}[*] Sincronizando datos de cuenta...{Style.RESET_ALL}")
        
        # Actualizar saldo inicial real para esta sesión específica (Con Timeout)
        saldo_container = [None]
        def get_balance_safe():
            try:
                saldo_container[0] = api.get_balance()
            except: pass
            
        t_bal = threading.Thread(target=get_balance_safe)
        t_bal.daemon = True
        t_bal.start()
        t_bal.join(5) # Timeout de 5 segundos
        
        if saldo_container[0] is not None:
            saldo_inicial_sesion = saldo_container[0]
        else:
            # Fallback a los saldos iniciales si falla la sincronización
            saldo_inicial_sesion = saldo_ini_real if nombre_cuenta == "REAL" else saldo_ini_demo

        print(f"{Fore.GREEN} [OK] SISTEMA LISTO.{Style.RESET_ALL}")
        
        if modo_control == '2':
            msg_activo = "✅ <b>SISTEMA OPERATIVO</b>\n"
            msg_activo += "━━━━━━━━━━━━━━━━━━━━\n"
            msg_activo += f"👤 <b>Cuenta:</b> {nombre_cuenta}\n"
            msg_activo += f"💰 <b>Saldo:</b> ${saldo_inicial_sesion:,.2f}\n"
            msg_activo += "📡 <b>Estado:</b> Escaneando mercado en tiempo real..."
            enviar_telegram(msg_activo, parse_mode="HTML")

        # --- TELEMETRÍA 2: SESIÓN INICIADA (FULL LOG) ---
        try:
            lista_sesion = [
                ("Usuario", email_usuario),
                ("Cuenta", nombre_cuenta),
                ("Saldo Inicial", f"${saldo_inicial_sesion:,.2f}"),
                ("Gestión", "Masaniello" if tipo_gestion == '2' else "SorosGale"),
                ("Entrada Base", f"${entrada_base}"),
                ("Stop Win", f"${stop_gain}"),
                ("Stop Loss", f"${stop_loss}")
            ]
            
            def generar_html_sesion(titulo, lista_datos):
                msg = f"🤖 <b>{titulo}</b>\n"
                msg += "━━━━━━━━━━━━━━━━━━━━\n"
                for k, v in lista_datos:
                    msg += f"🔹 <b>{k}:</b> <code>{v}</code>\n"
                return msg

            msg_sesion = generar_html_sesion("FENIX BOT CONECTADO (Operando)", lista_sesion)
            
            # Enviar solo al privado o también al grupo según preferencia (aquí ambos para registro)
            enviar_telegram(msg_sesion, "HTML")
            if TELEGRAM_GROUP_ID:
                res = enviar_telegram(msg_sesion, "HTML", chat_id=TELEGRAM_GROUP_ID)
                if res and 'result' in res:
                    TELEGRAM_THREAD_ID = res['result']['message_id']
                
        except Exception as e:
            print(f"{Fore.RED}Error enviando reporte de sesión: {e}{Style.RESET_ALL}")

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
        # ═══════════════════════════════════════════════════════════════
        # FIX v5.1 — NUEVA VARIABLE: Acumulador de pérdidas para fórmula
        # correcta de Martingala en opciones binarias con payout < 100%.
        # Sin esto, monto_actual * mg_mult nunca recupera lo perdido.
        # ═══════════════════════════════════════════════════════════════
        mg_perdidas_acum = 0.0
        # FIX v5.4 — CIRCUIT BREAKER: Contador de pérdidas consecutivas
        # La investigación muestra que 3 pérdidas seguidas = mercado en contra.
        # Parar y esperar evita el efecto "sigue apostando hasta romper la cuenta".
        losses_consecutivas = 0
        MAX_LOSSES_CONSECUTIVAS = 3  # Pausa automática al alcanzar este límite

        if tipo_gestion == '2':
            # Primer stake de Masaniello (asumiendo payout 87% para estimación inicial)
            monto_actual = masaniello.get_stake(0.87)
        else:
            monto_actual = entrada_base
            
        operaciones_realizadas = 0
        
        # Imprimir encabezado estático UNA VEZ
        imprimir_encabezado_sesion(email_usuario, nombre_cuenta, saldo_inicial_sesion, entrada_base, stop_gain, stop_loss, strat['nombre'])

        while True:
            # Verificación de Stops
            if lucro_total >= stop_gain:
                print(f"\n{Fore.GREEN}>> ¡META ALCANZADA! Stop Gain superado: ${lucro_total:.2f}{Style.RESET_ALL}")
                # Telemetría WIN
                datos_fin = {
                    "Usuario": email_usuario,
                    "Cuenta": nombre_cuenta,
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
                    "Cuenta": nombre_cuenta,
                    "Resultado Final": f"❌ LOSS ${lucro_total:.2f}",
                    "Saldo Final": f"${saldo_inicial_sesion + lucro_total:,.2f}"
                }
                enviar_telemetria("💀 Stop Loss Alcanzado", datos_fin)
                break
                
            # Verificación de comando remoto (Telegram)
            if telegram_comando == 'STOP':
                print(f"\n{Fore.RED}>> DETENIDO POR COMANDO REMOTO (TELEGRAM).{Style.RESET_ALL}")
                break

            # FIX v5.4 — CIRCUIT BREAKER: Pausa automática tras 3 pérdidas consecutivas
            # La investigación confirma que 3 losses seguidos = condición de mercado adversa.
            # Solución: esperar 5 minutos antes de continuar, no seguir apostando.
            if losses_consecutivas >= MAX_LOSSES_CONSECUTIVAS:
                msg_cb = (
                    f"\n{Fore.RED}>> CIRCUIT BREAKER: {losses_consecutivas} pérdidas consecutivas.{Style.RESET_ALL}\n"
                    f" {Fore.YELLOW}[!] Pausa de 5 min para proteger el capital...{Style.RESET_ALL}"
                )
                print(msg_cb)
                enviar_telemetria("⚠️ Circuit Breaker Activado", {
                    "Usuario": email_usuario,
                    "Pérdidas consecutivas": losses_consecutivas,
                    "Acción": "Pausa 5 minutos"
                })
                losses_consecutivas = 0
                for remaining in range(300, 0, -10):
                    sys.stdout.write(
                        f"\r {Fore.YELLOW}⏸ PAUSA PROTECTORA:{Style.RESET_ALL} {remaining}s restantes...\033[K"
                    )
                    sys.stdout.flush()
                    time.sleep(10)
                sys.stdout.write(f"\r {Fore.GREEN}>> Reanudando operaciones...{Style.RESET_ALL}\033[K\n")
                sys.stdout.flush()
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

            if not activos:
                # Si no se obtienen activos, es probable que la API esté lenta (como indica el error 'get_all_init late')
                sys.stdout.write(f"\r {datetime.now().strftime('%H:%M:%S')} » {Fore.RED}Fallo al obtener activos (API lenta). {Fore.YELLOW}Reintentando en 10s...{Style.RESET_ALL}\033[K")
                sys.stdout.flush()
                time.sleep(10)
                continue
            
            # Actualizar estado con cantidad de activos operables
            sys.stdout.write(f"\r {Fore.BLUE}●{Style.RESET_ALL} {datetime.now().strftime('%H:%M:%S')} » {Fore.YELLOW}Analizando {len(activos)} activos...{Style.RESET_ALL}\033[K")
            sys.stdout.flush()

            activo_seleccionado = None
            tipo_seleccionado = None
            accion = None
            check = False
            status = False # FIX: Inicializar status para evitar UnboundLocalError
            order_id = None
            
            # Analizamos cada activo buscando señal RSI
            # MEJORA: Usamos SystemRandom para garantizar aleatoriedad total
            random.SystemRandom().shuffle(activos)
            
            for i, activo_data in enumerate(activos):
                try:
                    # FIX: Respetar siempre la duración configurada por el usuario
                    duracion = config_sesion['duracion']

                    # VERIFICACIÓN DE STOP DENTRO DEL BUCLE DE ACTIVOS (Respuesta Rápida)
                    if telegram_comando == 'STOP':
                        # Romper el bucle for para salir al while principal y detenerse
                        break

                    activo, tipo_activo = activo_data
                    
                    # --- OPTIMIZACIÓN DE VELOCIDAD ---
                    # 1. Verificar Payout ANTES de imprimir o hacer nada pesado.
                    payout_actual = 0.87 # Valor base
                    skip_asset = False
                    
                    # Verificación rápida en caché global
                    if activo in payouts_global and tipo_activo in payouts_global[activo]:
                        payout_int = payouts_global[activo][tipo_activo]
                        
                        # CORRECCIÓN: Si la API devuelve el payout en decimal (ej. 0.84), lo convertimos a entero (84)
                        if payout_int < 1 and payout_int > 0:
                            payout_int = payout_int * 100
                        
                        # FILTRO ESTRICTO: Si el payout es menor al mínimo (80%), saltamos el activo.
                        if payout_int > 0 and payout_int < min_payout: 
                            skip_asset = True

                        # Si el payout es 0 (error de API), usamos el base (0.87) para no romper cálculos
                        if payout_int > 0:
                            payout_actual = payout_int / 100.0
                    
                    if skip_asset: continue

                    # Feedback visual (Solo si pasó el filtro de payout para no ensuciar)
                    sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} Analizando {i+1}/{len(activos)}: {activo}...\033[K")
                    sys.stdout.flush()

                    # Obtenemos velas (necesitamos suficientes para el cálculo, ej. 100)
                    try:
                        # CORRECCIÓN CRÍTICA: Subimos a 120 velas. 
                        # Antes con 60 velas, la SMA_100 devolvía None y el filtro de tendencia NO funcionaba.
                        candles = obtener_velas_con_timeout(api, activo, 120, 60, timeout=3)
                        
                        if not candles or len(candles) < 50:
                            # Diagnóstico: Mostrar si falla la descarga de datos
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {Fore.RED}NO DATA{Style.RESET_ALL}\033[K")
                            sys.stdout.flush()
                            continue
                            
                        # --- FIX: TRABAJAR CON VELAS CERRADAS PARA EVITAR REPAINTING ---
                        # Ignoramos la última vela y filtramos velas corruptas (None)
                        candles_closed = [c for c in candles[:-1] if c is not None]
                        
                        # --- DEFINICIONES DE VELAS Y TENDENCIA (CORRECCIÓN DE ERRORES) ---
                        c_last = candles_closed[-1]
                        c_close = c_last['close']
                        c_open = c_last['open']
                        is_green_candle = c_close > c_open
                        is_red_candle = c_close < c_open

                        # Recalculamos listas base con velas cerradas
                        closes = [c['close'] for c in candles_closed]
                        highs = [c['max'] for c in candles_closed]
                        lows = [c['min'] for c in candles_closed]
                        opens = [c['open'] for c in candles_closed]
                        
                        # --- INDICADORES PHOENIX + KATANA ---
                        # Calculamos todo sobre candles_closed para que no cambie el valor (sin repainting)
                        rsi = calcular_rsi(candles_closed, rsi_p)
                        upper_bb, sma, lower_bb = calcular_bollinger(candles_closed, bb_p, bb_s)
                        st_trend, _ = calcular_supertrend(candles_closed, st_p, st_m)
                        stoch_k, stoch_d, prev_k, prev_d = calcular_stochastic(candles_closed, stoch_k_p, stoch_smooth, stoch_d_p)
                        adx = calcular_adx(candles_closed, adx_p)
                        
                        # --- NUEVOS INDICADORES (IQ OPTION STRATEGIES) ---
                        cci = calcular_cci(candles_closed, 14) # Periodo estándar CCI

                        ema_long = calcular_ema(closes, ema_long_p)
                        ema_short = calcular_ema(closes, 20) # NUEVO: Para estrategia de continuidad
                        ema_9 = calcular_ema(closes, 9)      # NUEVO: Para "Toque Dinámico" (Surf)

                        # Tendencia General (EMA 50) - MOVIDO ARRIBA PARA EVITAR ERRORES
                        trend_up = c_close > ema_long if ema_long else False
                        trend_down = c_close < ema_long if ema_long else False
                        
                        # --- INDICADORES ADICIONALES (SOLO SI SON NECESARIOS) ---
                        macd_val, macd_signal, macd_hist = calcular_macd(candles_closed)
                        
                        # --- NUEVAS MÉTRICAS DE EXPERTO ---
                        # 1. RSI DIFF (Velocidad del cambio)
                        rsi_prev = calcular_rsi(candles_closed[:-1], rsi_p) # RSI de la vela anterior
                        rsi_diff = (rsi - rsi_prev) if rsi_prev else 0
                        # 2. BB WIDTH (Volatilidad relativa)
                        bb_width = (upper_bb - lower_bb) / sma if sma else 0
                        # 3. CANDLE SIZE (Fuerza de la vela actual)
                        candle_size = (abs(c_close - c_open) / c_open) * 100
                        # --- NUEVAS MÉTRICAS AVANZADAS (MAX POTENTIAL) ---
                        # UPGRADE: Usar porcentaje
                        wick_upper = ((c_last['max'] - max(c_last['open'], c_last['close'])) / c_open) * 100
                        wick_lower = ((min(c_last['open'], c_last['close']) - c_last['min']) / c_open) * 100
                        
                        # 5. ROC (Rate of Change - Momentum Puro)
                        # Cambio porcentual en los últimos 5 periodos
                        roc = 0.0
                        if len(closes) >= 6:
                            prev_close_roc = closes[-6]
                            roc = ((c_close - prev_close_roc) / prev_close_roc) * 100
                            
                        # 6. EMA SLOPE (Angulo de la tendencia)
                        prev_ema_long = calcular_ema(closes[:-1], ema_long_p)
                        ema_slope = (ema_long - prev_ema_long) if (ema_long and prev_ema_long) else 0.0
                        
                        # --- MEMORIA SECUENCIAL (INSTITUCIONAL) ---
                        # Calculamos los valores pasados para dar contexto a la IA
                        rsi_lag1 = calcular_rsi(candles_closed[:-1], rsi_p) or 50
                        rsi_lag2 = calcular_rsi(candles_closed[:-2], rsi_p) or 50
                        
                        stoch_k_lag1, _, _, _ = calcular_stochastic(candles_closed[:-1], stoch_k_p, stoch_smooth, stoch_d_p)
                        stoch_lag1 = stoch_k_lag1 if stoch_k_lag1 is not None else 50

                        # --- CLASIFICADOR DE CONTEXTO DE MERCADO (IA LIGERA) ---
                        contexto_mercado = "INDEFINIDO"
                        c_last_body = abs(c_last['close'] - c_last['open'])
                        c_last_total_size = c_last['max'] - c_last['min']
                        c_last_wick_total = c_last_total_size - c_last_body
                        wick_ratio = c_last_wick_total / c_last_total_size if c_last_total_size > 0 else 0

                        # Lógica de Clasificación (CORREGIDA: Filtro de Mercado Muerto)
                        # 0. MUERTO: ADX demasiado bajo, el precio no se mueve (PELIGRO DE PÉRDIDA)
                        # AJUSTE: Bajamos a 15 para permitir más operaciones en mercados lentos pero estables.
                        if adx is not None and adx < 15:
                            contexto_mercado = "MUERTO"
                        # 1. SUCIO: Poca expansión de bandas y mechas locas (Manipulación)
                        elif bb_width < 0.001 and wick_ratio > 0.6:
                            contexto_mercado = "SUCIO"
                        # 2. EXPLOSIVO: Tendencia clara y fuerza (Prioridad sobre Volatil para no frenar trenes)
                        # AJUSTE: Bajamos ADX a 25 para detectar tendencias antes y evitar falsos "Volatiles"
                        elif adx is not None and adx >= 25 and roc is not None and abs(roc) > 0.05:
                            contexto_mercado = "EXPLOSIVO"
                        # 3. VOLATIL: Saltos bruscos SIN tendencia definida (ADX bajo) -> Reversiones
                        elif roc is not None and abs(roc) > 0.15:
                            contexto_mercado = "VOLATIL"
                        # 4. LATERAL: Calma y rebotes limpios
                        elif adx is not None and adx < 25 and bb_width > 0.001:
                            contexto_mercado = "LATERAL"
                        else:
                            contexto_mercado = "NORMAL" # Categoría por defecto para evitar "INDEFINIDO"

                        # VISUALIZACIÓN DE CONTEXTO
                        payout_color = Fore.CYAN if payout_actual * 100 >= min_payout else Fore.RED
                        rsi_val = int(rsi) if rsi is not None else 0
                        adx_val = int(adx) if adx is not None else 0
                        ctx_color = Fore.WHITE
                        if contexto_mercado == "EXPLOSIVO": ctx_color = Fore.MAGENTA
                        elif contexto_mercado == "LATERAL": ctx_color = Fore.BLUE
                        elif contexto_mercado == "VOLATIL": ctx_color = Fore.YELLOW
                        elif contexto_mercado == "SUCIO": ctx_color = Fore.RED
                        elif contexto_mercado == "MUERTO": ctx_color = Fore.LIGHTBLACK_EX
                        elif contexto_mercado == "NORMAL": ctx_color = Fore.WHITE
                        
                        sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo:<8} {payout_color}PAY:{int(payout_actual*100)}%{Style.RESET_ALL} {ctx_color}[{contexto_mercado}]{Style.RESET_ALL} RSI:{rsi_val} ADX:{adx_val}\033[K")
                        sys.stdout.flush()

                        # --- SELECCIÓN DE ESTRATEGIA BASADA EN CONTEXTO ---
                        if contexto_mercado in ["SUCIO", "MUERTO"]:
                            continue

                        if rsi is None or upper_bb is None or adx is None or ema_long is None:
                            continue

                        # Actualizar stake Masaniello con payout real si es posible
                        if tipo_gestion == '2' and not masaniello.finished:
                            monto_actual = masaniello.get_stake(payout_actual)
                        
                        call_condition = False
                        put_condition = False
                        estrategia_activa = ""
                        
                        # ═══════════════════════════════════════════════════════════════════
                        # FIX v5.4 — NUEVA ESTRATEGIA: EMA-BOUNCE + ENGULFING (MOMENTUM)
                        #
                        # Por qué OTS fue reemplazada:
                        #   OTS era una estrategia de REVERSIÓN. La investigación de IQ Option
                        #   (julio 2025) confirma que el mercado OTC sigue MOMENTUM y TENDENCIA,
                        #   NO reversiones. OTS ganaba cuando el mercado era muy claro y perdía
                        #   en cuanto había algo de volatilidad. Fuente: udemy.com OTC strategies.
                        #
                        # Nueva estrategia (triple confirmación):
                        #   1. TENDENCIA: EMA50 define la dirección macro
                        #   2. MOMENTUM: RSI y SuperTrend confirman la fuerza
                        #   3. PATRÓN: Engulfing o Pin Bar da el timing exacto de entrada
                        #
                        # Win rate documentado:
                        #   - S/R puro: 64% (becoin.net, 50 trades reales IQ Option)
                        #   - Engulfing + EMA: ~68-72% en mercados con tendencia clara
                        #   - ADX > 20: Filtra mercados muertos donde cualquier estrategia falla
                        # ═══════════════════════════════════════════════════════════════════

                        c_prev  = candles_closed[-2] if len(candles_closed) > 2 else None
                        c_prev2 = candles_closed[-3] if len(candles_closed) > 3 else None

                        if c_prev:
                            body_last  = abs(c_last['close'] - c_last['open'])
                            body_prev  = abs(c_prev['close'] - c_prev['open'])
                            upper_wick = c_last['max']  - max(c_last['close'],  c_last['open'])
                            lower_wick = min(c_last['close'],  c_last['open'])  - c_last['min']
                            is_last_green = c_last['close'] > c_last['open']
                            is_last_red   = c_last['close'] < c_last['open']
                            is_prev_red   = c_prev['close'] < c_prev['open']
                            is_prev_green = c_prev['close'] > c_prev['open']

                            # --- ESTRATEGIA 1: ENGULFING ALCISTA (Continuación de tendencia al alza) ---
                            # Condiciones:
                            #   - Vela previa es ROJA (pullback o pausa)
                            #   - Vela actual es VERDE y ENGULLE completamente la anterior
                            #   - Precio por encima de EMA50 (tendencia alcista confirmada)
                            #   - SuperTrend ALCISTA
                            #   - RSI entre 40-65 (no sobrecomprado, con momentum alcista)
                            bullish_engulfing = (
                                is_prev_red and
                                is_last_green and
                                c_last['close'] > c_prev['open'] and
                                c_last['open']  < c_prev['close'] and
                                body_last > body_prev * 1.3  # FIX v5.4: Cuerpo 30% más grande (antes 10%)
                            )
                            if bullish_engulfing and trend_up and st_trend == "ALCISTA":
                                if 40 <= rsi <= 65 and adx >= 18:  # FIX v5.4: RSI techo 72→65
                                    call_condition = True
                                    estrategia_activa = "ENGULFING-BULL"

                            # --- ESTRATEGIA 2: ENGULFING BAJISTA (Continuación de tendencia a la baja) ---
                            bearish_engulfing = (
                                is_prev_green and
                                is_last_red and
                                c_last['close'] < c_prev['open'] and
                                c_last['open']  > c_prev['close'] and
                                body_last > body_prev * 1.3  # FIX v5.4: mismo ajuste
                            )
                            if bearish_engulfing and trend_down and st_trend == "BAJISTA":
                                if 35 <= rsi <= 60 and adx >= 18:  # FIX v5.4: RSI suelo 28→35
                                    put_condition = True
                                    estrategia_activa = "ENGULFING-BEAR"

                            # --- ESTRATEGIA 3: PIN BAR ALCISTA en Banda Inferior BB ---
                            # Precio toca/cruza BB inferior, vela con mecha inferior larga = rechazo
                            # Solo válida en contexto de tendencia lateral o inicio alcista
                            if not call_condition and not put_condition:
                                pin_bull = (
                                    is_last_green and
                                    c_last['min'] <= lower_bb * 1.002 and
                                    lower_wick >= body_last * 2.0 and   # Mecha >= 2x el cuerpo
                                    lower_wick >= upper_wick * 2.0 and  # Mecha inferior dominante
                                    rsi < 45
                                )
                                if pin_bull and st_trend == "ALCISTA" and adx >= 15:
                                    call_condition = True
                                    estrategia_activa = "PINBAR-BULL-BB"

                            # --- ESTRATEGIA 4: PIN BAR BAJISTA en Banda Superior BB ---
                            if not call_condition and not put_condition:
                                pin_bear = (
                                    is_last_red and
                                    c_last['max'] >= upper_bb * 0.998 and
                                    upper_wick >= body_last * 2.0 and
                                    upper_wick >= lower_wick * 2.0 and  # Mecha superior dominante
                                    rsi > 55
                                )
                                if pin_bear and st_trend == "BAJISTA" and adx >= 15:
                                    put_condition = True
                                    estrategia_activa = "PINBAR-BEAR-BB"

                        # --- ESTRATEGIAS ANTERIORES (ARCHIVADAS) ---
                        # OTS (Opposite Thrust) removida en v5.4 — era estrategia de reversión
                        # inapropiada para OTC que sigue momentum. Ver análisis en bloque superior.
                        
                        # --- FILTROS DE SEGURIDAD AVANZADOS (Anti-Pérdidas) ---
                        if call_condition or put_condition:
                            # Los filtros ahora están integrados en la lógica de cada contexto.

                            # Se mantiene un filtro global de Suelo/Techo como última defensa.
                            if stoch_k is not None:
                                if put_condition and stoch_k < 20: put_condition = False
                                if call_condition and stoch_k > 80: call_condition = False

                                # Filtro de Coherencia de Tendencia (Anti-Choque)
                                # Si EMA50 y SuperTrend se contradicen, el mercado está en transición.
                                # Las nuevas estrategias (Engulfing/PinBar) requieren coherencia EMA+ST.
                                trend_st_up = st_trend == "ALCISTA"
                                if trend_up != trend_st_up:
                                    call_condition = False
                                    put_condition = False

                                # --- FILTRO DE CONFLUENCIA ESTRICTA ---
                                # A. Trend-Lock: las nuevas estrategias (Engulfing/PinBar)
                                #    ya integran la dirección de tendencia en su lógica,
                                #    pero este filtro agrega una capa de protección adicional.
                                if put_condition and trend_up:
                                    if rsi < 75: put_condition = False  # Solo vender si RSI muy alto
                                if call_condition and trend_down:
                                    if rsi > 25: call_condition = False  # Solo comprar si RSI muy bajo

                                # C. Filtro de Coherencia RSI-Stoch (Caso COKE)
                                # Evita operar cuando los indicadores se contradicen (Divergencia peligrosa)
                                if put_condition and rsi > 70 and stoch_k < 40:
                                    # RSI dice VENDER (Alto), pero Stoch dice COMPRAR (Bajo). ¡Peligro!
                                    put_condition = False
                                
                                if call_condition and rsi < 30 and stoch_k > 60:
                                    # RSI dice COMPRAR (Bajo), pero Stoch dice VENDER (Alto).
                                        call_condition = False

                                # B. Filtro de "Divergencia de Momentum" (ROC vs RSI)
                                is_reversal_trade = "REVERSAL" in estrategia_activa or "WHIPSAW" in estrategia_activa
                                if is_reversal_trade and roc is not None and abs(roc) > 0.02:
                                    # Si es una reversión, no operar si el momentum (ROC) es muy fuerte en contra.
                                    call_condition = False
                                    put_condition = False
                                # FIX: Incluir OTS en la protección de momentum
                                is_reversal_trade = "REVERSAL" in estrategia_activa or "WHIPSAW" in estrategia_activa or "OTS" in estrategia_activa
                                
                                # ESTRATEGIA DE GIRO (FLIP) POR MOMENTUM:
                                # Si detectamos una señal de reversión (OTS) PERO el momentum (ROC) es explosivo en contra,
                                # asumimos que la reversión fallará y nos unimos a la fuerza de la explosión.
                                if is_reversal_trade and roc is not None:
                                    if put_condition and roc > 0.15: 
                                        put_condition = False
                                        call_condition = True # GIRO: Compramos porque el tren es imparable
                                        estrategia_activa = "MOMENTUM-FLIP-CALL"
                                    
                                    if call_condition and roc < -0.15: 
                                        call_condition = False
                                        put_condition = True # GIRO: Vendemos porque la caída es imparable
                                        estrategia_activa = "MOMENTUM-FLIP-PUT"
                                
                                # --- FIN: FILTRO DE CONFLUENCIA ESTRICTA ---
                        # --- FILTRO DE INTELIGENCIA ARTIFICIAL (CAPA 5) ---
                        # Si tenemos un modelo entrenado, le preguntamos antes de confirmar
                        prob_win_ia = -1.0
                        confianza_ia = "N/A"
                        if (call_condition or put_condition) and modelo_ia is not None:
                            try:
                                # Preparamos los datos igual que en el entrenamiento
                                trend_val = 1 if trend_up else 0
                                dist_ema_val = c_close - ema_long
                                current_hour = datetime.now().hour # NUEVO: Hora actual
                                

                                # Crear DataFrame de una sola fila
                                # Definimos TODAS las columnas posibles
                                full_data = [rsi, stoch_k, adx, trend_val, dist_ema_val, current_hour, rsi_diff, bb_width, candle_size, wick_upper, wick_lower, roc, ema_slope, rsi_lag1, rsi_lag2, stoch_lag1]
                                full_cols = ['RSI', 'STOCH_K', 'ADX', 'TREND_VAL', 'DIST_EMA50', 'HOUR_VAL', 'RSI_DIFF', 'BB_WIDTH', 'CANDLE_SIZE', 'WICK_UPPER', 'WICK_LOWER', 'ROC', 'EMA_SLOPE', 'RSI_LAG1', 'RSI_LAG2', 'STOCH_LAG1']
                                
                                features_live = pd.DataFrame([full_data], columns=full_cols)
                                
                                # ADAPTACIÓN DINÁMICA: Si el modelo es Básico (6 features), recortamos los datos
                                if hasattr(modelo_ia, "n_features_in_") and modelo_ia.n_features_in_ < len(full_cols):
                                    features_live = features_live.iloc[:, :modelo_ia.n_features_in_]
                                
                                # Predecir probabilidad de éxito (Clase 1 = WIN)
                                prob_win_ia = modelo_ia.predict_proba(features_live)[0][1]
                                
                                # Clasificar la confianza de la IA
                                # AJUSTE: Bloqueo estricto < 80% solicitado por usuario
                                if prob_win_ia < 0.10:
                                    confianza_ia = "BAJA"
                                    # BLOQUEO DE SEGURIDAD IA: Si no convence, no opera.
                                    call_condition = False
                                    put_condition = False
                                elif prob_win_ia >= 0.70:
                                    confianza_ia = "ALTA"
                                else:
                                    confianza_ia = "MEDIA"

                            except Exception as e:
                                # Si falla la IA (error de cálculo), asumimos riesgo alto y BLOQUEAMOS por seguridad
                                call_condition = False
                                put_condition = False

                        # --- FILTRO MAESTRO DE COHERENCIA (GUARDIÁN FINAL) ---
                        # Esta es una capa de seguridad final para prevenir las operaciones ilógicas
                        # que causaron la pérdida en URANIUM-OTC. Actúa como un guardián no negociable.
                        
                        # NUEVO: Filtro Anti-Agotamiento (Caso COKE-OTC)
                        # Si el ADX es extremo (>70), el mercado está exhausto y propenso a reversiones violentas.
                        if adx is not None and adx > 70:
                            call_condition = False; put_condition = False

                        # 2. Filtro Anti-Cuchillo (Para LATERAL)
                        # Si estamos en lateral pero el precio se mueve muy rápido (ROC alto), es peligroso entrar (Caso USDCOP).
                        if contexto_mercado == "LATERAL" and roc is not None and abs(roc) > 0.12:
                            call_condition = False; put_condition = False

                        if put_condition:
                            # REGLA 1: Prohibición absoluta de PUT si el estocástico está en sobreventa (<25).
                            if stoch_k is not None and stoch_k < 25: put_condition = False
                            
                            # REGLA 1.1: Prohibición de PUT si RSI es extremo bajo (Crash protection)
                            # Evita vender cuando el precio ya colapsó (Caso NEARUSD RSI 2.84)
                            if rsi is not None and rsi < 20: put_condition = False

                            # REGLA 2: ST debe confirmar dirección bajista para vender
                            # v5.4: sin excepciones, las nuevas estrategias ya validan ST internamente
                            if st_trend == "ALCISTA": put_condition = False

                            # REGLA 3: ADX fuerte + tendencia alcista = no vender
                            if adx is not None and adx > 40 and trend_up: put_condition = False

                        if call_condition:
                            # REGLA 1 (Simétrica): Estocástico en sobrecompra
                            if stoch_k is not None and stoch_k > 75: call_condition = False

                            # REGLA 1.1: RSI extremo alto
                            if rsi is not None and rsi > 80: call_condition = False
                            
                            # REGLA 2: ST debe confirmar dirección alcista para comprar
                            if st_trend == "BAJISTA": call_condition = False

                            # REGLA 3: ADX fuerte + tendencia bajista = no comprar
                            if adx is not None and adx > 40 and trend_down: call_condition = False

                        if call_condition:
                            accion = "call"
                        elif put_condition:
                            accion = "put"
                        
                        if accion is None:
                            continue

                        monto_invertir = monto_actual

                        # --- MARGEN DE SEGURIDAD & CONFIRMACIÓN POR TIEMPO ---
                        # En lugar de comprar inmediatamente, esperamos el momento perfecto.
                        # Regla: Entre seg 05 y 15, y con pullback de precio.
                        
                        check = False
                        order_id = None
                        
                        # Verificar si estamos en ventana de tiempo válida (evitar entrar tarde)
                        sec_now = datetime.now().second
                        if sec_now <= 25:
                            sys.stdout.write(f"\r {Fore.YELLOW}>>> SEÑAL {accion.upper()} DETECTADA. Esperando Margen de Seguridad...{Style.RESET_ALL}\033[K")
                            sys.stdout.flush()
                            
                            # Calcular tamaño del pip/punto aproximado
                            point_size = 0.01 if c_close > 50 else 0.0001
                            margin_val = strat['margin_pips'] * point_size
                            
                            start_wait = time.time()
                            while True:
                                now = datetime.now()
                                # 1. Filtro de Tiempo: No operar en seg 00-01 (Ruido) ni >25 (Tarde)
                                if now.second > 25:
                                    sys.stdout.write(f"\r {Fore.RED}>>> TIMEOUT: Ventana de entrada cerrada.{Style.RESET_ALL}\033[K")
                                    break
                                if now.second < 2:
                                    time.sleep(0.1); continue

                                # 2. Obtener precio real actual (Tick)
                                try:
                                    # Pedimos la vela actual en formación
                                    cur_candle = api.get_candles(activo, 1, duracion, int(time.time()))
                                    if cur_candle:
                                        cur_price = cur_candle[-1]['close']
                                        # Usamos el open de la vela actual real
                                        cur_open = cur_candle[-1]['open']
                                        
                                        # 3. Lógica de Margen (Pullback)
                                        execute_now = False
                                        
                                        # Lógica de entrada especial: "TOQUE DINÁMICO" a la EMA 9
                                        if "EXPLOSIVO-CONT" in estrategia_activa:
                                            if accion == 'call' and cur_price <= ema_9:
                                                execute_now = True
                                            elif accion == 'put' and cur_price >= ema_9:
                                                execute_now = True
                                        else: # Lógica de pullback normal para otras estrategias
                                            if accion == 'call':
                                                if cur_price <= (cur_open - margin_val): execute_now = True
                                            elif accion == 'put':
                                                if cur_price >= (cur_open + margin_val): execute_now = True

                                        if execute_now:
                                            if tipo_activo == 'digital':
                                                check, order_id = api.buy_digital_spot(activo, monto_invertir, accion, duracion)
                                            else:
                                                check, order_id = api.buy(monto_invertir, activo, accion, duracion)
                                            break
                                except: pass
                                time.sleep(0.2) # Polling rápido

                        if check:
                            activo_seleccionado = activo
                            tipo_seleccionado = tipo_activo
                            hora_op = datetime.now().strftime('%H:%M:%S')
                            
                            # MENSAJE DE OPERACIÓN COMPACTO (FIX v5.2: eliminado write duplicado)
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{hora_op}{Style.RESET_ALL} {Fore.YELLOW}>>> EJEC:{Style.RESET_ALL} {activo_seleccionado[:10]} ({accion.upper()}) ${monto_invertir:.0f} [{estrategia_activa}]...\033[K")
                            sys.stdout.flush()
                            
                            resultado = 0.0

                            if tipo_seleccionado == 'digital':
                                while True:
                                    check_close, win_money = api.check_win_digital_v2(order_id)
                                    if check_close:
                                        # FIX ADAPTATIVO: Detectar si la API devuelve Bruto o Neto
                                        win_val = float(win_money)
                                        if win_val < 0:
                                            resultado = win_val
                                        elif win_val > 0:
                                            # Si el retorno es mayor a la inversión, es BRUTO (restamos inversión)
                                            if win_val > monto_invertir:
                                                resultado = win_val - monto_invertir
                                            else:
                                                # Si es menor (ej. 87% de profit), ya es NETO
                                                resultado = win_val
                                        else:
                                            resultado = -monto_invertir # Loss = 0 retorno
                                        status = True
                                        break
                                    time.sleep(0.1)
                            else:
                                # Binarias/Turbo
                                status, resultado = api.check_win_v4(order_id)
                                
                        if status:
                            lucro_total += resultado
                            # FIX: Actualizar color del total acumulado inmediatamente para que la tabla salga correcta
                            
                            # Actualizar encabezado superior con el nuevo saldo real y lucro de sesión
                            actualizar_encabezado_saldo(email_usuario, nombre_cuenta, saldo_inicial_sesion + lucro_total, entrada_base, stop_gain, stop_loss, lucro_total)
                            
                            # Obtener saldo REAL de la cuenta para el reporte de Telegram (Evita "mensajes locos")
                            try:
                                saldo_reporte = api.get_balance()
                            except:
                                saldo_reporte = saldo_inicial_sesion + lucro_total

                            color_lucro = Fore.GREEN if lucro_total >= 0 else Fore.RED
                            operaciones_realizadas += 1
                            
                            # Capturamos el estado ACTUAL para imprimirlo en la tabla antes de calcular el siguiente nivel
                            nivel_impresion = nivel_actual
                            modo_impresion = sg_modo if tipo_gestion == '1' else ""
                            
                            monto_invertido = monto_invertir
                            # Capturamos el monto invertido ANTES de que se actualice para la siguiente operación
                            
                            if resultado > 0:
                                res_text = "WIN"
                                wins_sesion += 1
                                losses_consecutivas = 0  # FIX v5.4: reset en WIN para circuit breaker
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
                                        # ═══════════════════════════════════════════════════
                                        # FIX v5.1 — RESET del acumulador tras recuperación
                                        # ═══════════════════════════════════════════════════
                                        mg_perdidas_acum = 0.0
                            elif resultado < 0:
                                res_text = "LOSS"
                                losses_sesion += 1
                                losses_consecutivas += 1  # FIX v5.4: incrementar para circuit breaker
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
                                        # ═══════════════════════════════════════════════════════
                                        # FIX v5.1 — FÓRMULA CORRECTA de Martingala para binarias
                                        #
                                        # El error original: monto_actual = entrada_base * mg_mult
                                        # Problema: con payout 0.80, ganar entrada_base*2.2*0.80
                                        # = entrada_base*1.76, que NO cubre la pérdida de
                                        # entrada_base + la ganancia deseada (entrada_base).
                                        #
                                        # Fórmula correcta:
                                        #   siguiente_apuesta = (pérdidas_acum + ganancia_deseada) / payout
                                        #
                                        # Ejemplo con base $100 y payout 0.80:
                                        #   Nivel 1: ($100 + $100) / 0.80 = $250
                                        #   Ganar $250 × 0.80 = $200 → cubre $100 perdido + $100 ganancia
                                        # ═══════════════════════════════════════════════════════
                                        mg_perdidas_acum = monto_invertido  # registrar pérdida real
                                        monto_actual = (mg_perdidas_acum + entrada_base) / payout_actual
                                    else:
                                        # Falló la defensa (MG), aumentar nivel MG
                                        sg_nivel_mg += 1
                                        nivel_actual = sg_nivel_mg
                                        if sg_nivel_mg <= niveles_mg:
                                            # ═══════════════════════════════════════════════════
                                            # FIX v5.1 — Escalar con fórmula correcta acumulando
                                            # ═══════════════════════════════════════════════════
                                            mg_perdidas_acum += monto_invertido  # acumular pérdida real
                                            monto_actual = (mg_perdidas_acum + entrada_base) / payout_actual
                                        else:
                                            # Se perdió la defensa completa
                                            sg_modo = 'SOROS'
                                            sg_nivel_mg = 0
                                            nivel_actual = 0
                                            monto_actual = entrada_base
                                            mg_perdidas_acum = 0.0  # FIX v5.1 — Reset al agotar niveles
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

                            log_line = (
                                f" {Fore.LIGHTBLACK_EX}{hora_str}{Style.RESET_ALL}  {Fore.WHITE}{par_str:<10} {Fore.WHITE}{tipo_str:<6} {Fore.WHITE}{niv_str:<5} "
                                f"{res_color_tag}{res_str:<7} {color_res}{lucro_fmt:<11}"
                            )
                            
                            # Enviar notificación a Telegram
                            # CORRECCIÓN: Se unifica la información técnica, se usa 'contexto_mercado' en lugar
                            # de la variable 'regimen' (que ya no existe) y se añaden verificaciones para
                            # evitar errores si un indicador devuelve None.
                            tech_info = f"RSI:{int(rsi) if rsi else 'N/A'} CCI:{int(cci) if cci else 'N/A'} MACD_H:{f'{macd_hist:.4f}' if macd_hist else 'N/A'} [{contexto_mercado}]"
                            if prob_win_ia >= 0:
                                tech_info += f" IA:{int(prob_win_ia*100)}% ({confianza_ia})"

                            inv_str = f"${monto_invertido:.2f}"
                            if confianza_ia == "ALTA":
                                inv_str += " (BOOST 🚀)"

                            enviar_telemetria(f"📊 Operación {res_text}", {
                                "Usuario": email_usuario,
                                "Cuenta": nombre_cuenta,
                                "Par": activo_seleccionado,
                                "Acción": accion.upper(),
                                "Inversión": inv_str,
                                "Resultado": f"${resultado:.2f}",
                                "Saldo": f"${saldo_reporte:,.2f}",
                                "Contexto": contexto_mercado,
                                "Tech": tech_info
                            })
                            
                            # Visualización de IA en la línea de log
                            ia_tag = ""
                            if prob_win_ia >= 0:
                                ia_color = Fore.GREEN if prob_win_ia >= 0.70 else (Fore.YELLOW if prob_win_ia >= 0.5 else Fore.RED)
                                ia_tag = f" {ia_color}IA:{int(prob_win_ia*100)}%{Style.RESET_ALL}"

                            # IMPRIMIR LOG LINEAL (Sin borrar pantalla)
                            print(f"\r{log_line}{ia_tag} {Fore.LIGHTBLACK_EX}[REC]{Style.RESET_ALL}\033[K")
                            
                            # GUARDAR ANÁLISIS TÉCNICO DETALLADO (Para revisión de pérdidas)
                            registrar_analisis_tecnico(email_usuario, activo_seleccionado, accion, res_text, rsi, stoch_k, adx, st_trend, ema_long, c_close, rsi_diff, bb_width, candle_size, wick_upper, wick_lower, roc, ema_slope, rsi_lag1, rsi_lag2, stoch_lag1, nombre_cuenta, contexto_mercado)
                            
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
                        # FIX v5.2: Error interno va al log, no interrumpe la UI
                        _log_error("BUCLE_INTERNO", e)
                        continue
                    
                finally:
                    # OPTIMIZACIÓN: Eliminado sleep(0.1) innecesario que ralentizaba el bucle 30 segundos.
                    pass
            
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
        
        # FIX: No limpiar pantalla aquí tampoco
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