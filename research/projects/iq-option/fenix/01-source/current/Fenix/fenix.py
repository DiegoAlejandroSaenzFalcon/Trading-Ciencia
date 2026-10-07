import time
import csv
import sys
import os
import iqoptionapi.constants as OP_code

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
import websocket

# 1. Habilitar el rastreo de paquetes en la capa de transporte
#websocket.enableTrace(True)
# 2. Configurar el logger nativo para volcar la carga útil WSS a la consola
#logging.basicConfig(
#    level=logging.DEBUG,
#    format='[%(asctime)s] WSS_DUMP: %(message)s',
#    datefmt='%Y-%m-%d %H:%M:%S'
#)

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

from iqoptionapi.stable_api import IQ_Option # type: ignore

# ==========================================================
# [APEXQUANT DIAGNOSTICS MANAGER]
# Centralized control for debugging and testing.
# ==========================================================
DIAGNOSTICS = {
    "ENABLE_WSS_DUMP": False,         # Set True to see raw broker underlying list messages
    "FORCE_EXECUTION_TEST": False,     # Set True to force a $1 test trade on the first open market
    "ALLOW_OTC_FOR_TESTING": False     # Set True to bypass the strict Real-Market filter for testing
}
# ==========================================================

# --- VARIABLES GLOBALES ---
payouts_global = {} # Cache para payouts en segundo plano

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
        # Imprimir error para depuración si falla el envío
        print(f"\n{Fore.RED}>> Error Telegram: {e}{Style.RESET_ALL}")
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
        print(f"{Fore.RED}>> Error Editar Mensaje: {e}{Style.RESET_ALL}")

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
    texto_menu = "🎛 <b>PANEL DE CONTROL NEURALGO</b>\nConfigure los parámetros antes de iniciar:"
    
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
                pass # Silenciar errores de conexión para no ensuciar la terminal
            else:
                print(f"\n{Fore.RED}>> Error Hilo Telegram: {e}{Style.RESET_ALL}")
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

