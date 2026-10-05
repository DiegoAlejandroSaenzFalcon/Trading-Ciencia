import os
import threading
from iqoptionapi.stable_api import IQ_Option
import time
import configparser
import logging
from datetime import datetime

# --- Configuración de Estética y Colores ---
class C:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    YELLOW = '\033[93m'
    RED = '\033[91m'
    END = '\033[0m'
    BOLD = '\033[1m'
    UNDERLINE = '\033[4m'

# Configuración del Sistema de Registro (Logging)
logging.basicConfig(
    filename='trading_log.log',
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)

def imprimir_encabezado_tabla():
    print(f"{C.CYAN}------------+------------------+-------------+------+------------+-------------+-------------{C.END}")
    print(f"{C.BOLD}    HORA    |      PARIDAD     |  DIRECCIÓN  |  LV  |   CUENTA   |  RESULTADO  |    LUCRO    {C.END}")
    print(f"{C.CYAN}------------+------------------+-------------+------+------------+-------------+-------------{C.END}")

def actualizar_linea_proceso(activo, accion, lucro_total):
    try:
        # Detectar ancho de la terminal en tiempo real
        ancho = os.get_terminal_size().columns
    except OSError:
        ancho = 120
    
    # Margen de seguridad para evitar el salto de línea automático
    ancho = max(10, ancho - 2)

    hora = datetime.now().strftime("%H:%M:%S")
    color_lucro = C.GREEN if lucro_total >= 0 else C.RED
    str_lucro = f"$ {lucro_total:.2f}"
    
    # Construir versiones de texto plano (sin códigos de color) para medir longitud real
    txt_full = f" {hora} \u2192 {activo} | {accion} | Lucro Total: {str_lucro}"
    txt_short = f" {hora} \u2192 {activo} | {str_lucro}"
    
    if len(txt_full) <= ancho:
        mensaje = f" {hora} \u2192 {activo} | {accion} | Lucro Total: {color_lucro}{str_lucro}{C.END}"
    elif len(txt_short) <= ancho:
        mensaje = f" {hora} \u2192 {activo} | {color_lucro}{str_lucro}{C.END}"
    else:
        # Si no cabe ni la versión corta, truncar el nombre del activo dinámicamente
        fixed_len = 15 + len(str_lucro) # Longitud de hora, flechas, barras y lucro
        available = ancho - fixed_len
        if available > 0:
            activo_trunc = activo[:available]
            mensaje = f" {hora} \u2192 {activo_trunc} | {color_lucro}{str_lucro}{C.END}"
        else:
            mensaje = f" {hora} | {color_lucro}{str_lucro}{C.END}"
        
    print(f"\r\033[K{mensaje}", end="", flush=True)

# --- Clase para manejar la línea de estado en segundo plano ---
class StatusMonitor:
    def __init__(self):
        self.active = False
        self.thread = None
        self.data = {"activo": "Iniciando...", "accion": "...", "lucro": 0.0}
        self.lock = threading.Lock()

    def start(self):
        self.active = True
        self.thread = threading.Thread(target=self._run)
        self.thread.daemon = True
        self.thread.start()

    def stop(self):
        self.active = False
        if self.thread: self.thread.join(timeout=1)

    def update(self, activo, accion, lucro):
        with self.lock:
            self.data = {"activo": activo, "accion": accion, "lucro": lucro}

    def _run(self):
        while self.active:
            with self.lock:
                actualizar_linea_proceso(self.data["activo"], self.data["accion"], self.data["lucro"])
            time.sleep(0.2)

    def safe_print(self, text):
        with self.lock:
            # Limpiar línea actual, imprimir texto y dejar que el loop repinte el estado abajo
            print(f"\r\033[K{text}")

def buy_with_timeout(api, amount, active_id, direction, duration, timeout=20):
    """Intenta comprar con un tiempo límite para evitar congelamientos."""
    result = [False, None]
    def target():
        try: result[0], result[1] = api.buy(amount, active_id, direction, duration)
        except: pass
    t = threading.Thread(target=target); t.start(); t.join(timeout)
    return (result[0], result[1]) if not t.is_alive() else (False, None)