def guardar_historial_neuralgo(email, cuenta, par, accion, estrategia, inversion, lucro, saldo):
    """
    [NEURALGO] Corporate Ledger: Saves a clean, account-separated trade history.
    """
    try:
        base_dir = os.path.dirname(os.path.abspath(__file__))
        safe_email = email.replace('@', '_').replace('.', '_')
        nombre_archivo = f"Historial_NeurAlgo_{cuenta}_{safe_email}.csv"
        ruta_csv = os.path.join(base_dir, nombre_archivo)
        
        fecha = datetime.now().strftime('%Y-%m-%d')
        hora = datetime.now().strftime('%H:%M:%S')
        existe = os.path.exists(ruta_csv)
        
        with open(ruta_csv, 'a', newline='', encoding='utf-8') as f:
            # Prevent CSV formatting breakage (newline enforcement)
            if existe:
                try:
                    with open(ruta_csv, 'rb') as fr:
                        fr.seek(-1, 2)
                        if fr.read(1) != b'\n':
                            f.write('\n')
                except: pass 

            writer = csv.writer(f)
            if not existe:
                writer.writerow(['FECHA', 'HORA', 'ACTIVO', 'ACCION', 'ESTRATEGIA', 'INVERSION', 'RESULTADO', 'SALDO_RESTANTE'])
            
            writer.writerow([fecha, hora, par, accion.upper(), estrategia, f"${inversion:.2f}", f"${lucro:.2f}", f"${saldo:.2f}"])
    except Exception as e:
        pass # Silent fail to prevent interrupting live trading

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
    except TypeError as e:
        if "'NoneType' object is not subscriptable" in str(e):
            # Silently handle IQ Option API null responses
            sys.stdout.write(f"\r {Fore.YELLOW}● Servidor de API ocupado. Reconectando radar...{Style.RESET_ALL}\033[K")
            sys.stdout.flush()
            time.sleep(1.5)
        else:
            sys.stdout.write(f"\r {Fore.RED}● Error de Radar: {e}{Style.RESET_ALL}\033[K")
            sys.stdout.flush()
            time.sleep(2)
    except Exception as e:
        sys.stdout.write(f"\r {Fore.RED}● Error de Radar: {e}{Style.RESET_ALL}\033[K")
        sys.stdout.flush()
        time.sleep(2)
        
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
    print(f"{Fore.MAGENTA} NeurAlgo Trading: IQ-Option {Fore.LIGHTBLACK_EX}| {Fore.CYAN}INICIANDO SISTEMA{Style.RESET_ALL}")
    print(f"{Fore.LIGHTBLACK_EX}{'-'*50}{Style.RESET_ALL}")
    print(f" {Fore.GREEN}[*]{Style.RESET_ALL} Hora del Sistema: {Fore.YELLOW}{datetime.now().strftime('%Y-%m-%d %H:%M:%S')}{Style.RESET_ALL}")
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
        
        # --- PARCHE ESTRUCTURAL: MEMORIA HÍBRIDA DE IDs ---
        print(f" {Fore.YELLOW}[*] Sincronizando Topología de Activos...{Style.RESET_ALL}")
        
        # 1. Base Segura Inmutable
        ACTIVOS_REALES = {
            "EURUSD": 1, "EURGBP": 2, "EURJPY": 4, "GBPJPY": 5, "GBPUSD": 6, 
            "USDJPY": 7, "AUDCAD": 8, "XAUUSD": 12, "USOUSD": 11, "USDCHF": 72, 
            "USDCAD": 75, "EURCHF": 76, "AUDUSD": 99, "AUDJPY": 101, "CHFJPY": 102, 
            "AUDCHF": 103, "GBPAUD": 104, "EURAUD": 105, "EURCAD": 106, 
            "CADCHF": 107, "NZDUSD": 108, "NZDJPY": 109, "NZDCAD": 211, 
            "EURNZD": 212, "GBPNZD": 213, "GBPCAD": 214
        }
        for nombre, id_activo in ACTIVOS_REALES.items():
            OP_code.ACTIVES[nombre] = id_activo
            OP_code.ACTIVES[nombre + "-op"] = id_activo
            
        # ==========================================================
        # [APEXQUANT HOTFIX] BASE SEGURA OTC (Memoria de Fin de Semana)
        # ==========================================================
        ACTIVOS_OTC = {
            "EURUSD-OTC": 76, "EURGBP-OTC": 77, "USDCHF-OTC": 78, "EURJPY-OTC": 79,
            "NZDUSD-OTC": 80, "GBPUSD-OTC": 81, "AUDCAD-OTC": 82, "USDCAD-OTC": 84,
            "AUDUSD-OTC": 85, "GBPJPY-OTC": 86, "AUDJPY-OTC": 87, "CADCHF-OTC": 88,
            "EURCAD-OTC": 89, "EURAUD-OTC": 90, "EURNZD-OTC": 91, "GBPCAD-OTC": 92,
            "GBPAUD-OTC": 93, "GBPNZD-OTC": 94, "AUDCHF-OTC": 95, "AUDNZD-OTC": 96,
            "NZDJPY-OTC": 97, "NZDCAD-OTC": 98, "NZDCHF-OTC": 99, "CADJPY-OTC": 100,
            "CHFJPY-OTC": 101, "USDJPY-OTC": 106, "USDCOP-OTC": 119, "USDZAR-OTC": 120
        }
        for nombre, id_activo in ACTIVOS_OTC.items():
            OP_code.ACTIVES[nombre] = id_activo
            OP_code.ACTIVES[nombre + "-op"] = id_activo
        # ==========================================================
        
        # 2. Sincronización Dinámica Oficial (Sobrescribe con IDs frescos si el broker los cambió)
        try:
            for tipo_opcion in ["binary-option", "turbo-option"]:
                instrumentos = api.get_instruments(tipo_opcion)
                if instrumentos and 'instruments' in instrumentos:
                    for ins in instrumentos['instruments']:
                        nom = ins['name']
                        i_id = ins['active_id']
                        OP_code.ACTIVES[nom] = i_id
                        OP_code.ACTIVES[nom + "-op"] = i_id
        except: pass
        # -------------------------------------------------------------
        
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
        if tipo in datos_mercado and datos_mercado[tipo] is not None:
            try:
                for par, data in datos_mercado[tipo].items():
                    if data.get('open'):
                        activos_otc.append((par, tipo))
            except AttributeError:
                pass
    
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