def conectar_broker():
    """
    Establece la conexión con el broker.
    """
    os.system('') # Habilita colores en Windows
    print(f"\n{C.HEADER}--- SISTEMA DE TRADING ---{C.END}")
    
    if not os.path.exists("config.txt"):
        print(f"{C.RED}[ERROR] Archivo 'config.txt' no encontrado.{C.END}")
        logging.error("Archivo de configuración no encontrado.")
        return None

    try:
        config = configparser.ConfigParser()
        config.read("config.txt")
        email = config["GENERAL"]["email"]
        password = config["GENERAL"]["password"]
    except KeyError:
        print(f"{C.RED}[ERROR] Credenciales no encontradas en 'config.txt'.{C.END}")
        logging.error("Credenciales mal formadas en config.txt")
        return None

    print(f"{C.YELLOW}[INFO] Conectando como: {C.BOLD}{email}{C.END}...")
    api = IQ_Option(email, password)
    check, reason = api.connect()
    
    if check:
        print(f"{C.GREEN}[OK] Conexión establecida exitosamente.{C.END}")
        logging.info(f"Conexión exitosa con {email}")
        return api
    else:
        print(f"{C.RED}[ERROR] Fallo en la conexión: {reason}{C.END}")
        logging.error(f"Fallo de conexión: {reason}")
        return None

def seleccionar_cuenta(api):
    """
    Permite al usuario seleccionar entre la cuenta Demo y Real.
    """
    mensaje_error = ""

    while True:
        os.system('cls' if os.name == 'nt' else 'clear')
        print(f"\n{C.BOLD}>> Indique el tipo de cuenta:{C.END}")
        print(f" {C.CYAN}1.{C.END} Cuenta Demo")
        print(f" {C.CYAN}2.{C.END} Cuenta Real")
        
        if mensaje_error:
            print(f"\n{C.RED}{mensaje_error}{C.END}")

        choice = input(f"{C.YELLOW}Seleccione una opción (1 o 2): {C.END}")
        if choice == '1':
            print(f"\n{C.YELLOW}[INFO] Configurando entorno DEMO...{C.END}")
            api.change_balance("PRACTICE")
            print(f"{C.GREEN}[OK] Cuenta activa: DEMO{C.END}")
            print(f"{C.BOLD}[BALANCE] Saldo actual: ${api.get_balance():,.2f}{C.END}")
            logging.info("Usuario seleccionó cuenta Demo (PRACTICE).")
            return True
        elif choice == '2':
            print(f"\n{C.YELLOW}[INFO] Configurando entorno REAL...{C.END}")
            api.change_balance("REAL")
            print(f"{C.GREEN}[OK] Cuenta activa: REAL{C.END}")
            print(f"{C.BOLD}[BALANCE] Saldo actual: ${api.get_balance():,.2f}{C.END}")
            logging.warning("Usuario seleccionó cuenta REAL.")
            return True
        else:
            mensaje_error = "[ERROR] Opción inválida."

def esta_abierto(schedule):
    """Verifica manualmente si el mercado está abierto usando el horario raw."""
    now = int(time.time())
    for start, end in schedule:
        if start <= now <= end:
            return True
    return False

def auditar_resultado(api, order_id, monitor, activo, lucro_total):
    """Intenta obtener el resultado de una operación con múltiples reintentos y métodos."""
    for intento in range(1, 5): # 4 intentos
        monitor.update(activo, f"Auditando... ({intento}/4)", lucro_total)
        try:
            status, profit = api.check_win_v4(order_id)
            if status:
                return profit
        except Exception as e:
            logging.warning(f"Auditoría (check_win_v4) intento {intento} falló para ID {order_id}: {e}")

        time.sleep(intento * 2) # Espera progresiva (2s, 4s, 6s)

    logging.error(f"AUDITORÍA FALLIDA para ID {order_id}. No se pudo determinar el resultado.")
    return None