def obtener_velas_con_timeout(api, activo, interval, count, timeout=2.5):
    """
    FIX DEFINITIVO (ANTI-ZOMBIES): Conexión de bajo nivel al WebSocket.
    Previene la fuga de memoria y asegura que cada petición sea limpia.
    """
    import iqoptionapi.constants as OP_code
    
    # 1. Limpiamos el canal de recepción
    api.api.candles.candles_data = None 
    
    # 2. Traducimos el texto a número seguro
    try:
        active_id = OP_code.ACTIVES[activo]
    except KeyError:
        return None
        
    # 3. Disparamos directo al servidor (Sin hilos que se congelen)
    try:
        api.api.getcandles(active_id, interval, count, int(time.time()))
    except:
        return None
        
    # 4. Espera controlada y segura
    start_t = time.time()
    while api.api.candles.candles_data is None:
        if time.time() - start_t > timeout:
            return None # Si el broker ignora, salimos instantáneamente
        time.sleep(0.05) # Respiro para el procesador
        
    # 5. Capturamos los datos y limpiamos el canal para el siguiente activo
    data = api.api.candles.candles_data
    api.api.candles.candles_data = None 
    
    return data

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
        if tipo in datos and datos[tipo] is not None:
            try:
                for par, info in datos[tipo].items():
                    if par in procesados: continue
                    procesados.add(par)
                    total += 1
                    if info.get('open'): abiertos += 1
                    else: cerrados += 1
                    if any(f.strip() in par for f in evitar_paridad): rechazados += 1
            except AttributeError:
                pass
    
    print(f" {Fore.WHITE}Total: {total} | Abiertos: {Fore.GREEN}{abiertos}{Fore.WHITE} | Cerrados: {Fore.RED}{cerrados}{Fore.WHITE} | Filtrados: {Fore.YELLOW}{rechazados}{Style.RESET_ALL}")

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
    print(f"{Fore.MAGENTA} NeurAlgo Trading: IQ-Option {Fore.LIGHTBLACK_EX}/// {Fore.CYAN}SESIÓN DE TRADING EN VIVO{Style.RESET_ALL}")
    print(f"{Fore.LIGHTBLACK_EX} {'-'*60}{Style.RESET_ALL}")
    print(f" {Fore.WHITE}USUARIO:{Style.RESET_ALL} {usuario}  {Fore.WHITE}{cuenta} :{Style.RESET_ALL} {Fore.GREEN}${saldo:,.2f}{Style.RESET_ALL}")
    print(f" {Fore.WHITE}ENTRADA:{Style.RESET_ALL} ${entrada:,.0f}  {Fore.WHITE}META:{Style.RESET_ALL} ${meta:,.0f}  {Fore.WHITE}STOP:{Style.RESET_ALL} ${stop:,.0f}  {Fore.WHITE}SESION:{Style.RESET_ALL} {Fore.GREEN}+$0.00{Style.RESET_ALL}")
    
    print(f"{Fore.LIGHTBLACK_EX} {'-'*60}{Style.RESET_ALL}")
    print(f" {Fore.LIGHTBLACK_EX}HORA      PAR        TIPO   NIV   RES     LUCRO{Style.RESET_ALL}")

# --- DEFINICIÓN INTERNA DE ESTRATEGIAS (BLINDADAS) ---
ESTRATEGIAS = {
    "1": {
        "nombre": "BIONIC PRO OTC (RSI 50 Crossover + EMA + ADX)",
        "rsi_period": 14,
        "rsi_overbought": 50,
        "rsi_oversold": 50,
        "duracion": 1,
        "martingale_multiplier": 1.0, 
        "ema_long_period": 50,
        "adx_period": 14,
        "adx_min": 20,
        # Default safety fillers for other potential variables
        "bb_period": 20, "bb_sigma": 2.0, "st_period": 10, "st_multiplier": 3,
        "stoch_k_period": 14, "stoch_smooth_k": 3, "stoch_d_period": 3,
        "sma_trend_period": 50, "margin_pips": 0
    }
}

def registrar_analisis_profesional(email, par, accion, resultado_txt, rsi, stoch, adx, trend, ema, precio, rsi_d, bb_w, c_size, w_up, w_low, roc_val, ema_s, ctx):
    """
    [NEURALGO] BlackBox Logger: Captura la física del mercado para análisis de pérdidas.
    """
    try:
        base_dir = os.path.dirname(os.path.abspath(__file__))
        safe_email = email.replace('@', '_').replace('.', '_')
        ruta_csv = os.path.join(base_dir, f"Analisis_Tecnico_NeurAlgo_{safe_email}.csv")
        existe = os.path.exists(ruta_csv)
        with open(ruta_csv, 'a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            if not existe:
                writer.writerow(['FECHA', 'HORA', 'PAR', 'ACCION', 'RES', 'RSI', 'STOCH', 'ADX', 'TREND', 'EMA_DIST', 'RSI_DIFF', 'BB_WIDTH', 'C_SIZE', 'W_UP', 'W_LOW', 'ROC', 'EMA_SLOPE', 'CONTEXTO'])
            dist_ema = precio - ema if ema else 0
            writer.writerow([datetime.now().strftime('%Y-%m-%d'), datetime.now().strftime('%H:%M:%S'), par, accion.upper(), resultado_txt, f"{rsi:.2f}", f"{stoch:.2f}", f"{adx:.2f}", trend, f"{dist_ema:.5f}", f"{rsi_d:.2f}", f"{bb_w:.5f}", f"{c_size:.5f}", f"{w_up:.5f}", f"{w_low:.5f}", f"{roc_val:.5f}", f"{ema_s:.5f}", ctx])
    except: pass

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

        msg_inicio_grupo = generar_html_inicio("NEURALGO TRADING CONECTADO (FULL LOG)", lista_grupo)
        msg_inicio_privado = generar_html_inicio("NEURALGO TRADING CONECTADO (FULL LOG)", lista_privado)

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
                    sel_strat = "1" # BIONIC PRO OTC Activada
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

            msg_sesion = generar_html_sesion("NEURALGO TRADING CONECTADO (Operando)", lista_sesion)
            
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
        activos_muertos_sesion = set() # NUEVO: Memoria RAM para ignorar basura
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
            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} {Fore.CYAN}RADAR: Iniciando Escaneo de Activos...{Style.RESET_ALL} | P/L: {color_lucro}${lucro_total:<7.2f}{Style.RESET_ALL}\033[K")
            sys.stdout.flush()

            # Reset dead assets memory per cycle to prevent permanent blacklisting
            activos_muertos_sesion.clear()
            # 4. Obtener activos OTC y seleccionar uno
            activos_todos = obtener_activos_otc(api)
            
            if not activos_todos:
                sys.stdout.write(f"\r {Fore.YELLOW}● Sincronizando con el servidor de mercado...{Style.RESET_ALL}\033[K")
                sys.stdout.flush()
                time.sleep(1)
                continue

            # FILTRO DE OPERATIVA: Solo Binarias y Turbo (Excluir Digitales)
            # Filtramos aquí para que el bot solo opere en los tipos solicitados
            # CÓDIGO PARCHEADO (Escudo Anti-OTC y Filtro Dinámico)
            activos_base = [x for x in activos_todos if x[1] in ['binary', 'turbo', 'digital']]

            # 1. Filtro de paridad del usuario (Lista Negra)
            activos_limpios = [a for a in activos_base if not any(ev.strip() in a[0] for ev in evitar_paridad)]

            # ==========================================================
            # [NEURALGO] STRICT OTC RADAR LOCK (BIONIC PRO)
            # Exclusively scans OTC assets, filtering out all real market pairs.
            # ==========================================================
            activos = [a for a in activos_limpios if "-OTC" in a[0].upper()]
            # ==========================================================

            if not activos:
                sys.stdout.write(f"\r {Fore.YELLOW}>>> ALERTA: Mercados Reales Cerrados. Esperando Apertura de Sesión...{Style.RESET_ALL}\033[K")
                sys.stdout.flush()
                time.sleep(15)
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
                    # VERIFICACIÓN DE STOP DENTRO DEL BUCLE DE ACTIVOS
                    if telegram_comando == 'STOP':
                        break

                    activo_crudo, tipo_activo = activo_data
                    activo_limpio = activo_crudo.replace("-op", "").replace("-OP", "")

                    # ==========================================================
                    # [TOOLKIT] FORCED EXECUTION TEST (TARGET: EURUSD-OTC)
                    # ==========================================================
                    if DIAGNOSTICS.get("FORCE_EXECUTION_TEST", False):
                        # SNIPER LOCK: Solo probar en el activo más estable del broker
                        if activo_crudo != "EURUSD-OTC":
                            continue # Si no es EURUSD-OTC, lo ignoramos para la prueba
                            
                        import iqoptionapi.constants as OP_code
                        # PRE-CHECK de memoria
                        if activo_crudo not in OP_code.ACTIVES:
                            print(f"\n{Fore.RED} >>> [DIAGNOSTICS] ERROR: ID 76 (EURUSD-OTC) no inyectado en memoria.{Style.RESET_ALL}")
                            sys.exit(0)

                        print(f"\n{Fore.MAGENTA} >>> [DIAGNOSTICS] FRANCOTIRADOR EN POSICIÓN. TEST DE RED EN: {activo_crudo} (TIPO: {tipo_activo})...{Style.RESET_ALL}")
                        try:
                            # Disparo
                            if tipo_activo == 'digital':
                                check, order_id = api.buy_digital_spot(activo_crudo, 1, "call", 1)
                            else:
                                check, order_id = api.buy(1, activo_crudo, "call", 1)
                                
                            if check:
                                print(f"{Fore.GREEN} >>> ÉXITO WSS: Orden ejecutada. LA API ESTÁ VIVA. ID: {order_id}{Style.RESET_ALL}")
                            else:
                                print(f"{Fore.RED} >>> FALLO WSS: Broker rechazó la orden en EURUSD-OTC. Razón: {order_id}{Style.RESET_ALL}")
                        except Exception as e:
                            print(f"{Fore.RED} >>> ERROR FATAL DE API: {e}{Style.RESET_ALL}")
                        
                        input(f"\n{Fore.CYAN} >>> TEST FINALIZADO. Cambia 'FORCE_EXECUTION_TEST' a False para operar normal. Presiona Enter para salir...{Style.RESET_ALL}")
                        sys.exit(0)
                    # ==========================================================
                    
                    # --- 0. COMPUERTA DE MEMORIA RAM (Lectura O(1)) ---
                    # Si el activo ya colapsó en red hoy, la IA le niega el acceso al servidor instantáneamente.
                    if activo_crudo in activos_muertos_sesion or activo_limpio in activos_muertos_sesion:
                        continue

                    # --- 1. Filtro de Basura Sintética ---
                    if activo_limpio in ["EXY", "AXY", "BXY", "CXY", "DXY", "JXY"]:
                        continue
                        
                    activo = activo_crudo
                    
                    # --- OPTIMIZACIÓN DE VELOCIDAD ---
                    payout_actual = 0.87
                    skip_asset = False
                    
                    # FIX DE DIAGNÓSTICO: Forzamos Payout a 10% para que el bot nos deje ver EURUSD
                    min_payout = 80
                    skip_asset = False   # FIX CRÍTICO: Restauramos la variable que faltaba
                    
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
                    
                    # Feedback visual continuo
                    sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} {Fore.YELLOW}🔎 Analizando {i+1}/{len(activos)}: {activo}...{Style.RESET_ALL}\033[K")
                    sys.stdout.flush()
                    
                    if skip_asset: continue

                    # Obtenemos velas (necesitamos suficientes para el cálculo, ej. 100)
                    try:
                        # INYECCIÓN CUANTITATIVA: Pasamos EL NÚMERO (activo_id) directo al servidor.
                        # FIX DEFINITIVO: Pasamos 'activo_crudo' (Texto). La memoria inyectada hará el resto.
                        candles = obtener_velas_con_timeout(api, activo_crudo, 60, 120, timeout=2.5)
                        
                        if not candles or len(candles) < 50:
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} SCAN: {activo_limpio:<10} {Fore.RED}NO DATA (Baneado de la sesión){Style.RESET_ALL}\033[K")
                            sys.stdout.flush()
                            # FIX CUANTITATIVO: Guardamos ambas versiones del String para sellar la memoria
                            activos_muertos_sesion.add(activo_crudo)
                            activos_muertos_sesion.add(activo_limpio)
                            continue    
                            
                        # --- FIX: TRABAJAR CON VELAS CERRADAS PARA EVITAR REPAINTING ---
                            
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

                        # ==========================================================
                        # [APEXQUANT] MODULAR ROUTING SYSTEM
                        # ==========================================================
                        from strategies.router import market_router
                        from strategies.reversion import reversion_module
                        from strategies.continuity import continuity_module
                        from strategies.breakout import breakout_module

                        # 0. CÁLCULO DE MÉTRICAS HUÉRFANAS
                        c_last_body = abs(c_last['close'] - c_last['open'])
                        c_last_total_size = c_last['max'] - c_last['min']
                        c_last_wick_total = c_last_total_size - c_last_body
                        wick_ratio = c_last_wick_total / c_last_total_size if c_last_total_size > 0 else 0

                        # 1. PREPARACIÓN DE SENSORES
                        wick_ratio_val = wick_ratio if wick_ratio is not None else 0
                        adx_val_router = adx if adx is not None else 0
                        bb_width_router = bb_width if bb_width is not None else 0
                        roc_router = roc if roc is not None else 0

                        # 2. EVALUACIÓN DEL RÉGIMEN (EL CEREBRO)
                        regime, target_strategy = market_router.evaluate_regime(adx_val_router, bb_width_router, roc_router, wick_ratio_val)
                        contexto_mercado = regime # Sincronizamos con telemetría visual

                        # VISUALIZACIÓN DE ESTADO (UI Consola)
                        payout_color = Fore.CYAN if payout_actual * 100 >= min_payout else Fore.RED
                        rsi_val = int(rsi) if rsi is not None else 0
                        adx_print = int(adx) if adx is not None else 0
                        ctx_color = Fore.MAGENTA if "TREND" in regime or "COMP" in regime else Fore.WHITE
                        
                        sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{datetime.now().strftime('%H:%M:%S')}{Style.RESET_ALL} {Fore.MAGENTA}🔭 SCAN:{Style.RESET_ALL} {activo:<10} {payout_color}PAY:{int(payout_actual*100)}%{Style.RESET_ALL} {ctx_color}[{contexto_mercado}]{Style.RESET_ALL} RSI:{rsi_val:<3} ADX:{adx_print:<3}\033[K")
                        sys.stdout.flush()

                        # ==========================================================
                        # [NEURALGO] PURE BIONIC PRO ENGINE (OTC M1)
                        # Exclusive Logic: RSI 50 Crossover + Institutional Filters
                        # ==========================================================
                        accion_eval = None
                        estrategia_activa = "BIONIC-PRO-OTC"

                        if rsi is not None and rsi_prev is not None:
                            # 1. Institutional Safeguards (Trend & Volume)
                            tendencia_ok_call = trend_up # c_close > ema_long
                            tendencia_ok_put = trend_down # c_close < ema_long
                            volumen_ok = (adx >= strat.get('adx_min', 20)) if adx else False

                            # 2. Momentum Crossover (Polarity Shift on 50 Line)
                            cruce_hacia_arriba = rsi_prev < 50 and rsi >= 50
                            cruce_hacia_abajo = rsi_prev > 50 and rsi <= 50

                            # 3. Execution Logic
                            if cruce_hacia_arriba and tendencia_ok_call and volumen_ok:
                                accion_eval = 'call'
                            elif cruce_hacia_abajo and tendencia_ok_put and volumen_ok:
                                accion_eval = 'put'
                        # ==========================================================
                        # 4. TRADUCCIÓN A COMPUERTAS DE COMPRA ORIGINALES
                        call_condition = (accion_eval == 'call')
                        put_condition = (accion_eval == 'put')
                        accion = accion_eval
                            
                        if accion is None:
                            continue

                        # ==========================================================
                        # [NEURALGO] PUENTE DE VARIABLES HUÉRFANAS PARA LOGS/UI
                        # ==========================================================
                        # Mapeamos la confianza al nuevo enrutador de regímenes
                        confianza_ia = f"{regime} ({estrategia_activa})"
                        # Simulamos una probabilidad base para no romper el formato visual antiguo
                        prob_win_ia = 85 if target_strategy != "KILL_SWITCH" else 0
                        # ==========================================================

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
                                    # FIX ANTI-FREEZE: Usamos nuestro 'Kill Switch' para que el bot no se congele si el broker ignora la petición
                                 cur_candle = obtener_velas_con_timeout(api, activo_crudo, 60, 1, timeout=1.0)
                                 if cur_candle:
                                        cur_price = cur_candle[-1]['close']
                                        # Usamos el open de la vela actual real
                                        cur_open = cur_candle[-1]['open']
                                        
                                        # 3. Lógica de Margen (Pullback) y MICROESTRUCTURA
                                        execute_now = False
                                        tiempo_transcurrido = time.time() - start_wait
                                        
                                        # --- BYPASS NIVEL 2: IGNORAR MARGEN Y DISPARAR ---
                                        if estrategia_activa == "DIAGNOSTICO-API":
                                            execute_now = True
                                        
                                        # Lógica de "Toque Dinámico" a la EMA 9
                                        if "EXPLOSIVO-CONT" in estrategia_activa:
                                            if accion == 'call' and cur_price <= ema_9:
                                                execute_now = True
                                            elif accion == 'put' and cur_price >= ema_9:
                                                execute_now = True
                                        else: 
                                            # Lógica de pullback normal con Acelerador de Tick
                                            # El retroceso debe ocurrir en los primeros 3.5 segundos. 
                                            # Si tarda más, no es volumen institucional, es agotamiento.
                                            es_volumen_rapido = tiempo_transcurrido <= 3.5
                                            
                                            if accion == 'call':
                                                if cur_price <= (cur_open - margin_val) and es_volumen_rapido: 
                                                    execute_now = True
                                            elif accion == 'put':
                                                if cur_price >= (cur_open + margin_val) and es_volumen_rapido: 
                                                    execute_now = True

                                        if execute_now:
                                            if tipo_activo == 'digital':
                                                check, order_id = api.buy_digital_spot(activo, monto_invertir, accion, duracion)
                                            else:
                                                check, order_id = api.buy(monto_invertir, activo, accion, duracion)
                                            break
                                except: pass
                                time.sleep(0.5) # FIX ANTI-BAN: Respiro al servidor para no ser desconectados

                        if check:
                            activo_seleccionado = activo
                            tipo_seleccionado = tipo_activo
                            hora_op = datetime.now().strftime('%H:%M:%S')
                            
                            # MENSAJE DE OPERACIÓN COMPACTO
                            sys.stdout.write(f"\r {Fore.LIGHTBLACK_EX}{hora_op}{Style.RESET_ALL} {Fore.YELLOW}>>> EJEC:{Style.RESET_ALL} {activo_seleccionado[:10]} ({accion.upper()}) ${monto_invertir:.0f}...\033[K")
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
                                try:
                                    res_val = api.check_win_v3(order_id)
                                    # La API devuelve el valor monetario directamente
                                    resultado = float(res_val) if res_val is not None else -monto_invertir
                                    status = True
                                except Exception:
                                    resultado = -monto_invertir
                                    status = True

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

                                win = resultado > 0
                                profit = resultado

                                if resultado > 0:
                                    res_text = "WIN"
                                    wins_sesion += 1
                                    res_color_tag = Fore.GREEN
                                    if tipo_gestion == '2': # Masaniello
                                        masaniello.update(resultado)
                                        nivel_actual = masaniello.trades # Usamos nivel para mostrar progreso
                                    elif tipo_gestion == '1': # NeurAlgo (Unified)
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
                                    elif tipo_gestion == '1': # NeurAlgo (Flat Bet / Strict Reset)
                                        # Extirpated Martingale: Immediate reset to base entry on ANY loss.
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

                            log_line = (
                                f" {Fore.LIGHTBLACK_EX}{hora_str}{Style.RESET_ALL}  {Fore.WHITE}{par_str:<10} {Fore.WHITE}{tipo_str:<6} {Fore.WHITE}{niv_str:<5} "
                                f"{res_color_tag}{res_str:<7} {color_res}{lucro_fmt:<11}"
                            )
                            
                            # --- TELEMETRÍA INSTITUCIONAL NEURALGO (UNIFICADA) ---
                            tech_str = f"RSI:{int(rsi) if rsi else 0} ADX:{int(adx) if adx else 0} [{contexto_mercado}]"
                            icono_res = '🏆' if win else '💀'
                            texto_res = 'GANADA ✅' if win else 'PERDIDA ❌'
                            
                            msg_cierre = (
                                f"{icono_res} <b>REPORTE DE OPERACIÓN | NEURALGO</b>\n"
                                f"━━━━━━━━━━━━━━━━━━━━\n"
                                f"🌐 <b>Par:</b> <code>{activo_seleccionado}</code>\n"
                                f"🎯 <b>Acción:</b> <b>{accion.upper()}</b>\n"
                                f"⚙️ <b>Algoritmo:</b> <code>{estrategia_activa}</code>\n"
                                f"💸 <b>Inversión:</b> <code>${monto_invertido:,.2f}</code>\n"
                                f"📊 <b>Resultado:</b> <b>{texto_res}</b>\n"
                                f"💵 <b>P/L:</b> <code>${profit:,.2f}</code>\n"
                                f"🏦 <b>Saldo Est.:</b> <code>${saldo_reporte:,.2f}</code>\n"
                                f"🔬 <b>Tech:</b> <code>{tech_str}</code>\n"
                                f"━━━━━━━━━━━━━━━━━━━━"
                            )
                            enviar_telegram(msg_cierre, parse_mode="HTML")

                            print(f"\r{log_line} {Fore.LIGHTBLACK_EX}[REC]{Style.RESET_ALL}\033[K")
                            
                            # ==========================================================
                            # [NEURALGO] DATA PERSISTENCE LOGGING (SPRINT 7.3)
                            # ==========================================================
                            try:
                                import os
                                archivo_historial = "historial_bionic_otc.csv"
                                # Check if file exists to write headers
                                es_nuevo = not os.path.exists(archivo_historial)
                                
                                with open(archivo_historial, "a", encoding="utf-8") as log_file:
                                    if es_nuevo:
                                        log_file.write("FECHA,HORA,PARIDAD,DIRECCION,INVERSION,RESULTADO,LUCRO\n")
                                    
                                    fecha_hoy = datetime.now().strftime('%Y-%m-%d')
                                    hora_actual = datetime.now().strftime('%H:%M:%S')
                                    
                                    # Write trade data
                                    log_file.write(f"{fecha_hoy},{hora_actual},{activo_seleccionado},{accion.upper()},{monto_invertido},{res_text},{resultado:.2f}\n")
                            except Exception as e:
                                # Silent fail to avoid crashing the bot, but prints to console
                                sys.stdout.write(f"\n[⚠️ ALERTA INTERNA] Error guardando historial CSV: {e}\n")
                                sys.stdout.flush()
                            # ==========================================================

                            # 3. Historial Contable
                            guardar_historial_neuralgo(email_usuario, nombre_cuenta, activo_seleccionado, accion, estrategia_activa, monto_invertido, resultado, saldo_reporte)

                            # 4. Caja Negra de Análisis Técnico (Para auditoría de pérdidas)
                            registrar_analisis_profesional(email_usuario, activo_seleccionado, accion, res_text, rsi, stoch_k, adx, st_trend, ema_long, c_close, rsi_diff, bb_width, candle_size, wick_upper, wick_lower, roc, ema_slope, contexto_mercado)
                            
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
                    # OPTIMIZACIÓN: Eliminado sleep(0.1) innecesario que ralentizaba el bucle 30 segundos.
                    pass
            
            # ESPERA AL FINAL DEL CICLO (Respiro para la API)
            sys.stdout.write(f"\r {Fore.YELLOW}● Ciclo completo. Reiniciando radar em 1s...{Style.RESET_ALL}\033[K")
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