def bucle_analisis(api):
    """
    Modo de prueba: Busca activos abiertos dinámicamente y ejecuta una operación de prueba.
    """
    print(f"\n{C.HEADER}--- INICIANDO MOTOR DE ANÁLISIS ---{C.END}")
    logging.info("Iniciando modo de prueba dinámico.")
    
    importe_operacion = 1  # Importe fijo por ahora, podría leerse de config
    
    try:
        print(f"{C.YELLOW}[INFO] Sincronizando activos con el broker...{C.END}")
        try:
            # Obtenemos la lista completa de activos e instrumentos
            data = api.get_all_init()
        except Exception as e:
            print(f"{C.RED}[ERROR] Fallo al obtener datos iniciales: {e}{C.END}")
            return

        if not data or not data.get("isSuccessful"):
            print(f"{C.RED}[ERROR] La API no devolvió datos válidos.{C.END}")
            return

        # --- FIX: Poblar manualmente api.ACTIVES ---
        # Esto soluciona el KeyError en api.buy() ya que la librería no pudo mapear los nombres a IDs automáticamente
        if not hasattr(api, 'ACTIVES'):
            api.ACTIVES = {}
            
        # Mapa auxiliar local para asegurar persistencia de IDs (Backup de seguridad)
        mapa_ids = {}
        
        for tipo in ["turbo", "binary"]:
            for aid, info in data.get("result", {}).get(tipo, {}).get("actives", {}).items():
                ticker = info.get("ticker")
                if ticker:
                    api.ACTIVES[ticker] = int(aid)
                    # Aseguramos compatibilidad si la librería convierte a mayúsculas internamente
                    api.ACTIVES[ticker.upper()] = int(aid)
                    mapa_ids[ticker] = int(aid)
                    mapa_ids[ticker.upper()] = int(aid)

        # Clasificación de activos
        candidatos = []
        activos_cerrados = []
        activos_suspendidos = []
        activos_deshabilitados = []
        procesados = set()
        
        # Revisamos opciones Turbo y Binarias
        for tipo in ["turbo", "binary"]:
            actives = data.get("result", {}).get(tipo, {}).get("actives", {})
            for aid, info in actives.items():
                ticker = info.get("ticker")
                if not ticker or ticker in procesados:
                    continue
                procesados.add(ticker)

                if not info.get("enabled"):
                    activos_deshabilitados.append(ticker)
                elif info.get("is_suspended"):
                    activos_suspendidos.append(ticker)
                elif not esta_abierto(info.get("schedule", [])):
                    activos_cerrados.append(ticker)
                else:
                    candidatos.append({"ticker": ticker, "id": int(aid)})

        if not candidatos:
            print(f"{C.RED}[ALERTA] No se encontraron activos abiertos. El mercado puede estar cerrado.{C.END}")
            return

        print(f"{C.GREEN}[OK] Mercado Abierto. {len(candidatos)} activos disponibles.{C.END}")
        # print(f"[INFO] Ejemplo de activos abiertos: {candidatos[:5]}")

        # Intentamos operar recorriendo la lista hasta tener éxito
        operaciones_exitosas = 0
        lucro_total = 0.0
        activos_operables = []
        activos_rechazados = []
        activos_error = []
        
        print(f"\n{C.BOLD}[INFO] Iniciando barrido de ejecución en {len(candidatos)} activos...{C.END}\n")
        
        imprimir_encabezado_tabla()

        # Iniciar monitor de estado en segundo plano
        monitor = StatusMonitor()
        monitor.start()

        for activo in candidatos:
            activo_ticker = activo["ticker"]
            activo_id = activo["id"]
            monitor.update(activo_ticker, "Analizando disponibilidad...", lucro_total)
            # print(f"\n[TEST] Verificando activo: {activo}") # Comentado para limpiar salida
            try:
                # Verificar conexión antes de operar
                if not api.check_connect():
                    monitor.safe_print(f"{C.RED}[ALERTA] Conexión perdida. Reconectando...{C.END}")
                    api.connect()

                # RE-INYECCIÓN DE ID: Aseguramos que el ID exista justo antes de la compra
                # Esto evita KeyErrors si la librería refresca su caché en segundo plano borrando nuestros datos
                if activo_ticker in mapa_ids:
                    api.ACTIVES[activo_ticker] = mapa_ids[activo_ticker]

                # Usar compra con timeout para evitar que se pegue
                check, order_id = buy_with_timeout(api, importe_operacion, activo_ticker, "call", 1)
                
                hora_actual = datetime.now().strftime("%H:%M")
                tipo_cuenta = "PRACTICE" # Asumimos practice por defecto en este modo

                if check:
                    logging.info(f"Operación de prueba exitosa en {activo} ID:{order_id}")
                    operaciones_exitosas += 1
                    activos_operables.append(activo)

                    # --- SINCRONIZACIÓN DE TIEMPO REAL ---
                    # Obtener fecha de expiración real desde el broker para cuenta regresiva exacta
                    expiration_timestamp = int(time.time()) + 60
                    try:
                        bet_info = api.get_betinfo(order_id)
                        if bet_info and bet_info.get('isSuccessful'):
                            game_data = bet_info.get('result', {}).get('data', {}).get(str(order_id))
                            if game_data and 'expired' in game_data:
                                expiration_timestamp = int(game_data['expired'])
                    except Exception as e:
                        logging.error(f"Error obteniendo tiempo de expiración: {e}")
                    
                    ganancia = None
                    while True:
                        try:
                            server_time = api.get_server_timestamp()
                        except:
                            server_time = int(time.time())

                        remaining = max(0, expiration_timestamp - server_time)
                        actualizar_linea_proceso(activo, f"Cierre en {remaining}s...", lucro_total)
                        
                        # Consultar resultado directamente usando get_betinfo (método directo)
                        if remaining <= 2:
                            try:
                                bet_info = api.get_betinfo(order_id)
                                if bet_info and bet_info.get('isSuccessful'):
                                    game_data = bet_info.get('result', {}).get('data', {}).get(str(order_id))
                                    if game_data and 'win' in game_data and game_data['win'] != '':
                                        if game_data['win'] == 'win':
                                            ganancia = float(game_data.get('profit', 0)) - float(game_data.get('deposit', 0))
                                        elif game_data['win'] == 'loose':
                                            ganancia = -float(game_data.get('deposit', 0))
                                        else:
                                            ganancia = 0.0
                                        break
                            except: pass
                        
                        # Salida de seguridad si pasamos 10s después de la expiración sin resultado
                        if remaining == 0 and (int(time.time()) - expiration_timestamp) > 10:
                            break
                        
                        time.sleep(0.5)

                    # Procesar resultado final
                    if ganancia is not None:
                        lucro_total += ganancia
                    
                        if ganancia > 0:
                            resultado = "WIN"
                            color_res = C.GREEN
                        elif ganancia < 0:
                            resultado = "LOSS"
                            color_res = C.RED
                        else:
                            resultado = "EQUAL"
                            color_res = C.YELLOW
                    else:
                        # Si después de todo sigue siendo None, es un error crítico de datos
                        ganancia = 0.0
                        resultado = "N/A"
                        color_res = C.YELLOW

                    # Formatear ganancia para que quede centrada con el símbolo $
                    str_ganancia = f"$ {ganancia:.2f}"
                    
                    # Limpiar línea de proceso antes de imprimir tabla
                    print(f"\r\033[K", end="", flush=True)

                    # Imprimir fila de la tabla alineada
                    print(f"    {hora_actual:^5}    |{activo:^18}|{C.GREEN}{'call':^13}{C.END}|{'1':^6}|{tipo_cuenta:^12}|{color_res}{resultado:^13}{C.END}|{color_res}{str_ganancia:^13}{C.END}")
                    print(f"{C.CYAN}------------+------------------+-------------+------+------------+-------------+-------------{C.END}")
                    
                else:
                    activos_rechazados.append(activo_ticker)
                    
            except Exception as e:
                activos_error.append(f"{activo_ticker} ({e})")
                pass
            
            time.sleep(1) # Pequeña pausa para no saturar
            
        monitor.stop() # Detener monitor al finalizar

        print(f"\n{C.CYAN} {'-'*95} {C.END}")
        print(f"{C.GREEN}[FIN] Barrido completado. Operaciones abiertas: {operaciones_exitosas}{C.END}")
        print(f"{C.YELLOW}[RESUMEN] Activos operables guardados: {len(activos_operables)}{C.END}")

        if activos_rechazados:
            print(f"\n{C.RED}--- LISTADO DE ACTIVOS RECHAZADOS ({len(activos_rechazados)}) ---{C.END}")
            for item in activos_rechazados:
                print(f" {C.RED}x{C.END} {item}")

        if activos_error:
            print(f"\n{C.RED}--- LISTADO DE ERRORES TÉCNICOS ({len(activos_error)}) ---{C.END}")
            for item in activos_error:
                print(f" {C.RED}!{C.END} {item}")
        
        if activos_cerrados:
            print(f"\n{C.YELLOW}--- ACTIVOS CERRADOS (FUERA DE HORARIO) ({len(activos_cerrados)}) ---{C.END}")
            for item in activos_cerrados:
                print(f" - {item}")

        if activos_suspendidos:
            print(f"\n{C.YELLOW}--- ACTIVOS SUSPENDIDOS POR EL BROKER ({len(activos_suspendidos)}) ---{C.END}")
            for item in activos_suspendidos:
                print(f" - {item}")

        if activos_deshabilitados:
            print(f"\n{C.YELLOW}--- ACTIVOS DESHABILITADOS ({len(activos_deshabilitados)}) ---{C.END}")
            for item in activos_deshabilitados:
                print(f" - {item}")

    except KeyboardInterrupt:
        print(f"\n{C.RED}[FIN] Deteniendo motor de análisis...{C.END}")
        logging.info("Usuario detuvo el bot manualmente.")

if __name__ == "__main__":
    try:
        api = conectar_broker()
        if api:
            if seleccionar_cuenta(api):
                bucle_analisis(api)
    except Exception as e:
        import traceback
        print(f"\n{C.RED}[FATAL ERROR] El programa ha fallado: {e}{C.END}")
        traceback.print_exc()
    finally:
        input(f"\n{C.BOLD}--- Proceso finalizado. Presiona ENTER para salir. ---{C.END}")
